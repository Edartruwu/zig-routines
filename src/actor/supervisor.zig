//! Supervisor for managing actor lifecycles.
//!
//! Supervisors monitor child actors and restart them according to
//! a supervision strategy when they fail. Inspired by Erlang/OTP.
//!
//! ## Strategies
//!
//! - `one_for_one`: Restart only the failed child
//! - `one_for_all`: Restart all children if one fails
//! - `rest_for_one`: Restart the failed child and all children started after it
//!
//! ## Example
//!
//! ```zig
//! var sup = try Supervisor.init(allocator, .{
//!     .strategy = .one_for_one,
//!     .max_restarts = 3,
//!     .max_seconds = 5,
//! });
//! defer sup.deinit();
//!
//! try sup.startChild(.{
//!     .id = "worker1",
//!     .start = workerStart,
//! });
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const Allocator = std.mem.Allocator;

/// Supervision strategy.
pub const Strategy = enum {
    /// Restart only the failed child.
    one_for_one,
    /// Restart all children if one fails.
    one_for_all,
    /// Restart failed child and all children started after it.
    rest_for_one,
};

/// Child restart type.
pub const RestartType = enum {
    /// Always restart.
    permanent,
    /// Restart only if terminated abnormally.
    transient,
    /// Never restart.
    temporary,
};

/// Child specification.
pub const ChildSpec = struct {
    /// Unique identifier.
    id: []const u8,

    /// Start function.
    start_fn: *const fn (*anyopaque) anyerror!void,

    /// Context for start function.
    context: ?*anyopaque = null,

    /// Restart type.
    restart: RestartType = .permanent,

    /// Shutdown timeout in milliseconds.
    shutdown_ms: u32 = 5000,
};

/// Child state.
const ChildState = enum {
    starting,
    running,
    stopping,
    stopped,
    failed,
};

/// Child entry.
const Child = struct {
    spec: ChildSpec,
    state: ChildState,
    pid: ?std.Thread,
    restart_count: u32,
    last_restart: i64,
};

/// Supervisor configuration.
pub const SupervisorConfig = struct {
    /// Supervision strategy.
    strategy: Strategy = .one_for_one,

    /// Maximum restarts allowed.
    max_restarts: u32 = 3,

    /// Time window for max_restarts (in seconds).
    max_seconds: u32 = 5,
};

/// Supervisor state.
pub const SupervisorState = enum(u8) {
    initializing = 0,
    running = 1,
    stopping = 2,
    stopped = 3,
};

