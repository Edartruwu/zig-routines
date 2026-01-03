//! Lock-free Chase-Lev work-stealing deque.
//!
//! This deque allows one thread (the owner) to push and pop from the bottom,
//! while other threads (stealers) can steal from the top. It's the foundation
//! of work-stealing schedulers.
//!
//! ## Algorithm
//!
//! Based on "Dynamic Circular Work-Stealing Deque" by Chase and Lev (2005),
//! with improvements from "Correct and Efficient Work-Stealing for Weak
//! Memory Models" by Lê et al. (2013).
//!
//! ## Operations
//!
//! - `push(task)`: Owner pushes to bottom (O(1) amortized)
//! - `pop()`: Owner pops from bottom (O(1))
//! - `steal()`: Stealer steals from top (O(1))
//!
//! ## Usage Pattern
//!
//! ```zig
//! // Worker thread owns a deque
//! var deque = try WorkStealingDeque(*Task).init(allocator);
//!
//! // Push local work
//! try deque.push(task);
//!
//! // Pop own work (LIFO for locality)
//! if (deque.pop()) |task| {
//!     task.run();
//! }
//!
//! // Other threads can steal (FIFO for fairness)
//! if (deque.steal()) |result| {
//!     switch (result) {
//!         .success => |task| task.run(),
//!         .empty => {},
//!         .abort => {}, // Retry
//!     }
//! }
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const Allocator = std.mem.Allocator;

/// Result of a steal operation.
pub fn StealResult(comptime T: type) type {
    return union(enum) {
        /// Successfully stole a value
        success: T,
        /// Deque was empty
        empty: void,
        /// Operation aborted due to contention, retry
        abort: void,
    };
}

/// Lock-free work-stealing deque.
///
/// The owner thread can push and pop from the bottom.
/// Stealer threads can steal from the top.
pub fn WorkStealingDeque(comptime T: type) type {
    return struct {
        const Self = @This();
        const MIN_CAPACITY = 32;

        /// Circular buffer that can grow
        const Buffer = struct {
            data: []T,
            capacity: usize,
            mask: usize,

            fn init(allocator: Allocator, cap: usize) !*Buffer {
                const self = try allocator.create(Buffer);
                self.data = try allocator.alloc(T, cap);
                self.capacity = cap;
                self.mask = cap - 1;
                return self;
            }

            fn deinit(self: *Buffer, allocator: Allocator) void {
                allocator.free(self.data);
                allocator.destroy(self);
            }

            fn get(self: *Buffer, index: isize) T {
                const i = @as(usize, @intCast(@mod(index, @as(isize, @intCast(self.capacity)))));
                return self.data[i];
            }

            fn put(self: *Buffer, index: isize, value: T) void {
                const i = @as(usize, @intCast(@mod(index, @as(isize, @intCast(self.capacity)))));
                self.data[i] = value;
            }

            fn grow(self: *Buffer, allocator: Allocator, bottom: isize, top: isize) !*Buffer {
                const new_cap = self.capacity * 2;
                const new_buf = try Buffer.init(allocator, new_cap);

                // Copy existing elements
                var i = top;
                while (i < bottom) : (i += 1) {
                    new_buf.put(i, self.get(i));
                }

                return new_buf;
            }
        };

        /// Current buffer
        buffer: atomic.Atomic(*Buffer),

        /// Bottom index - modified only by owner
        bottom: atomic.Atomic(isize),

        /// Top index - modified by stealers
        top: atomic.Atomic(isize),

        /// Allocator for buffer management
        allocator: Allocator,

        /// Old buffers pending deallocation
        garbage: std.ArrayListUnmanaged(*Buffer),

        /// Initialize a new work-stealing deque.
        pub fn init(allocator: Allocator) !Self {
            const buffer = try Buffer.init(allocator, MIN_CAPACITY);

            return Self{
                .buffer = atomic.Atomic(*Buffer).init(buffer),
                .bottom = atomic.Atomic(isize).init(0),
                .top = atomic.Atomic(isize).init(0),
                .allocator = allocator,
                .garbage = .{},
            };
        }

        /// Deinitialize and free all resources.
        pub fn deinit(self: *Self) void {
            // Free current buffer
            self.buffer.load().deinit(self.allocator);

            // Free any old buffers
            for (self.garbage.items) |buf| {
                buf.deinit(self.allocator);
            }
            self.garbage.deinit(self.allocator);
        }

        /// Push a value to the bottom (owner only).
        pub fn push(self: *Self, value: T) !void {
            const bottom = self.bottom.load();
            const top = self.top.raw().load(.acquire);
            var buf = self.buffer.load();

            const size = bottom - top;
            if (size >= @as(isize, @intCast(buf.capacity - 1))) {
                // Buffer is full, grow it
                const new_buf = try buf.grow(self.allocator, bottom, top);
                try self.garbage.append(self.allocator, buf);
                self.buffer.store(new_buf);
                buf = new_buf;
            }

            buf.put(bottom, value);

            // Release fence to ensure the write is visible before updating bottom
            self.bottom.raw().store(bottom + 1, .release);
        }

        /// Pop a value from the bottom (owner only).
        pub fn pop(self: *Self) ?T {
            var bottom = self.bottom.load();
            const buf = self.buffer.load();

            bottom -= 1;
            self.bottom.raw().store(bottom, .seq_cst);

            const top = self.top.raw().load(.seq_cst);
            const size = bottom - top;

            if (size < 0) {
                // Deque is empty
                self.bottom.store(top);
                return null;
            }

            const value = buf.get(bottom);

            if (size > 0) {
                // There are still items, no contention possible
                return value;
            }

            // This is the last item, race with stealers
            if (self.top.compareAndSwapStrong(top, top + 1) != null) {
                // Lost the race, queue is now empty
                self.bottom.store(top + 1);
                return null;
            }

            self.bottom.store(top + 1);
            return value;
        }

        /// Steal a value from the top (stealers).
        pub fn steal(self: *Self) StealResult(T) {
            const top = self.top.raw().load(.acquire);
            const bottom = self.bottom.raw().load(.acquire);

            const size = bottom - top;
            if (size <= 0) {
                return .empty;
            }

            const buf = self.buffer.load();
            const value = buf.get(top);

            // Try to increment top
            if (self.top.compareAndSwap(top, top + 1) != null) {
                // Lost the race with another stealer or pop
                return .abort;
            }

            return .{ .success = value };
        }

        /// Check if deque is empty.
        pub fn isEmpty(self: *const Self) bool {
            const bottom = self.bottom.load();
            const top = self.top.load();
            return bottom <= top;
        }

        /// Get approximate number of items.
        pub fn len(self: *const Self) usize {
            const bottom = self.bottom.load();
            const top = self.top.load();
            const size = bottom - top;
            return if (size > 0) @intCast(size) else 0;
        }
    };
}

