//! WaitGroup for coordinating multiple concurrent tasks.
//!
//! A WaitGroup waits for a collection of tasks to finish. The main task
//! calls add() to set the number of tasks to wait for, then each task
//! calls done() when finished. wait() blocks until all tasks complete.
//!
//! ## Example
//!
//! ```zig
//! var wg = WaitGroup.init();
//!
//! // Spawn 5 tasks
//! for (0..5) |_| {
//!     wg.add(1);
//!     try spawnTask(struct {
//!         fn run(w: *WaitGroup) void {
//!             defer w.done();
//!             doWork();
//!         }
//!     }.run, &wg);
//! }
//!
//! // Wait for all tasks to complete
//! wg.wait();
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");

/// WaitGroup waits for a collection of tasks to finish.
pub const WaitGroup = struct {
    const Self = @This();

    /// Counter state packed into a single atomic:
    /// - Lower 32 bits: counter (number of pending tasks)
    /// - Upper 32 bits: waiter count (threads blocked in wait)
    state: atomic.Atomic(u64),

    /// Futex-based event for efficient waiting
    event: std.Thread.ResetEvent,

    pub fn init() Self {
        return .{
            .state = atomic.Atomic(u64).init(0),
            .event = .{},
        };
    }

    /// Add delta to the counter. Delta may be negative.
    ///
    /// If the counter becomes zero, all blocked wait() calls are released.
    /// If the counter goes negative, this is a programming error.
    pub fn add(self: *Self, delta: i32) void {
        const d: u64 = @bitCast(@as(i64, delta));
        const old_state = self.state.raw().fetchAdd(d, .release);
        const old_counter = @as(i32, @truncate(@as(i64, @bitCast(old_state))));
        const new_counter = old_counter + delta;

        if (new_counter < 0) {
            @panic("WaitGroup counter went negative");
        }

        if (new_counter == 0) {
            // Signal all waiters
            self.event.set();
        }
    }

    /// Decrement the counter by 1.
    /// Equivalent to add(-1).
    pub fn done(self: *Self) void {
        self.add(-1);
    }

    /// Block until the counter becomes zero.
    ///
    /// If the counter is already zero, returns immediately.
    pub fn wait(self: *Self) void {
        while (true) {
            const state = self.state.load();
            const cnt = @as(i32, @truncate(@as(i64, @bitCast(state))));

            if (cnt == 0) {
                return;
            }

            // Wait for signal
            self.event.wait();

            // Check again after waking
            const new_state = self.state.load();
            const new_cnt = @as(i32, @truncate(@as(i64, @bitCast(new_state))));
            if (new_cnt == 0) {
                return;
            }

            // Reset event for next wait cycle
            self.event.reset();
        }
    }

    /// Try to wait with a timeout.
    /// Returns true if counter reached zero, false if timed out.
    pub fn waitTimeout(self: *Self, timeout_ns: u64) bool {
        const deadline = @as(u64, @intCast(std.time.nanoTimestamp())) + timeout_ns;

        while (true) {
            const state = self.state.load();
            const cnt = @as(i32, @truncate(@as(i64, @bitCast(state))));

            if (cnt == 0) {
                return true;
            }

            const now = @as(u64, @intCast(std.time.nanoTimestamp()));
            if (now >= deadline) {
                return false;
            }

            const remaining = deadline - now;
            self.event.timedWait(remaining) catch {};

            // Check again after waking
            const new_state = self.state.load();
            const new_cnt = @as(i32, @truncate(@as(i64, @bitCast(new_state))));
            if (new_cnt == 0) {
                return true;
            }

            self.event.reset();
        }
    }

    /// Get current counter value.
    pub fn counter(self: *const Self) i32 {
        const state = self.state.load();
        return @as(i32, @truncate(@as(i64, @bitCast(state))));
    }

    /// Check if all tasks are done.
    pub fn isDone(self: *const Self) bool {
        return self.counter() == 0;
    }

    /// Reset the wait group for reuse.
    /// Only safe to call when counter is zero.
    pub fn reset(self: *Self) void {
        std.debug.assert(self.counter() == 0);
        self.event.reset();
    }
};

/// Latch is a single-use synchronization barrier.
/// Unlike WaitGroup, it can only count down and cannot be reset.
pub const Latch = struct {
    const Self = @This();

    count: atomic.Atomic(u32),
    event: std.Thread.ResetEvent,

    pub fn init(count: u32) Self {
        return .{
            .count = atomic.Atomic(u32).init(count),
            .event = .{},
        };
    }

    /// Decrement the count. When it reaches zero, all waiters are released.
    pub fn countDown(self: *Self) void {
        const old = self.count.raw().fetchSub(1, .release);
        if (old == 1) {
            self.event.set();
        }
    }

    /// Wait until count reaches zero.
    pub fn wait(self: *Self) void {
        while (self.count.load() > 0) {
            self.event.wait();
        }
    }

    /// Try wait with timeout.
    pub fn waitTimeout(self: *Self, timeout_ns: u64) bool {
        const deadline = @as(u64, @intCast(std.time.nanoTimestamp())) + timeout_ns;

        while (self.count.load() > 0) {
            const now = @as(u64, @intCast(std.time.nanoTimestamp()));
            if (now >= deadline) return false;
            self.event.timedWait(deadline - now) catch {};
        }
        return true;
    }

    /// Check if latch has been released.
    pub fn isReleased(self: *const Self) bool {
        return self.count.load() == 0;
    }

    /// Get current count.
    pub fn getCount(self: *const Self) u32 {
        return self.count.load();
    }
};