/// Supervisor for managing child actors.
pub const Supervisor = struct {
    const Self = @This();

    /// Children.
    children: std.ArrayListUnmanaged(Child),

    /// Configuration.
    config: SupervisorConfig,

    /// Current state.
    state: atomic.Atomic(SupervisorState),

    /// Mutex for thread safety.
    mutex: std.Thread.Mutex,

    /// Allocator.
    allocator: Allocator,

    /// Total restart count.
    total_restarts: u32,

    /// First restart timestamp.
    restart_window_start: i64,

    /// Initialize a new supervisor.
    pub fn init(allocator: Allocator, config: SupervisorConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .children = .{},
            .config = config,
            .state = atomic.Atomic(SupervisorState).init(.initializing),
            .mutex = .{},
            .allocator = allocator,
            .total_restarts = 0,
            .restart_window_start = 0,
        };
        self.state.store(.running);
        return self;
    }

    /// Deinitialize the supervisor.
    pub fn deinit(self: *Self) void {
        self.stopAllChildren();
        self.children.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Start a child.
    pub fn startChild(self: *Self, spec: ChildSpec) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if child already exists
        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.spec.id, spec.id)) {
                return error.ChildAlreadyExists;
            }
        }

        var child = Child{
            .spec = spec,
            .state = .starting,
            .pid = null,
            .restart_count = 0,
            .last_restart = std.time.timestamp(),
        };

        // Start the child
        child.pid = std.Thread.spawn(.{}, runChild, .{ self, self.children.items.len }) catch |err| {
            child.state = .failed;
            try self.children.append(self.allocator, child);
            return err;
        };

        child.state = .running;
        try self.children.append(self.allocator, child);
    }

    /// Stop a specific child.
    pub fn stopChild(self: *Self, id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.children.items, 0..) |*child, i| {
            if (std.mem.eql(u8, child.spec.id, id)) {
                self.stopChildAt(i);
                break;
            }
        }
    }

    fn stopChildAt(self: *Self, index: usize) void {
        if (index >= self.children.items.len) return;

        var child = &self.children.items[index];
        if (child.state != .running) return;

        child.state = .stopping;

        if (child.pid) |pid| {
            // Wait for thread with timeout
            pid.join();
            child.pid = null;
        }

        child.state = .stopped;
    }

    /// Stop all children.
    pub fn stopAllChildren(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Stop in reverse order
        var i = self.children.items.len;
        while (i > 0) {
            i -= 1;
            self.stopChildAt(i);
        }
    }

    /// Restart a child.
    pub fn restartChild(self: *Self, id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.children.items, 0..) |*child, i| {
            if (std.mem.eql(u8, child.spec.id, id)) {
                try self.restartChildAt(i);
                break;
            }
        }
    }

    fn restartChildAt(self: *Self, index: usize) !void {
        if (index >= self.children.items.len) return;

        var child = &self.children.items[index];

        // Check restart limits
        if (!self.canRestart(child)) {
            return error.MaxRestartsExceeded;
        }

        // Stop if running
        if (child.state == .running) {
            self.stopChildAt(index);
        }

        // Restart
        child.restart_count += 1;
        child.last_restart = std.time.timestamp();
        child.state = .starting;

        child.pid = try std.Thread.spawn(.{}, runChild, .{ self, index });
        child.state = .running;
    }

    fn canRestart(self: *Self, child: *Child) bool {
        const now = std.time.timestamp();

        // Reset window if expired
        if (now - self.restart_window_start > self.config.max_seconds) {
            self.total_restarts = 0;
            self.restart_window_start = now;
        }

        // Check child's restart type
        if (child.spec.restart == .temporary) {
            return false;
        }

        // Check total restarts
        if (self.total_restarts >= self.config.max_restarts) {
            return false;
        }

        self.total_restarts += 1;
        return true;
    }

    fn runChild(self: *Self, index: usize) void {
        if (index >= self.children.items.len) return;

        const child = &self.children.items[index];
        const spec = child.spec;

        // Run the child's start function
        if (spec.context) |ctx| {
            spec.start_fn(ctx) catch |err| {
                self.handleChildFailure(index, err);
            };
        }
    }

    fn handleChildFailure(self: *Self, index: usize, err: anyerror) void {
        _ = err;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (index >= self.children.items.len) return;

        var child = &self.children.items[index];
        child.state = .failed;
        child.pid = null;

        // Apply restart strategy
        switch (self.config.strategy) {
            .one_for_one => {
                // Restart only this child
                if (child.spec.restart != .temporary) {
                    self.restartChildAt(index) catch {};
                }
            },
            .one_for_all => {
                // Restart all children
                self.restartAll();
            },
            .rest_for_one => {
                // Restart this and all following children
                self.restartFrom(index);
            },
        }
    }

    fn restartAll(self: *Self) void {
        // Stop all first
        var i = self.children.items.len;
        while (i > 0) {
            i -= 1;
            self.stopChildAt(i);
        }

        // Restart all
        for (0..self.children.items.len) |j| {
            self.restartChildAt(j) catch {};
        }
    }

    fn restartFrom(self: *Self, index: usize) void {
        // Stop from index to end
        var i = self.children.items.len;
        while (i > index) {
            i -= 1;
            self.stopChildAt(i);
        }

        // Restart from index to end
        for (index..self.children.items.len) |j| {
            self.restartChildAt(j) catch {};
        }
    }

    /// Get child count.
    pub fn childCount(self: *const Self) usize {
        return self.children.items.len;
    }

    /// Get running child count.
    pub fn runningCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var count: usize = 0;
        for (self.children.items) |child| {
            if (child.state == .running) {
                count += 1;
            }
        }
        return count;
    }

    /// Check if supervisor is running.
    pub fn isRunning(self: *const Self) bool {
        return self.state.load() == .running;
    }

    /// Get supervisor state.
    pub fn getState(self: *const Self) SupervisorState {
        return self.state.load();
    }
};

/// Simple supervisor builder.
pub const SupervisorBuilder = struct {
    const Self = @This();

    config: SupervisorConfig,
    children: std.ArrayListUnmanaged(ChildSpec),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Self {
        return .{
            .config = .{},
            .children = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.children.deinit(self.allocator);
    }

    pub fn strategy(self: *Self, s: Strategy) *Self {
        self.config.strategy = s;
        return self;
    }

    pub fn maxRestarts(self: *Self, max: u32) *Self {
        self.config.max_restarts = max;
        return self;
    }

    pub fn maxSeconds(self: *Self, seconds: u32) *Self {
        self.config.max_seconds = seconds;
        return self;
    }

    pub fn addChild(self: *Self, spec: ChildSpec) !*Self {
        try self.children.append(self.allocator, spec);
        return self;
    }

    pub fn build(self: *Self) !*Supervisor {
        const sup = try Supervisor.init(self.allocator, self.config);

        for (self.children.items) |spec| {
            try sup.startChild(spec);
        }

        return sup;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Supervisor init and deinit" {
    var sup = try Supervisor.init(std.testing.allocator, .{});
    defer sup.deinit();

    try std.testing.expect(sup.isRunning());
    try std.testing.expectEqual(@as(usize, 0), sup.childCount());
}

test "Supervisor config" {
    var sup = try Supervisor.init(std.testing.allocator, .{
        .strategy = .one_for_all,
        .max_restarts = 5,
        .max_seconds = 10,
    });
    defer sup.deinit();

    try std.testing.expectEqual(Strategy.one_for_all, sup.config.strategy);
    try std.testing.expectEqual(@as(u32, 5), sup.config.max_restarts);
    try std.testing.expectEqual(@as(u32, 10), sup.config.max_seconds);
}

test "SupervisorBuilder" {
    var builder = SupervisorBuilder.init(std.testing.allocator);
    defer builder.deinit();

    _ = builder.strategy(.rest_for_one).maxRestarts(10).maxSeconds(60);

    try std.testing.expectEqual(Strategy.rest_for_one, builder.config.strategy);
    try std.testing.expectEqual(@as(u32, 10), builder.config.max_restarts);
}

test "Supervisor state" {
    var sup = try Supervisor.init(std.testing.allocator, .{});
    defer sup.deinit();

    try std.testing.expectEqual(SupervisorState.running, sup.getState());
}
