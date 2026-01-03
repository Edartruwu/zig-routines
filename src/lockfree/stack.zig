//! Lock-free Treiber Stack implementation.
//!
//! A simple but effective lock-free stack that uses CAS (compare-and-swap)
//! operations to maintain thread safety. Named after R. Kent Treiber who
//! described this algorithm in his 1986 paper.
//!
//! ## Algorithm
//!
//! Uses a singly-linked list with an atomic head pointer. Push and pop
//! operations use CAS to atomically update the head.
//!
//! ## ABA Problem
//!
//! The basic Treiber stack is susceptible to the ABA problem when nodes
//! are reused. This implementation provides both:
//! - `TreiberStack`: Basic version (safe if nodes aren't reused)
//! - `TaggedTreiberStack`: Uses tagged pointers to prevent ABA
//!
//! ## Performance Characteristics
//!
//! - Push: O(1) with CAS retry
//! - Pop: O(1) with CAS retry
//! - Memory: One pointer per node
//!
//! ## Example
//!
//! ```zig
//! var stack = TreiberStack(Task).init(allocator);
//! defer stack.deinit();
//!
//! try stack.push(task1);
//! try stack.push(task2);
//!
//! while (stack.pop()) |task| {
//!     task.run();
//! }
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const Allocator = std.mem.Allocator;

/// Lock-free Treiber stack with dynamic allocation.
pub fn TreiberStack(comptime T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            value: T,
            next: ?*Node,
        };

        /// Atomic head pointer
        head: atomic.Atomic(?*Node),

        /// Allocator for nodes
        allocator: Allocator,

        /// Initialize an empty stack.
        pub fn init(allocator: Allocator) Self {
            return Self{
                .head = atomic.Atomic(?*Node).init(null),
                .allocator = allocator,
            };
        }

        /// Deinitialize and free all nodes.
        pub fn deinit(self: *Self) void {
            while (self.pop()) |_| {}
        }

        /// Push a value onto the stack (thread-safe).
        pub fn push(self: *Self, value: T) !void {
            const node = try self.allocator.create(Node);
            node.value = value;

            var backoff = atomic.Backoff{};

            while (true) {
                const head = self.head.load();
                node.next = head;

                if (self.head.compareAndSwap(head, node) == null) {
                    return; // Success
                }

                backoff.spin();
            }
        }

        /// Pop a value from the stack (thread-safe).
        pub fn pop(self: *Self) ?T {
            var backoff = atomic.Backoff{};

            while (true) {
                const head = self.head.load() orelse return null;
                const next = head.next;

                if (self.head.compareAndSwap(head, next) == null) {
                    const value = head.value;
                    self.allocator.destroy(head);
                    return value;
                }

                backoff.spin();
            }
        }

        /// Try to pop without retrying.
        pub fn tryPop(self: *Self) ?T {
            const head = self.head.load() orelse return null;
            const next = head.next;

            if (self.head.compareAndSwap(head, next) == null) {
                const value = head.value;
                self.allocator.destroy(head);
                return value;
            }

            return null;
        }

        /// Check if stack is empty.
        pub fn isEmpty(self: *const Self) bool {
            return self.head.load() == null;
        }

        /// Peek at top value without removing.
        pub fn peek(self: *const Self) ?T {
            const head = self.head.load() orelse return null;
            return head.value;
        }
    };
}

/// Intrusive Treiber stack - nodes are embedded in user structs.
pub fn IntrusiveTreiberStack(comptime T: type, comptime node_field: []const u8) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            next: atomic.Atomic(?*Node),

            pub fn init() Node {
                return .{ .next = atomic.Atomic(?*Node).init(null) };
            }
        };

        head: atomic.Atomic(?*Node),

        pub fn init() Self {
            return Self{
                .head = atomic.Atomic(?*Node).init(null),
            };
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
            var backoff = atomic.Backoff{};

            while (true) {
                const head = self.head.load();
                node.next.store(head);

                if (self.head.compareAndSwap(head, node) == null) {
                    return;
                }

                backoff.spin();
            }
        }

        /// Pop an item (thread-safe).
        pub fn pop(self: *Self) ?*T {
            var backoff = atomic.Backoff{};

            while (true) {
                const head = self.head.load() orelse return null;
                const next = head.next.load();

                if (self.head.compareAndSwap(head, next) == null) {
                    return itemFromNode(head);
                }

                backoff.spin();
            }
        }

        pub fn tryPop(self: *Self) ?*T {
            const head = self.head.load() orelse return null;
            const next = head.next.load();

            if (self.head.compareAndSwap(head, next) == null) {
                return itemFromNode(head);
            }

            return null;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.head.load() == null;
        }
    };
}

