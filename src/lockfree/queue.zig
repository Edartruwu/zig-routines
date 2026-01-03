//! Lock-free Multi-Producer Multi-Consumer (MPMC) bounded queue.
//!
//! This queue allows multiple threads to both push and pop concurrently.
//! It uses Dmitry Vyukov's bounded MPMC queue algorithm which provides
//! excellent performance under contention.
//!
//! ## Algorithm
//!
//! Based on Dmitry Vyukov's bounded MPMC queue, which uses sequence numbers
//! per cell to coordinate producers and consumers without locks.
//!
//! ## Performance Characteristics
//!
//! - Push/Pop: O(1) with CAS retry under contention
//! - Memory: Fixed-size ring buffer (power of 2)
//! - No ABA problem due to sequence numbers
//!
//! ## Example
//!
//! ```zig
//! var queue = try MPMCQueue(Task).init(allocator, 1024);
//! defer queue.deinit();
//!
//! // Any thread can push
//! if (queue.push(task)) {
//!     // Success
//! }
//!
//! // Any thread can pop
//! if (queue.pop()) |task| {
//!     task.run();
//! }
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const cache_line = @import("../core/cache_line.zig");
const Allocator = std.mem.Allocator;

/// Lock-free MPMC bounded queue (Vyukov algorithm).
pub fn MPMCQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Cell in the ring buffer
        const Cell = struct {
            sequence: atomic.Atomic(usize),
            value: T,
        };

        /// Ring buffer
        buffer: []Cell,

        /// Buffer size mask (capacity - 1)
        mask: usize,

        /// Enqueue position (cache-line padded)
        enqueue_pos: cache_line.Padded(atomic.Atomic(usize)),

        /// Dequeue position (cache-line padded)
        dequeue_pos: cache_line.Padded(atomic.Atomic(usize)),

        /// Allocator
        allocator: Allocator,

        /// Initialize a new MPMC queue.
        /// Capacity is rounded up to the next power of 2.
        pub fn init(allocator: Allocator, min_capacity: usize) !Self {
            const cap = std.math.ceilPowerOfTwo(usize, min_capacity) catch return error.OutOfMemory;
            const buffer = try allocator.alloc(Cell, cap);

            // Initialize sequence numbers
            for (buffer, 0..) |*cell, i| {
                cell.sequence = atomic.Atomic(usize).init(i);
            }

            return Self{
                .buffer = buffer,
                .mask = cap - 1,
                .enqueue_pos = cache_line.Padded(atomic.Atomic(usize)).init(atomic.Atomic(usize).init(0)),
                .dequeue_pos = cache_line.Padded(atomic.Atomic(usize)).init(atomic.Atomic(usize).init(0)),
                .allocator = allocator,
            };
        }

        /// Deinitialize and free the buffer.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        /// Push a value to the queue (thread-safe).
        /// Returns true if successful, false if queue is full.
        pub fn push(self: *Self, value: T) bool {
            var pos = self.enqueue_pos.get().load();

            while (true) {
                const cell = &self.buffer[pos & self.mask];
                const seq = cell.sequence.load();

                const diff = @as(isize, @bitCast(seq)) - @as(isize, @bitCast(pos));

                if (diff == 0) {
                    // Cell is ready for writing
                    if (self.enqueue_pos.get().compareAndSwap(pos, pos + 1) == null) {
                        // Successfully claimed the slot
                        cell.value = value;
                        // Release the cell for consumers
                        cell.sequence.store(pos + 1);
                        return true;
                    }
                    // Lost the race, reload and retry
                } else if (diff < 0) {
                    // Queue is full
                    return false;
                } else {
                    // Cell was already taken, reload position
                    pos = self.enqueue_pos.get().load();
                }
            }
        }

        /// Pop a value from the queue (thread-safe).
        /// Returns null if queue is empty.
        pub fn pop(self: *Self) ?T {
            var pos = self.dequeue_pos.get().load();

            while (true) {
                const cell = &self.buffer[pos & self.mask];
                const seq = cell.sequence.load();

                const diff = @as(isize, @bitCast(seq)) - @as(isize, @bitCast(pos + 1));

                if (diff == 0) {
                    // Cell is ready for reading
                    if (self.dequeue_pos.get().compareAndSwap(pos, pos + 1) == null) {
                        // Successfully claimed the slot
                        const value = cell.value;
                        // Release the cell for producers
                        cell.sequence.store(pos + self.mask + 1);
                        return value;
                    }
                    // Lost the race, reload and retry
                } else if (diff < 0) {
                    // Queue is empty
                    return null;
                } else {
                    // Cell was already taken, reload position
                    pos = self.dequeue_pos.get().load();
                }
            }
        }

        /// Try to push without spinning (single attempt).
        pub fn tryPush(self: *Self, value: T) bool {
            const pos = self.enqueue_pos.get().load();
            const cell = &self.buffer[pos & self.mask];
            const seq = cell.sequence.load();

            const diff = @as(isize, @bitCast(seq)) - @as(isize, @bitCast(pos));

            if (diff == 0) {
                if (self.enqueue_pos.get().compareAndSwap(pos, pos + 1) == null) {
                    cell.value = value;
                    cell.sequence.store(pos + 1);
                    return true;
                }
            }
            return false;
        }

        /// Try to pop without spinning (single attempt).
        pub fn tryPop(self: *Self) ?T {
            const pos = self.dequeue_pos.get().load();
            const cell = &self.buffer[pos & self.mask];
            const seq = cell.sequence.load();

            const diff = @as(isize, @bitCast(seq)) - @as(isize, @bitCast(pos + 1));

            if (diff == 0) {
                if (self.dequeue_pos.get().compareAndSwap(pos, pos + 1) == null) {
                    const value = cell.value;
                    cell.sequence.store(pos + self.mask + 1);
                    return value;
                }
            }
            return null;
        }

        /// Check if queue is empty (approximate).
        pub fn isEmpty(self: *const Self) bool {
            const enq = self.enqueue_pos.getConst().load();
            const deq = self.dequeue_pos.getConst().load();
            return enq == deq;
        }

        /// Check if queue is full (approximate).
        pub fn isFull(self: *const Self) bool {
            const enq = self.enqueue_pos.getConst().load();
            const deq = self.dequeue_pos.getConst().load();
            return enq - deq >= self.buffer.len;
        }

        /// Get approximate number of items.
        pub fn len(self: *const Self) usize {
            const enq = self.enqueue_pos.getConst().load();
            const deq = self.dequeue_pos.getConst().load();
            if (enq >= deq) {
                return enq - deq;
            }
            return 0;
        }

        /// Get the capacity.
        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }
    };
}

