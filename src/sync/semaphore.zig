//! Counting semaphore for resource limiting.
//!
//! A semaphore maintains a count of available permits. acquire() blocks until
//! a permit is available, release() adds a permit back.
//!
//! ## Example
//!
//! ```zig
//! // Limit to 3 concurrent connections
//! var sem = Semaphore.init(3);
//!
//! sem.acquire();
//! defer sem.release();
//!
//! // Use limited resource
//! handleConnection();
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");

/// A counting semaphore.
pub const Semaphore = struct {
    const Self = @This();

    /// Number of available permits.
    permits: atomic.Atomic(i32),

    /// Event for waiting.
    event: std.Thread.ResetEvent,

    /// Number of waiters.
    waiters: atomic.Atomic(u32),

    /// Initialize with a number of permits.
    pub fn init(permits: u32) Self {
        return .{
            .permits = atomic.Atomic(i32).init(@intCast(permits)),
            .event = .{},
            .waiters = atomic.Atomic(u32).init(0),
        };
    }

    /// Acquire one permit, blocking if none available.
    pub fn acquire(self: *Self) void {
        self.acquireN(1);
    }

    /// Acquire N permits, blocking if not enough available.
    pub fn acquireN(self: *Self, n: u32) void {
        const amount: i32 = @intCast(n);
        var backoff: atomic.Backoff = .{};

        while (true) {
            const current = self.permits.load();

            if (current >= amount) {
                if (self.permits.compareAndSwap(current, current - amount) == null) {
                    return;
                }
            } else {
                // Not enough permits - wait
                _ = self.waiters.fetchAdd(1);
                self.event.wait();
                _ = self.waiters.fetchSub(1);
            }

            backoff.snooze();
        }
    }

    /// Release one permit.
    pub fn release(self: *Self) void {
        self.releaseN(1);
    }

    /// Release N permits.
    pub fn releaseN(self: *Self, n: u32) void {
        const amount: i32 = @intCast(n);
        _ = self.permits.fetchAdd(amount);

        // Wake waiters if any
        if (self.waiters.load() > 0) {
            self.event.set();
            std.Thread.yield() catch {};
            self.event.reset();
        }
    }

    /// Try to acquire one permit without blocking.
    pub fn tryAcquire(self: *Self) bool {
        return self.tryAcquireN(1);
    }

    /// Try to acquire N permits without blocking.
    pub fn tryAcquireN(self: *Self, n: u32) bool {
        const amount: i32 = @intCast(n);

        while (true) {
            const current = self.permits.load();

            if (current < amount) {
                return false;
            }

            if (self.permits.compareAndSwap(current, current - amount) == null) {
                return true;
            }
        }
    }

    /// Try to acquire with timeout.
    pub fn tryAcquireTimeout(self: *Self, timeout_ns: u64) bool {
        return self.tryAcquireNTimeout(1, timeout_ns);
    }

    /// Try to acquire N permits with timeout.
    pub fn tryAcquireNTimeout(self: *Self, n: u32, timeout_ns: u64) bool {
        const amount: i32 = @intCast(n);
        const deadline = @as(u64, @intCast(std.time.nanoTimestamp())) + timeout_ns;

        while (true) {
            const current = self.permits.load();

            if (current >= amount) {
                if (self.permits.compareAndSwap(current, current - amount) == null) {
                    return true;
                }
                continue;
            }

            const now = @as(u64, @intCast(std.time.nanoTimestamp()));
            if (now >= deadline) {
                return false;
            }

            _ = self.waiters.fetchAdd(1);
            self.event.timedWait(deadline - now) catch {};
            _ = self.waiters.fetchSub(1);
        }
    }

    /// Get current number of available permits.
    pub fn availablePermits(self: *const Self) u32 {
        const p = self.permits.load();
        return if (p > 0) @intCast(p) else 0;
    }

    /// Drain all available permits, returning how many were taken.
    pub fn drainPermits(self: *Self) u32 {
        while (true) {
            const current = self.permits.load();
            if (current <= 0) {
                return 0;
            }

            if (self.permits.compareAndSwap(current, 0) == null) {
                return @intCast(current);
            }
        }
    }

    /// Reduce permits by amount (for shrinking resource pools).
    pub fn reducePermits(self: *Self, reduction: u32) void {
        const amount: i32 = @intCast(reduction);
        _ = self.permits.fetchSub(amount);
    }
};

/// Binary semaphore (mutex-like, but can be released by different thread).
pub const BinarySemaphore = struct {
    const Self = @This();

    sem: Semaphore,

    /// Initialize (initially available).
    pub fn init() Self {
        return .{
            .sem = Semaphore.init(1),
        };
    }

    /// Initialize with initial state.
    pub fn initWithState(available: bool) Self {
        return .{
            .sem = Semaphore.init(if (available) 1 else 0),
        };
    }

    /// Wait until available.
    pub fn wait(self: *Self) void {
        self.sem.acquire();
    }

    /// Signal (make available).
    pub fn signal(self: *Self) void {
        // Ensure we don't exceed 1
        const current = self.sem.permits.load();
        if (current < 1) {
            self.sem.release();
        }
    }

    /// Try wait without blocking.
    pub fn tryWait(self: *Self) bool {
        return self.sem.tryAcquire();
    }

    /// Check if available.
    pub fn isAvailable(self: *const Self) bool {
        return self.sem.availablePermits() > 0;
    }
};

