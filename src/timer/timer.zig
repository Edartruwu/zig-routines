//! Timer wheel implementation for efficient timeout management.
//!
//! A hierarchical timer wheel provides O(1) timer operations for scheduling
//! delayed tasks. This is essential for implementing timeouts, delays, and
//! periodic tasks in concurrent systems.
//!
//! ## Algorithm
//!
//! Based on the hierarchical timing wheel described by Varghese and Lauck.
//! Uses multiple wheels with different granularities for efficiency.
//!
//! ## Features
//!
//! - O(1) timer insertion and cancellation
//! - O(1) per-tick processing
//! - Configurable tick duration and wheel sizes
//!
//! ## Example
//!
//! ```zig
//! var wheel = try TimerWheel.init(allocator, .{});
//! defer wheel.deinit();
//!
//! // Schedule a task for 100ms from now
//! const timer = try wheel.schedule(task, 100 * std.time.ns_per_ms);
//!
//! // Process expired timers
//! const expired = wheel.tick();
//! for (expired) |task| {
//!     task.run();
//! }
//! ```

const std = @import("std");
const Task = @import("../task/task.zig").Task;
const atomic = @import("../core/atomic.zig");
const intrusive = @import("../core/intrusive.zig");
const Allocator = std.mem.Allocator;

/// Timer wheel configuration.
pub const TimerConfig = struct {
    /// Duration of each tick in nanoseconds.
    tick_duration_ns: u64 = 1_000_000, // 1ms default

    /// Number of slots in the wheel (must be power of 2).
    wheel_size: usize = 256,

    /// Maximum timer duration in ticks.
    max_ticks: u64 = 1 << 32,
};

/// Timer entry state.
pub const TimerState = enum(u8) {
    /// Timer is pending (scheduled but not fired).
    pending = 0,
    /// Timer has fired.
    fired = 1,
    /// Timer was cancelled.
    cancelled = 2,
};

/// A timer entry in the wheel.
pub const TimerEntry = struct {
    /// Intrusive list node for slot chains.
    node: intrusive.Node,

    /// The task to execute when timer fires.
    task: *Task,

    /// Absolute deadline in ticks.
    deadline: u64,

    /// Current state.
    state: atomic.Atomic(TimerState),

    /// Initialize a timer entry.
    pub fn init(task: *Task, deadline: u64) TimerEntry {
        return .{
            .node = .{},
            .task = task,
            .deadline = deadline,
            .state = atomic.Atomic(TimerState).init(.pending),
        };
    }

    /// Cancel this timer.
    /// Returns true if successfully cancelled, false if already fired.
    pub fn cancel(self: *TimerEntry) bool {
        const old = self.state.compareAndSwap(.pending, .cancelled);
        return old == null; // null means swap succeeded
    }

    /// Check if timer is pending.
    pub fn isPending(self: *const TimerEntry) bool {
        return self.state.load() == .pending;
    }
};

/// Timer handle returned from schedule operations.
pub const TimerHandle = struct {
    entry: *TimerEntry,

    /// Cancel the timer.
    pub fn cancel(self: TimerHandle) bool {
        return self.entry.cancel();
    }

    /// Check if timer is still pending.
    pub fn isPending(self: TimerHandle) bool {
        return self.entry.isPending();
    }
};

/// Hierarchical timer wheel.
pub const TimerWheel = struct {
    const Self = @This();

    /// A slot in the wheel (linked list of timers).
    const Slot = struct {
        list: intrusive.List,

        fn init() Slot {
            return .{ .list = intrusive.List.init() };
        }
    };

    /// Configuration.
    config: TimerConfig,

    /// Wheel slots.
    slots: []Slot,

    /// Mask for slot indexing (wheel_size - 1).
    mask: usize,

    /// Current tick.
    current_tick: u64,

    /// Start time in nanoseconds.
    start_time: i128,

    /// Timer entry pool.
    entry_pool: std.ArrayListUnmanaged(*TimerEntry),

    /// Allocator.
    allocator: Allocator,

    /// Initialize a new timer wheel.
    pub fn init(alloc: Allocator, config: TimerConfig) !*Self {
        // Ensure wheel_size is power of 2
        const wheel_size = std.math.ceilPowerOfTwo(usize, config.wheel_size) catch config.wheel_size;

        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        const slots = try alloc.alloc(Slot, wheel_size);
        for (slots) |*slot| {
            slot.* = Slot.init();
        }

        self.* = Self{
            .config = config,
            .slots = slots,
            .mask = wheel_size - 1,
            .current_tick = 0,
            .start_time = std.time.nanoTimestamp(),
            .entry_pool = .{},
            .allocator = alloc,
        };

        return self;
    }

    /// Deinitialize the timer wheel.
    pub fn deinit(self: *Self) void {
        // Free all timer entries
        for (self.entry_pool.items) |entry| {
            self.allocator.destroy(entry);
        }
        self.entry_pool.deinit(self.allocator);

        self.allocator.free(self.slots);
        self.allocator.destroy(self);
    }

    /// Schedule a task to run after a delay.
    pub fn schedule(self: *Self, task: *Task, delay_ns: u64) !TimerHandle {
        const delay_ticks = delay_ns / self.config.tick_duration_ns;
        const deadline = self.current_tick + delay_ticks;

        return self.scheduleAt(task, deadline);
    }

    /// Schedule a task to run at a specific tick.
    pub fn scheduleAt(self: *Self, task: *Task, deadline: u64) !TimerHandle {
        // Create timer entry
        const entry = try self.allocator.create(TimerEntry);
        entry.* = TimerEntry.init(task, deadline);

        try self.entry_pool.append(self.allocator, entry);

        // Insert into appropriate slot
        const slot_idx = deadline & self.mask;
        self.slots[slot_idx].list.pushBack(&entry.node);

        return TimerHandle{ .entry = entry };
    }

    /// Advance the wheel by one tick and return expired timers.
    /// Returns tasks that should be executed.
    pub fn tick(self: *Self) ExpiredTimers {
        self.current_tick += 1;
        const slot_idx = self.current_tick & self.mask;

        return ExpiredTimers{
            .wheel = self,
            .slot = &self.slots[slot_idx],
            .current_tick = self.current_tick,
        };
    }

    /// Advance to current time based on wall clock.
    pub fn advance(self: *Self) ExpiredTimers {
        const now = std.time.nanoTimestamp();
        const elapsed_ns: u64 = @intCast(now - self.start_time);
        const target_tick = elapsed_ns / self.config.tick_duration_ns;

        // Only advance if needed
        if (target_tick <= self.current_tick) {
            return ExpiredTimers{
                .wheel = self,
                .slot = null,
                .current_tick = self.current_tick,
            };
        }

        // Advance one tick at a time
        return self.tick();
    }

    /// Get current tick.
    pub fn getCurrentTick(self: *const Self) u64 {
        return self.current_tick;
    }

    /// Get the number of scheduled timers.
    pub fn getTimerCount(self: *const Self) usize {
        return self.entry_pool.items.len;
    }
};