// Note: UnboundedMPMCQueue requires more complex implementation
// due to Zig's atomic constraints on optional types.
// For now, use MPMCQueue with sufficient capacity or implement
// a growing strategy on top of it.

// ============================================================================
// Tests
// ============================================================================

test "MPMCQueue basic" {
    var queue = try MPMCQueue(u64).init(std.testing.allocator, 8);
    defer queue.deinit();

    try std.testing.expect(queue.isEmpty());

    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));

    try std.testing.expect(!queue.isEmpty());
    try std.testing.expectEqual(@as(usize, 3), queue.len());

    try std.testing.expectEqual(@as(u64, 1), queue.pop().?);
    try std.testing.expectEqual(@as(u64, 2), queue.pop().?);
    try std.testing.expectEqual(@as(u64, 3), queue.pop().?);

    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(queue.pop() == null);
}

test "MPMCQueue capacity" {
    var queue = try MPMCQueue(u32).init(std.testing.allocator, 4);
    defer queue.deinit();

    // Fill the queue
    for (0..4) |i| {
        try std.testing.expect(queue.push(@intCast(i)));
    }

    // Should be full
    try std.testing.expect(queue.isFull());
    try std.testing.expect(!queue.push(100));

    // Pop one and push again
    _ = queue.pop();
    try std.testing.expect(queue.push(100));
}

test "MPMCQueue wrap around" {
    var queue = try MPMCQueue(u32).init(std.testing.allocator, 4);
    defer queue.deinit();

    // Fill and drain multiple times
    for (0..20) |i| {
        try std.testing.expect(queue.push(@intCast(i % 4)));
        try std.testing.expectEqual(@as(u32, @intCast(i % 4)), queue.pop().?);
    }
}

test "MPMCQueue tryPush tryPop" {
    var queue = try MPMCQueue(u64).init(std.testing.allocator, 4);
    defer queue.deinit();

    try std.testing.expect(queue.tryPush(42));
    try std.testing.expectEqual(@as(u64, 42), queue.tryPop().?);
    try std.testing.expect(queue.tryPop() == null);
}