/// Weighted semaphore for resource pools with varying costs.
pub const WeightedSemaphore = struct {
    const Self = @This();

    sem: Semaphore,
    max_weight: u32,

    /// Initialize with maximum total weight.
    pub fn init(max_weight: u32) Self {
        return .{
            .sem = Semaphore.init(max_weight),
            .max_weight = max_weight,
        };
    }

    /// Acquire weight, blocking if not enough available.
    pub fn acquire(self: *Self, weight: u32) void {
        std.debug.assert(weight <= self.max_weight);
        self.sem.acquireN(weight);
    }

    /// Release weight.
    pub fn release(self: *Self, weight: u32) void {
        self.sem.releaseN(weight);
    }

    /// Try to acquire weight without blocking.
    pub fn tryAcquire(self: *Self, weight: u32) bool {
        if (weight > self.max_weight) {
            return false;
        }
        return self.sem.tryAcquireN(weight);
    }

    /// Get available weight.
    pub fn available(self: *const Self) u32 {
        return self.sem.availablePermits();
    }
};

/// Resource pool semaphore with RAII guard.
pub fn PoolSemaphore(comptime T: type) type {
    return struct {
        const Self = @This();

        sem: Semaphore,
        resources: []T,
        available_indices: std.ArrayList(usize),
        mutex: std.Thread.Mutex,

        pub fn init(allocator: std.mem.Allocator, resources: []T) !Self {
            var indices = std.ArrayList(usize).init(allocator);
            for (0..resources.len) |i| {
                try indices.append(i);
            }

            return .{
                .sem = Semaphore.init(@intCast(resources.len)),
                .resources = resources,
                .available_indices = indices,
                .mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.available_indices.deinit();
        }

        /// Acquire a resource.
        pub fn acquire(self: *Self) struct { resource: *T, index: usize } {
            self.sem.acquire();

            self.mutex.lock();
            defer self.mutex.unlock();

            const idx = self.available_indices.pop();
            return .{
                .resource = &self.resources[idx],
                .index = idx,
            };
        }

        /// Release a resource by index.
        pub fn release(self: *Self, index: usize) void {
            self.mutex.lock();
            self.available_indices.append(index) catch unreachable;
            self.mutex.unlock();

            self.sem.release();
        }

        /// Try to acquire without blocking.
        pub fn tryAcquire(self: *Self) ?struct { resource: *T, index: usize } {
            if (!self.sem.tryAcquire()) {
                return null;
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            const idx = self.available_indices.pop();
            return .{
                .resource = &self.resources[idx],
                .index = idx,
            };
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Semaphore basic" {
    var sem = Semaphore.init(3);

    try std.testing.expectEqual(@as(u32, 3), sem.availablePermits());

    sem.acquire();
    try std.testing.expectEqual(@as(u32, 2), sem.availablePermits());

    sem.acquire();
    sem.acquire();
    try std.testing.expectEqual(@as(u32, 0), sem.availablePermits());

    sem.release();
    try std.testing.expectEqual(@as(u32, 1), sem.availablePermits());

    sem.release();
    sem.release();
    try std.testing.expectEqual(@as(u32, 3), sem.availablePermits());
}

test "Semaphore tryAcquire" {
    var sem = Semaphore.init(1);

    try std.testing.expect(sem.tryAcquire());
    try std.testing.expect(!sem.tryAcquire()); // No permits left

    sem.release();
    try std.testing.expect(sem.tryAcquire());
    sem.release();
}

test "Semaphore acquireN" {
    var sem = Semaphore.init(5);

    sem.acquireN(3);
    try std.testing.expectEqual(@as(u32, 2), sem.availablePermits());

    try std.testing.expect(!sem.tryAcquireN(3)); // Only 2 available

    sem.releaseN(3);
    try std.testing.expectEqual(@as(u32, 5), sem.availablePermits());
}

test "Semaphore drain" {
    var sem = Semaphore.init(5);

    const drained = sem.drainPermits();
    try std.testing.expectEqual(@as(u32, 5), drained);
    try std.testing.expectEqual(@as(u32, 0), sem.availablePermits());

    // Drain when empty
    const drained2 = sem.drainPermits();
    try std.testing.expectEqual(@as(u32, 0), drained2);
}

test "BinarySemaphore" {
    var sem = BinarySemaphore.init();

    try std.testing.expect(sem.isAvailable());

    sem.wait();
    try std.testing.expect(!sem.isAvailable());

    sem.signal();
    try std.testing.expect(sem.isAvailable());

    // Multiple signals shouldn't increase beyond 1
    sem.signal();
    sem.signal();
    try std.testing.expectEqual(@as(u32, 1), sem.sem.availablePermits());
}

test "WeightedSemaphore" {
    var sem = WeightedSemaphore.init(10);

    try std.testing.expectEqual(@as(u32, 10), sem.available());

    sem.acquire(3);
    try std.testing.expectEqual(@as(u32, 7), sem.available());

    sem.acquire(5);
    try std.testing.expectEqual(@as(u32, 2), sem.available());

    try std.testing.expect(!sem.tryAcquire(3)); // Only 2 available

    sem.release(3);
    try std.testing.expect(sem.tryAcquire(3));

    sem.release(8); // Release all
    try std.testing.expectEqual(@as(u32, 10), sem.available());
}

test "Semaphore timeout" {
    var sem = Semaphore.init(0);

    // Should timeout since no permits
    const result = sem.tryAcquireTimeout(1_000_000); // 1ms
    try std.testing.expect(!result);

    // Add a permit and try again
    sem.release();
    const result2 = sem.tryAcquireTimeout(1_000_000);
    try std.testing.expect(result2);
}