/// Stealer handle for work-stealing deques.
/// Multiple stealers can be created from a single deque.
pub fn Stealer(comptime T: type) type {
    return struct {
        const Self = @This();

        deque: *WorkStealingDeque(T),

        pub fn init(deque: *WorkStealingDeque(T)) Self {
            return .{ .deque = deque };
        }

        pub fn steal(self: *Self) StealResult(T) {
            return self.deque.steal();
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.deque.isEmpty();
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "WorkStealingDeque push and pop" {
    var deque = try WorkStealingDeque(u64).init(std.testing.allocator);
    defer deque.deinit();

    try std.testing.expect(deque.isEmpty());

    // Push values
    try deque.push(1);
    try deque.push(2);
    try deque.push(3);

    try std.testing.expectEqual(@as(usize, 3), deque.len());
    try std.testing.expect(!deque.isEmpty());

    // Pop returns in LIFO order (from bottom)
    try std.testing.expectEqual(@as(u64, 3), deque.pop().?);
    try std.testing.expectEqual(@as(u64, 2), deque.pop().?);
    try std.testing.expectEqual(@as(u64, 1), deque.pop().?);

    try std.testing.expect(deque.isEmpty());
    try std.testing.expect(deque.pop() == null);
}

test "WorkStealingDeque steal" {
    var deque = try WorkStealingDeque(u64).init(std.testing.allocator);
    defer deque.deinit();

    try deque.push(1);
    try deque.push(2);
    try deque.push(3);

    // Steal returns in FIFO order (from top)
    const result1 = deque.steal();
    try std.testing.expectEqual(StealResult(u64){ .success = 1 }, result1);

    const result2 = deque.steal();
    try std.testing.expectEqual(StealResult(u64){ .success = 2 }, result2);

    const result3 = deque.steal();
    try std.testing.expectEqual(StealResult(u64){ .success = 3 }, result3);

    const result4 = deque.steal();
    try std.testing.expectEqual(StealResult(u64).empty, result4);
}

test "WorkStealingDeque grow" {
    var deque = try WorkStealingDeque(u32).init(std.testing.allocator);
    defer deque.deinit();

    // Push more than initial capacity
    for (0..100) |i| {
        try deque.push(@intCast(i));
    }

    try std.testing.expectEqual(@as(usize, 100), deque.len());

    // Pop all (LIFO order)
    var expected: u32 = 99;
    while (deque.pop()) |value| {
        try std.testing.expectEqual(expected, value);
        if (expected > 0) expected -= 1;
    }
}

test "WorkStealingDeque mixed push pop steal" {
    var deque = try WorkStealingDeque(u32).init(std.testing.allocator);
    defer deque.deinit();

    // Push some values
    try deque.push(1);
    try deque.push(2);
    try deque.push(3);
    try deque.push(4);

    // Steal from top
    const stolen = deque.steal();
    try std.testing.expectEqual(StealResult(u32){ .success = 1 }, stolen);

    // Pop from bottom
    try std.testing.expectEqual(@as(u32, 4), deque.pop().?);

    // Remaining: 2, 3
    try std.testing.expectEqual(@as(usize, 2), deque.len());
}

test "Stealer" {
    var deque = try WorkStealingDeque(u64).init(std.testing.allocator);
    defer deque.deinit();

    try deque.push(42);

    var stealer = Stealer(u64).init(&deque);
    try std.testing.expect(!stealer.isEmpty());

    const result = stealer.steal();
    try std.testing.expectEqual(StealResult(u64){ .success = 42 }, result);

    try std.testing.expect(stealer.isEmpty());
}
