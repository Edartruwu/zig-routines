//! Lock-free Multi-Producer Single-Consumer (MPSC) queue.
//!
//! This queue allows multiple threads to push concurrently while a single
//! thread consumes. It's ideal for task submission scenarios where many
//! threads submit work to a single executor.
//!
//! ## Implementation
//!
//! Uses a linked list with atomic operations. Based on Dmitry Vyukov's
//! non-intrusive MPSC queue algorithm.
//!
//! ## Performance Characteristics
//!
//! - Push: O(1) - two atomic operations (swap + store)
//! - Pop: O(1) amortized - may need to wait for push completion
//! - Memory: Dynamic allocation per item (or use intrusive variant)
//!
//! ## Example
//!
//! ```zig
//! var queue = MPSCQueue(Task).init();
//!
//! // Multiple producer threads
//! queue.push(task);
//!
//! // Single consumer thread
//! while (queue.pop()) |task| {
//!     task.run();
//! }
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const Allocator = std.mem.Allocator;

/// Lock-free MPSC queue with dynamic allocation.
pub fn MPSCQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            value: T,
            next: atomic.Atomic(?*Node),

            fn init(value: T) Node {
                return .{
                    .value = value,
                    .next = atomic.Atomic(?*Node).init(null),
                };
            }
        };

        /// Stub node (heap-allocated to avoid self-referential pointer issues)
        stub: *Node,

        /// Tail pointer - producers push here
        tail: atomic.Atomic(*Node),

        /// Head pointer - consumer pops from here
        head: *Node,

        /// Allocator for nodes
        allocator: Allocator,

        /// Initialize a new MPSC queue.
        pub fn init(allocator: Allocator) !Self {
            const stub = try allocator.create(Node);
            stub.* = .{
                .value = undefined,
                .next = atomic.Atomic(?*Node).init(null),
            };
            return Self{
                .stub = stub,
                .tail = atomic.Atomic(*Node).init(stub),
                .head = stub,
                .allocator = allocator,
            };
        }

        /// Deinitialize and free all remaining nodes.
        pub fn deinit(self: *Self) void {
            // Pop and free all remaining items
            while (self.pop()) |_| {}

            // Free the stub node
            self.allocator.destroy(self.stub);
        }

        /// Push a value to the queue (thread-safe, multiple producers).
        pub fn push(self: *Self, value: T) !void {
            const node = try self.allocator.create(Node);
            node.* = Node.init(value);
            self.pushNode(node);
        }

        /// Push a pre-allocated node (for zero-allocation patterns).
        fn pushNode(self: *Self, node: *Node) void {
            node.next.store(null);

            // Atomically swap tail, getting the previous tail
            const prev = self.tail.swap(node);

            // Link previous node to new node
            // This is the linearization point
            prev.next.store(node);
        }

        /// Pop a value from the queue (single consumer only).
        pub fn pop(self: *Self) ?T {
            var head = self.head;
            var next = head.next.load();

            // Skip stub node if we're at it
            if (head == self.stub) {
                if (next == null) {
                    return null; // Queue is empty
                }
                self.head = next.?;
                head = next.?;
                next = head.next.load();
            }

            // If there's a next node, we can pop
            if (next) |n| {
                self.head = n;
                const value = head.value;
                self.allocator.destroy(head);
                return value;
            }

            // Check if we're at the tail
            if (head != self.tail.load()) {
                // A push is in progress, spin briefly
                return null;
            }

            // Re-insert stub to maintain queue invariant
            self.stub.next.store(null);
            self.pushNode(self.stub);

            next = head.next.load();
            if (next) |n| {
                self.head = n;
                const value = head.value;
                self.allocator.destroy(head);
                return value;
            }

            return null;
        }

        /// Try to pop, returning immediately if queue appears empty.
        pub fn tryPop(self: *Self) ?T {
            return self.pop();
        }

        /// Check if queue appears empty.
        /// Note: May return false negatives during concurrent push.
        pub fn isEmpty(self: *const Self) bool {
            const head = self.head;
            if (head == self.stub) {
                return head.next.load() == null;
            }
            return false;
        }
    };
}