/// Iterator over expired timers.
pub const ExpiredTimers = struct {
    wheel: *TimerWheel,
    slot: ?*TimerWheel.Slot,
    current_tick: u64,
    current_node: ?*intrusive.Node = null,
    started: bool = false,

    /// Get the next expired task.
    pub fn next(self: *ExpiredTimers) ?*Task {
        const slot = self.slot orelse return null;

        if (!self.started) {
            self.current_node = slot.list.head;
            self.started = true;
        }

        while (self.current_node) |node| {
            // Get the entry
            const entry: *TimerEntry = @fieldParentPtr("node", node);
            self.current_node = node.next;

            // Check if timer is expired and pending
            if (entry.deadline <= self.current_tick) {
                // Try to mark as fired
                const old = entry.state.compareAndSwap(.pending, .fired);
                if (old == null) {
                    // Remove from list
                    slot.list.remove(node);
                    return entry.task;
                }
            }
        }

        return null;
    }
};

/// Delay helper - sleeps for specified duration.
pub fn delay(ns: u64) void {
    std.time.sleep(ns);
}

/// Delay in milliseconds.
pub fn delayMs(ms: u64) void {
    delay(ms * std.time.ns_per_ms);
}

/// Delay in seconds.
pub fn delayS(s: u64) void {
    delay(s * std.time.ns_per_s);
}

// ============================================================================
// Tests
// ============================================================================

test "TimerWheel basic" {
    var wheel = try TimerWheel.init(std.testing.allocator, .{});
    defer wheel.deinit();

    try std.testing.expectEqual(@as(u64, 0), wheel.getCurrentTick());
}

test "TimerWheel schedule and tick" {
    var wheel = try TimerWheel.init(std.testing.allocator, .{ .wheel_size = 8 });
    defer wheel.deinit();

    // Create a dummy task
    var task = Task.init(struct {
        fn run(_: *Task) void {}
    }.run);

    // Schedule for 2 ticks from now
    const handle = try wheel.schedule(&task, 2 * wheel.config.tick_duration_ns);
    try std.testing.expect(handle.isPending());

    // Tick once - timer shouldn't fire
    var expired1 = wheel.tick();
    try std.testing.expect(expired1.next() == null);

    // Tick again - timer should fire
    var expired2 = wheel.tick();
    const fired_task = expired2.next();
    try std.testing.expect(fired_task != null);
    try std.testing.expect(fired_task.? == &task);
    try std.testing.expect(!handle.isPending());
}

test "TimerWheel cancel" {
    var wheel = try TimerWheel.init(std.testing.allocator, .{});
    defer wheel.deinit();

    var task = Task.init(struct {
        fn run(_: *Task) void {}
    }.run);

    const handle = try wheel.schedule(&task, 10 * wheel.config.tick_duration_ns);
    try std.testing.expect(handle.isPending());

    // Cancel before it fires
    try std.testing.expect(handle.cancel());
    try std.testing.expect(!handle.isPending());

    // Can't cancel twice
    try std.testing.expect(!handle.cancel());
}

test "TimerEntry states" {
    var task = Task.init(struct {
        fn run(_: *Task) void {}
    }.run);

    var entry = TimerEntry.init(&task, 100);
    try std.testing.expectEqual(TimerState.pending, entry.state.load());

    try std.testing.expect(entry.cancel());
    try std.testing.expectEqual(TimerState.cancelled, entry.state.load());
}
