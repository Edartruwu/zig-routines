//! Lock-free Single-Producer Single-Consumer (SPSC) bounded queue.
//!
//! This is the most efficient queue variant when you have exactly one
//! producer thread and one consumer thread. It achieves lock-freedom
//! through careful use of atomic operations and memory ordering.
//!
//! ## Performance Characteristics
//!
//! - Push: O(1) - single atomic store
//! - Pop: O(1) - single atomic load
//! - Memory: Fixed-size ring buffer (power of 2)
//! - Cache-friendly: Sequential access pattern
//!
//! ## Example
//!
//! ```zig
//! var queue = try SPSCQueue(u64).init(allocator, 1024);
//! defer queue.deinit();
//!
//! // Producer thread
//! _ = queue.push(42);
//!
//! // Consumer thread
//! if (queue.pop()) |value| {
//!     // Use value
//! }
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const cache_line = @import("../core/cache_line.zig");

/// Lock-free SPSC bounded queue using a ring buffer.
pub fn SPSCQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Ring buffer storage
        buffer: []T,

        /// Capacity (always power of 2)
        capacity: usize,

        /// Mask for fast modulo (capacity - 1)
        mask: usize,

        /// Head index - consumer reads from here (cache-line padded)
        head: cache_line.Padded(atomic.Atomic(usize)),

        /// Tail index - producer writes here (cache-line padded)
        tail: cache_line.Padded(atomic.Atomic(usize)),

        /// Cached head for producer (avoids false sharing)
        cached_head: usize,

        /// Cached tail for consumer (avoids false sharing)
        cached_tail: usize,

        /// Allocator used for buffer
        allocator: std.mem.Allocator,

        /// Initialize a new SPSC queue with the given capacity.
        /// Capacity will be rounded up to the next power of 2.
        pub fn init(allocator: std.mem.Allocator, min_capacity: usize) !Self {
            const capacity = std.math.ceilPowerOfTwo(usize, min_capacity) catch return error.OutOfMemory;
            const buffer = try allocator.alloc(T, capacity);

            return Self{
                .buffer = buffer,
                .capacity = capacity,
                .mask = capacity - 1,
                .head = cache_line.Padded(atomic.Atomic(usize)).init(atomic.Atomic(usize).init(0)),
                .tail = cache_line.Padded(atomic.Atomic(usize)).init(atomic.Atomic(usize).init(0)),
                .cached_head = 0,
                .cached_tail = 0,
                .allocator = allocator,
            };
        }

        /// Deinitialize the queue and free the buffer.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        /// Push a value to the queue (producer only).
        /// Returns true if successful, false if queue is full.
        pub fn push(self: *Self, value: T) bool {
            const tail = self.tail.get().load();
            const next_tail = (tail + 1) & self.mask;

            // Check if queue is full using cached head
            if (next_tail == self.cached_head) {
                // Refresh cached head
                self.cached_head = self.head.get().load();
                if (next_tail == self.cached_head) {
                    return false; // Queue is full
                }
            }

            // Write the value
            self.buffer[tail] = value;

            // Publish the write with release ordering
            self.tail.get().store(next_tail);

            return true;
        }

        /// Pop a value from the queue (consumer only).
        /// Returns null if queue is empty.
        pub fn pop(self: *Self) ?T {
            const head = self.head.get().load();

            // Check if queue is empty using cached tail
            if (head == self.cached_tail) {
                // Refresh cached tail
                self.cached_tail = self.tail.get().load();
                if (head == self.cached_tail) {
                    return null; // Queue is empty
                }
            }

            // Read the value
            const value = self.buffer[head];

            // Publish the read with release ordering
            const next_head = (head + 1) & self.mask;
            self.head.get().store(next_head);

            return value;
        }

        /// Try to push without blocking. Same as push() for SPSC.
        pub fn tryPush(self: *Self, value: T) bool {
            return self.push(value);
        }

        /// Try to pop without blocking. Same as pop() for SPSC.
        pub fn tryPop(self: *Self) ?T {
            return self.pop();
        }

        /// Check if queue is empty (approximate).
        pub fn isEmpty(self: *const Self) bool {
            return self.head.getConst().load() == self.tail.getConst().load();
        }

        /// Check if queue is full (approximate).
        pub fn isFull(self: *const Self) bool {
            const tail = self.tail.getConst().load();
            const head = self.head.getConst().load();
            return ((tail + 1) & self.mask) == head;
        }

        /// Get approximate number of items in queue.
        pub fn len(self: *const Self) usize {
            const tail = self.tail.getConst().load();
            const head = self.head.getConst().load();
            if (tail >= head) {
                return tail - head;
            } else {
                return self.capacity - head + tail;
            }
        }

        /// Get the capacity of the queue.
        pub fn getCapacity(self: *const Self) usize {
            return self.capacity - 1; // One slot is always empty
        }

        /// Push multiple values at once (batch operation).
        /// Returns the number of values successfully pushed.
        pub fn pushBatch(self: *Self, values: []const T) usize {
            var pushed: usize = 0;
            for (values) |value| {
                if (!self.push(value)) break;
                pushed += 1;
            }
            return pushed;
        }

        /// Pop multiple values at once (batch operation).
        /// Returns the number of values successfully popped.
        pub fn popBatch(self: *Self, out: []T) usize {
            var popped: usize = 0;
            while (popped < out.len) {
                if (self.pop()) |value| {
                    out[popped] = value;
                    popped += 1;
                } else {
                    break;
                }
            }
            return popped;
        }
    };
}