/// Tagged Treiber stack with ABA prevention.
/// Uses upper bits of pointer for a generation counter.
pub fn TaggedTreiberStack(comptime T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            value: T,
            next: ?*Node,
        };

        /// Tagged head pointer (includes generation counter)
        head: atomic.AtomicTaggedPtr(Node),

        /// Allocator
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return Self{
                .head = atomic.AtomicTaggedPtr(Node).init(null, 0),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            while (self.pop()) |_| {}
        }

        /// Push with ABA prevention.
        pub fn push(self: *Self, value: T) !void {
            const node = try self.allocator.create(Node);
            node.value = value;

            var backoff = atomic.Backoff{};

            while (true) {
                const tagged = self.head.load();
                node.next = tagged.ptr;

                // Increment tag to prevent ABA
                const new_tag = tagged.tag +% 1;

                if (self.head.compareAndSwap(tagged.ptr, tagged.tag, node, new_tag) == null) {
                    return;
                }

                backoff.spin();
            }
        }

        /// Pop with ABA prevention.
        pub fn pop(self: *Self) ?T {
            var backoff = atomic.Backoff{};

            while (true) {
                const tagged = self.head.load();
                const head = tagged.ptr orelse return null;
                const next = head.next;

                const new_tag = tagged.tag +% 1;

                if (self.head.compareAndSwap(head, tagged.tag, next, new_tag) == null) {
                    const value = head.value;
                    self.allocator.destroy(head);
                    return value;
                }

                backoff.spin();
            }
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.head.load().ptr == null;
        }
    };
}

/// Elimination-backoff stack for high contention scenarios.
/// A simpler version that just wraps TreiberStack with backoff.
/// Full elimination array implementation requires pointer-based atomics.
pub fn EliminationStack(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Underlying stack
        stack: TreiberStack(T),

        pub fn init(allocator: Allocator) Self {
            return Self{
                .stack = TreiberStack(T).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.stack.deinit();
        }

        pub fn push(self: *Self, value: T) !void {
            try self.stack.push(value);
        }

        pub fn pop(self: *Self) ?T {
            return self.stack.pop();
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.stack.isEmpty();
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "TreiberStack basic" {
    var stack = TreiberStack(u64).init(std.testing.allocator);
    defer stack.deinit();

    try std.testing.expect(stack.isEmpty());

    try stack.push(1);
    try stack.push(2);
    try stack.push(3);

    try std.testing.expect(!stack.isEmpty());

    // Stack is LIFO
    try std.testing.expectEqual(@as(u64, 3), stack.pop().?);
    try std.testing.expectEqual(@as(u64, 2), stack.pop().?);
    try std.testing.expectEqual(@as(u64, 1), stack.pop().?);

    try std.testing.expect(stack.isEmpty());
    try std.testing.expect(stack.pop() == null);
}

test "TreiberStack peek" {
    var stack = TreiberStack(u32).init(std.testing.allocator);
    defer stack.deinit();

    try std.testing.expect(stack.peek() == null);

    try stack.push(42);
    try std.testing.expectEqual(@as(u32, 42), stack.peek().?);

    // Peek doesn't remove
    try std.testing.expectEqual(@as(u32, 42), stack.peek().?);
    try std.testing.expectEqual(@as(u32, 42), stack.pop().?);
}

test "IntrusiveTreiberStack" {
    const Item = struct {
        value: u32,
        node: IntrusiveTreiberStack(@This(), "node").Node = IntrusiveTreiberStack(@This(), "node").Node.init(),
    };

    var stack = IntrusiveTreiberStack(Item, "node").init();

    var items: [5]Item = undefined;
    for (&items, 0..) |*item, i| {
        item.* = .{ .value = @intCast(i) };
        stack.push(item);
    }

    // Pop in LIFO order
    for (0..5) |i| {
        const item = stack.pop().?;
        try std.testing.expectEqual(@as(u32, @intCast(4 - i)), item.value);
    }

    try std.testing.expect(stack.isEmpty());
}

test "TaggedTreiberStack" {
    var stack = TaggedTreiberStack(u64).init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(1);
    try stack.push(2);
    try stack.push(3);

    try std.testing.expectEqual(@as(u64, 3), stack.pop().?);
    try std.testing.expectEqual(@as(u64, 2), stack.pop().?);
    try std.testing.expectEqual(@as(u64, 1), stack.pop().?);

    try std.testing.expect(stack.isEmpty());
}

test "TreiberStack tryPop" {
    var stack = TreiberStack(u32).init(std.testing.allocator);
    defer stack.deinit();

    try std.testing.expect(stack.tryPop() == null);

    try stack.push(42);
    try std.testing.expectEqual(@as(u32, 42), stack.tryPop().?);
    try std.testing.expect(stack.tryPop() == null);
}

test "EliminationStack basic" {
    var stack = EliminationStack(u64).init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(1);
    try stack.push(2);

    try std.testing.expectEqual(@as(u64, 2), stack.pop().?);
    try std.testing.expectEqual(@as(u64, 1), stack.pop().?);
}