/// Barrier synchronizes a fixed number of threads at a sync point.
/// All threads must arrive before any can proceed.
pub const Barrier = struct {
    const Self = @This();

    parties: u32,
    count: atomic.Atomic(u32),
    generation: atomic.Atomic(u32),
    event: std.Thread.ResetEvent,

    pub fn init(parties: u32) Self {
        return .{
            .parties = parties,
            .count = atomic.Atomic(u32).init(parties),
            .generation = atomic.Atomic(u32).init(0),
            .event = .{},
        };
    }

    /// Wait at the barrier until all parties arrive.
    /// Returns the arrival index (0 is the last to arrive, which triggers release).
    pub fn wait(self: *Self) u32 {
        const gen = self.generation.load();

        const old_count = self.count.raw().fetchSub(1, .acq_rel);
        const index = old_count - 1;

        if (old_count == 1) {
            // Last to arrive - trigger release
            self.count.store(self.parties);
            _ = self.generation.fetchAdd(1);
            self.event.set();
            return 0;
        }

        // Wait for release
        while (self.generation.load() == gen) {
            self.event.wait();
        }

        // Reset event for next generation if needed
        if (self.count.load() == self.parties) {
            self.event.reset();
        }

        return index;
    }

    /// Get number of parties currently waiting.
    pub fn waiting(self: *const Self) u32 {
        return self.parties - self.count.load();
    }

    /// Get the number of parties.
    pub fn getParties(self: *const Self) u32 {
        return self.parties;
    }

    /// Check if barrier is broken (not used in this simple implementation).
    pub fn isBroken(_: *const Self) bool {
        return false;
    }
};

/// Once ensures a function is executed exactly once.
pub const Once = struct {
    const Self = @This();

    const UNINIT: u32 = 0;
    const RUNNING: u32 = 1;
    const DONE: u32 = 2;

    state: atomic.Atomic(u32),
    event: std.Thread.ResetEvent,

    pub fn init() Self {
        return .{
            .state = atomic.Atomic(u32).init(UNINIT),
            .event = .{},
        };
    }

    /// Execute func exactly once, regardless of how many threads call this.
    pub fn call(self: *Self, comptime func: fn () void) void {
        if (self.state.load() == DONE) {
            return;
        }

        // Try to become the executor
        const old = self.state.compareAndSwapStrong(UNINIT, RUNNING);
        if (old == null) {
            // We won the race - execute the function
            func();
            self.state.store(DONE);
            self.event.set();
            return;
        }

        // Someone else is running or done - wait
        while (self.state.load() != DONE) {
            self.event.wait();
        }
    }

    /// Execute func with context exactly once.
    pub fn callWithContext(self: *Self, comptime func: fn (*anyopaque) void, ctx: *anyopaque) void {
        if (self.state.load() == DONE) {
            return;
        }

        const old = self.state.compareAndSwapStrong(UNINIT, RUNNING);
        if (old == null) {
            func(ctx);
            self.state.store(DONE);
            self.event.set();
            return;
        }

        while (self.state.load() != DONE) {
            self.event.wait();
        }
    }

    /// Check if the function has been executed.
    pub fn isDone(self: *const Self) bool {
        return self.state.load() == DONE;
    }

    /// Reset for reuse (unsafe - ensure no one is waiting or calling).
    pub fn reset(self: *Self) void {
        self.state.store(UNINIT);
        self.event.reset();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "WaitGroup basic" {
    var wg = WaitGroup.init();

    try std.testing.expect(wg.isDone());

    wg.add(1);
    try std.testing.expect(!wg.isDone());

    wg.done();
    try std.testing.expect(wg.isDone());
}

test "WaitGroup add multiple" {
    var wg = WaitGroup.init();

    wg.add(5);
    try std.testing.expectEqual(@as(i32, 5), wg.counter());

    wg.done();
    wg.done();
    try std.testing.expectEqual(@as(i32, 3), wg.counter());

    wg.done();
    wg.done();
    wg.done();
    try std.testing.expect(wg.isDone());
}

test "WaitGroup wait when already done" {
    var wg = WaitGroup.init();
    wg.wait(); // Should return immediately
    try std.testing.expect(wg.isDone());
}

test "Latch countdown" {
    var latch = Latch.init(3);

    try std.testing.expect(!latch.isReleased());
    try std.testing.expectEqual(@as(u32, 3), latch.getCount());

    latch.countDown();
    try std.testing.expectEqual(@as(u32, 2), latch.getCount());

    latch.countDown();
    latch.countDown();

    try std.testing.expect(latch.isReleased());
}

test "Once execution" {
    var once = Once.init();

    try std.testing.expect(!once.isDone());

    // Call multiple times - should only execute once
    once.call(struct {
        fn f() void {}
    }.f);

    try std.testing.expect(once.isDone());

    once.call(struct {
        fn f() void {}
    }.f);

    try std.testing.expect(once.isDone());
}

test "Barrier single thread" {
    var barrier = Barrier.init(1);

    const index = barrier.wait();
    try std.testing.expectEqual(@as(u32, 0), index);
}

test "WaitGroup timeout" {
    var wg = WaitGroup.init();
    wg.add(1);

    // Should timeout since we never call done()
    const result = wg.waitTimeout(1_000_000); // 1ms
    try std.testing.expect(!result);

    wg.done();
}

test "Latch timeout" {
    var latch = Latch.init(1);

    // Should timeout
    const result = latch.waitTimeout(1_000_000); // 1ms
    try std.testing.expect(!result);

    latch.countDown();
    try std.testing.expect(latch.isReleased());
}