/// Intrusive MPSC queue - nodes are embedded in user structs.
/// Zero allocation overhead for the queue itself.
pub fn IntrusiveMPSCQueue(comptime T: type, comptime node_field: []const u8) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            next: atomic.Atomic(?*Node),

            pub fn init() Node {
                return .{ .next = atomic.Atomic(?*Node).init(null) };
            }
        };

        /// Stub node
        stub: Node,

        /// Tail - producers push here
        tail: atomic.Atomic(*Node),

        /// Head - consumer pops from here
        head: *Node,

        /// Initialize the queue in-place (must be called after struct is positioned).
        pub fn prepare(self: *Self) void {
            self.stub = Node.init();
            self.tail = atomic.Atomic(*Node).init(&self.stub);
            self.head = &self.stub;
        }

        fn nodeFromItem(item: *T) *Node {
            return &@field(item, node_field);
        }

        fn itemFromNode(node: *Node) *T {
            return @fieldParentPtr(node_field, node);
        }

        /// Push an item (thread-safe).
        pub fn push(self: *Self, item: *T) void {
            const node = nodeFromItem(item);
            node.next.store(null);

            const prev = self.tail.swap(node);
            prev.next.store(node);
        }

        /// Pop an item (single consumer).
        pub fn pop(self: *Self) ?*T {
            var head = self.head;
            var next = head.next.load();

            // Skip stub
            if (head == &self.stub) {
                if (next == null) return null;
                self.head = next.?;
                head = next.?;
                next = head.next.load();
            }

            if (next) |n| {
                self.head = n;
                return itemFromNode(head);
            }

            if (head != self.tail.load()) {
                return null; // Push in progress
            }

            // Re-insert stub
            self.stub.next.store(null);
            const stub_node: *Node = &self.stub;
            const prev = self.tail.swap(stub_node);
            prev.next.store(stub_node);

            next = head.next.load();
            if (next) |n| {
                self.head = n;
                return itemFromNode(head);
            }

            return null;
        }

        pub fn isEmpty(self: *const Self) bool {
            const head = self.head;
            if (head == &self.stub) {
                return head.next.load() == null;
            }
            return false;
        }
    };
}