/// Unbounded SPSC queue using linked chunks.
/// Useful when you don't want to bound the queue size.
pub fn UnboundedSPSCQueue(comptime T: type) type {
    const ChunkSize = 64; // Number of items per chunk

    return struct {
        const Self = @This();

        const Chunk = struct {
            data: [ChunkSize]T,
            next: atomic.Atomic(?*Chunk),

            fn init() Chunk {
                return .{
                    .data = undefined,
                    .next = atomic.Atomic(?*Chunk).init(null),
                };
            }
        };

        /// Head chunk and index (consumer)
        head_chunk: *Chunk,
        head_index: usize,

        /// Tail chunk and index (producer)
        tail_chunk: *Chunk,
        tail_index: usize,

        /// Allocator for chunks
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !Self {
            const chunk = try allocator.create(Chunk);
            chunk.* = Chunk.init();

            return Self{
                .head_chunk = chunk,
                .head_index = 0,
                .tail_chunk = chunk,
                .tail_index = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            var chunk: ?*Chunk = self.head_chunk;
            while (chunk) |c| {
                const next = c.next.load();
                self.allocator.destroy(c);
                chunk = next;
            }
        }

        /// Push a value (never fails, may allocate).
        pub fn push(self: *Self, value: T) !void {
            if (self.tail_index == ChunkSize) {
                // Need a new chunk
                const new_chunk = try self.allocator.create(Chunk);
                new_chunk.* = Chunk.init();

                self.tail_chunk.next.store(new_chunk);
                self.tail_chunk = new_chunk;
                self.tail_index = 0;
            }

            self.tail_chunk.data[self.tail_index] = value;
            self.tail_index += 1;
        }

        /// Pop a value.
        pub fn pop(self: *Self) ?T {
            if (self.head_chunk == self.tail_chunk and self.head_index == self.tail_index) {
                return null; // Empty
            }

            if (self.head_index == ChunkSize) {
                // Move to next chunk
                const next = self.head_chunk.next.load() orelse return null;
                const old = self.head_chunk;
                self.head_chunk = next;
                self.head_index = 0;
                self.allocator.destroy(old);
            }

            const value = self.head_chunk.data[self.head_index];
            self.head_index += 1;
            return value;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.head_chunk == self.tail_chunk and self.head_index == self.tail_index;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "SPSCQueue basic operations" {
    var queue = try SPSCQueue(u64).init(std.testing.allocator, 8);
    defer queue.deinit();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(!queue.isFull());

    // Push some values
    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));

    try std.testing.expect(!queue.isEmpty());
    try std.testing.expectEqual(@as(usize, 3), queue.len());

    // Pop values in FIFO order
    try std.testing.expectEqual(@as(u64, 1), queue.pop().?);
    try std.testing.expectEqual(@as(u64, 2), queue.pop().?);
    try std.testing.expectEqual(@as(u64, 3), queue.pop().?);

    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(queue.pop() == null);
}

test "SPSCQueue capacity" {
    var queue = try SPSCQueue(u32).init(std.testing.allocator, 4);
    defer queue.deinit();

    // Capacity is rounded to power of 2, minus 1 for the empty slot
    try std.testing.expectEqual(@as(usize, 3), queue.getCapacity());

    // Fill the queue
    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));

    // Queue should be full
    try std.testing.expect(queue.isFull());
    try std.testing.expect(!queue.push(4)); // Should fail

    // Pop one and push again
    _ = queue.pop();
    try std.testing.expect(queue.push(4));
}

test "SPSCQueue wrap around" {
    var queue = try SPSCQueue(u32).init(std.testing.allocator, 4);
    defer queue.deinit();

    // Fill and drain multiple times to test wrap-around
    for (0..10) |i| {
        try std.testing.expect(queue.push(@intCast(i)));
        try std.testing.expectEqual(@as(u32, @intCast(i)), queue.pop().?);
    }

    try std.testing.expect(queue.isEmpty());
}

test "SPSCQueue batch operations" {
    var queue = try SPSCQueue(u32).init(std.testing.allocator, 16);
    defer queue.deinit();

    const values = [_]u32{ 1, 2, 3, 4, 5 };
    const pushed = queue.pushBatch(&values);
    try std.testing.expectEqual(@as(usize, 5), pushed);

    var out: [5]u32 = undefined;
    const popped = queue.popBatch(&out);
    try std.testing.expectEqual(@as(usize, 5), popped);
    try std.testing.expectEqualSlices(u32, &values, &out);
}

test "UnboundedSPSCQueue basic" {
    var queue = try UnboundedSPSCQueue(u64).init(std.testing.allocator);
    defer queue.deinit();

    try std.testing.expect(queue.isEmpty());

    // Push many values (will allocate chunks)
    for (0..200) |i| {
        try queue.push(@intCast(i));
    }

    try std.testing.expect(!queue.isEmpty());

    // Pop all values
    for (0..200) |i| {
        try std.testing.expectEqual(@as(u64, @intCast(i)), queue.pop().?);
    }

    try std.testing.expect(queue.isEmpty());
}
