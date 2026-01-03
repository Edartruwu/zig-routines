//! Task group for managing related concurrent tasks.
//!
//! A TaskGroup is a lighter-weight alternative to Scope that doesn't
//! require heap allocation for task tracking. Good for fork-join patterns.
//!
//! ## Example
//!
//! ```zig
//! var group = TaskGroup.init();
//!
//! group.add(1);
//! defer group.done();
//!
//! // Spawn work...
//!
//! group.wait();
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const Context = @import("../task/context.zig").Context;
const Allocator = std.mem.Allocator;

/// A lightweight task group for fork-join patterns.
pub const TaskGroup = struct {
    const Self = @This();

    /// Number of pending tasks.
    pending: atomic.Atomic(isize),

    /// Mutex for waiting.
    mutex: std.Thread.Mutex,

    /// Condition for waiting.
    cond: std.Thread.Condition,

    /// Whether any task failed.
    has_failure: atomic.Atomic(bool),

    /// Optional cancellation context.
    context: ?*Context,

    /// Initialize a new task group.
    pub fn init() Self {
        return .{
            .pending = atomic.Atomic(isize).init(0),
            .mutex = .{},
            .cond = .{},
            .has_failure = atomic.Atomic(bool).init(false),
            .context = null,
        };
    }

    /// Initialize with a cancellation context.
    pub fn initWithContext(ctx: *Context) Self {
        var self = init();
        self.context = ctx;
        return self;
    }

    /// Add count to the number of pending tasks.
    pub fn add(self: *Self, count: isize) void {
        _ = self.pending.fetchAdd(count);
    }

    /// Mark one task as done.
    pub fn done(self: *Self) void {
        const prev = self.pending.fetchSub(1);
        if (prev == 1) {
            // Was the last task
            self.mutex.lock();
            defer self.mutex.unlock();
            self.cond.broadcast();
        }
    }

    /// Mark one task as failed and done.
    pub fn fail(self: *Self) void {
        self.has_failure.store(true);
        if (self.context) |ctx| {
            ctx.cancel();
        }
        self.done();
    }

    /// Wait for all tasks to complete.
    pub fn wait(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.pending.load() > 0) {
            self.cond.wait(&self.mutex);
        }
    }

    /// Wait with timeout (returns true if completed, false if timeout).
    pub fn waitTimeout(self: *Self, timeout_ns: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const deadline = @as(u64, @intCast(std.time.nanoTimestamp())) + timeout_ns;

        while (self.pending.load() > 0) {
            const now = @as(u64, @intCast(std.time.nanoTimestamp()));
            if (now >= deadline) {
                return false;
            }

            const remaining = deadline - now;
            self.cond.timedWait(&self.mutex, remaining) catch {};
        }

        return true;
    }

    /// Check if any task failed.
    pub fn hasFailure(self: *Self) bool {
        return self.has_failure.load();
    }

    /// Get number of pending tasks.
    pub fn getPending(self: *Self) usize {
        const val = self.pending.load();
        return if (val > 0) @intCast(val) else 0;
    }

    /// Check if all tasks are done.
    pub fn isDone(self: *Self) bool {
        return self.pending.load() <= 0;
    }

    /// Cancel the group's context if present.
    pub fn cancel(self: *Self) void {
        if (self.context) |ctx| {
            ctx.cancel();
        }
    }
};

/// Fork-join helper that automatically manages done() calls.
pub fn ForkJoin(comptime T: type) type {
    return struct {
        const Self = @This();

        group: *TaskGroup,
        results: []T,
        next_index: atomic.Atomic(usize),
        allocator: Allocator,

        pub fn init(allocator: Allocator, group: *TaskGroup, count: usize) !Self {
            const results = try allocator.alloc(T, count);
            return .{
                .group = group,
                .results = results,
                .next_index = atomic.Atomic(usize).init(0),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.results);
        }

        /// Fork a task, returning its index.
        pub fn fork(self: *Self) usize {
            const index = self.next_index.fetchAdd(1);
            self.group.add(1);
            return index;
        }

        /// Complete a forked task with result.
        pub fn join(self: *Self, index: usize, result: T) void {
            self.results[index] = result;
            self.group.done();
        }

        /// Wait and get all results.
        pub fn collect(self: *Self) []T {
            self.group.wait();
            return self.results;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "TaskGroup basic" {
    var group = TaskGroup.init();

    try std.testing.expect(group.isDone());
    try std.testing.expectEqual(@as(usize, 0), group.getPending());

    group.add(3);
    try std.testing.expect(!group.isDone());
    try std.testing.expectEqual(@as(usize, 3), group.getPending());

    group.done();
    group.done();
    try std.testing.expectEqual(@as(usize, 1), group.getPending());

    group.done();
    try std.testing.expect(group.isDone());
}

test "TaskGroup wait" {
    var group = TaskGroup.init();

    // Already done, should return immediately
    group.wait();
    try std.testing.expect(group.isDone());
}

test "TaskGroup fail" {
    var group = TaskGroup.init();

    group.add(1);
    try std.testing.expect(!group.hasFailure());

    group.fail();
    try std.testing.expect(group.hasFailure());
    try std.testing.expect(group.isDone());
}

test "TaskGroup with context" {
    var ctx = Context.init();
    var group = TaskGroup.initWithContext(&ctx);

    try std.testing.expect(!ctx.isCancelled());

    group.add(1);
    group.fail();

    try std.testing.expect(ctx.isCancelled());
}

test "ForkJoin" {
    var group = TaskGroup.init();
    var fj = try ForkJoin(u32).init(std.testing.allocator, &group, 3);
    defer fj.deinit();

    const idx0 = fj.fork();
    const idx1 = fj.fork();
    const idx2 = fj.fork();

    fj.join(idx0, 10);
    fj.join(idx1, 20);
    fj.join(idx2, 30);

    const results = fj.collect();

    try std.testing.expectEqual(@as(u32, 10), results[0]);
    try std.testing.expectEqual(@as(u32, 20), results[1]);
    try std.testing.expectEqual(@as(u32, 30), results[2]);
}