/// Bounded MPSC queue using a ring buffer.
/// Avoids allocation but has fixed capacity.
pub fn BoundedMPSCQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        const Cell = struct {
            sequence: atomic.Atomic(usize),
            value: T,
        };

        buffer: []Cell,
        mask: usize,
        head: atomic.Atomic(usize),
        tail: atomic.Atomic(usize),
        allocator: Allocator,

        pub fn init(allocator: Allocator, min_capacity: usize) !Self {
            const cap = std.math.ceilPowerOfTwo(usize, min_capacity) catch return error.OutOfMemory;
            const buffer = try allocator.alloc(Cell, cap);

            for (buffer, 0..) |*cell, i| {
                cell.sequence = atomic.Atomic(usize).init(i);
            }

            return Self{
                .buffer = buffer,
                .mask = cap - 1,
                .head = atomic.Atomic(usize).init(0),
                .tail = atomic.Atomic(usize).init(0),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        /// Push a value (thread-safe, multiple producers).
        /// Returns false if queue is full.
        pub fn push(self: *Self, value: T) bool {
            var pos = self.tail.load();

            while (true) {
                const cell = &self.buffer[pos & self.mask];
                const seq = cell.sequence.load();
                const diff = @as(isize, @bitCast(seq)) - @as(isize, @bitCast(pos));

                if (diff == 0) {
                    // Try to claim this slot
                    if (self.tail.compareAndSwap(pos, pos + 1) == null) {
                        // Success - write value
                        cell.value = value;
                        cell.sequence.store(pos + 1);
                        return true;
                    }
                } else if (diff < 0) {
                    // Queue is full
                    return false;
                } else {
                    // Slot was taken, retry
                    pos = self.tail.load();
                }
            }
        }

        /// Pop a value (single consumer only).
        pub fn pop(self: *Self) ?T {
            const pos = self.head.load();
            const cell = &self.buffer[pos & self.mask];
            const seq = cell.sequence.load();
            const diff = @as(isize, @bitCast(seq)) - @as(isize, @bitCast(pos + 1));

            if (diff == 0) {
                // Value is ready
                const value = cell.value;
                cell.sequence.store(pos + self.mask + 1);
                self.head.store(pos + 1);
                return value;
            }

            // Queue is empty or value not ready yet
            return null;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.head.load() == self.tail.load();
        }

        pub fn isFull(self: *const Self) bool {
            const tail = self.tail.load();
            const head = self.head.load();
            return tail - head >= self.buffer.len;
        }

        pub fn len(self: *const Self) usize {
            const tail = self.tail.load();
            const head = self.head.load();
            return tail - head;
        }

        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "MPSCQueue basic" {
    var queue = try MPSCQueue(u64).init(std.testing.allocator);
    defer queue.deinit();

    try std.testing.expect(queue.isEmpty());

    try queue.push(1);
    try queue.push(2);
    try queue.push(3);

    try std.testing.expect(!queue.isEmpty());

    try std.testing.expectEqual(@as(u64, 1), queue.pop().?);
    try std.testing.expectEqual(@as(u64, 2), queue.pop().?);
    try std.testing.expectEqual(@as(u64, 3), queue.pop().?);

    try std.testing.expect(queue.pop() == null);
}

test "MPSCQueue many items" {
    var queue = try MPSCQueue(u32).init(std.testing.allocator);
    defer queue.deinit();

    // Push many items
    for (0..100) |i| {
        try queue.push(@intCast(i));
    }

    // Pop and verify order
    for (0..100) |i| {
        const value = queue.pop() orelse {
            // May need to retry due to push completion delay
            std.atomic.spinLoopHint();
            try std.testing.expectEqual(@as(u32, @intCast(i)), queue.pop().?);
            continue;
        };
        try std.testing.expectEqual(@as(u32, @intCast(i)), value);
    }
}

test "IntrusiveMPSCQueue" {
    const Item = struct {
        value: u32,
        node: IntrusiveMPSCQueue(@This(), "node").Node = IntrusiveMPSCQueue(@This(), "node").Node.init(),
    };

    var queue: IntrusiveMPSCQueue(Item, "node") = undefined;
    queue.prepare();

    var items: [5]Item = undefined;
    for (&items, 0..) |*item, i| {
        item.* = .{ .value = @intCast(i) };
        queue.push(item);
    }

    // Pop all
    for (0..5) |i| {
        const item = queue.pop() orelse {
            std.atomic.spinLoopHint();
            try std.testing.expect(queue.pop() != null);
            continue;
        };
        try std.testing.expectEqual(@as(u32, @intCast(i)), item.value);
    }
}

test "BoundedMPSCQueue basic" {
    var queue = try BoundedMPSCQueue(u64).init(std.testing.allocator, 8);
    defer queue.deinit();

    try std.testing.expect(queue.isEmpty());

    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));

    try std.testing.expectEqual(@as(usize, 3), queue.len());

    try std.testing.expectEqual(@as(u64, 1), queue.pop().?);
    try std.testing.expectEqual(@as(u64, 2), queue.pop().?);
    try std.testing.expectEqual(@as(u64, 3), queue.pop().?);

    try std.testing.expect(queue.pop() == null);
}

test "BoundedMPSCQueue full" {
    var queue = try BoundedMPSCQueue(u32).init(std.testing.allocator, 4);
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
