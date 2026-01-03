//! Intrusive data structures for zero-allocation queuing.
//!
//! Intrusive structures embed the node directly in the data type,
//! allowing queue operations without heap allocation. This is critical
//! for high-performance task scheduling where allocation latency matters.
//!
//! Example:
//! ```zig
//! const MyTask = struct {
//!     data: u32,
//!     node: intrusive.Node,  // Embedded node
//!
//!     fn fromNode(node: *intrusive.Node) *MyTask {
//!         return @fieldParentPtr("node", node);
//!     }
//! };
//! ```

const std = @import("std");
const atomic = @import("atomic.zig");

/// Intrusive doubly-linked list node.
/// Embed this in your struct to make it queue-able.
pub const Node = struct {
    const Self = @This();

    next: ?*Self = null,
    prev: ?*Self = null,

    /// Reset node to unlinked state.
    pub fn reset(self: *Self) void {
        self.next = null;
        self.prev = null;
    }

    /// Check if node is linked in a list.
    pub fn isLinked(self: *const Self) bool {
        return self.next != null or self.prev != null;
    }
};

/// Intrusive doubly-linked list (FIFO queue).
/// Not thread-safe - use with external synchronization or lock-free variants.
pub const List = struct {
    const Self = @This();

    head: ?*Node = null,
    tail: ?*Node = null,
    len: usize = 0,

    /// Initialize an empty list.
    pub fn init() Self {
        return .{};
    }

    /// Check if list is empty.
    pub fn isEmpty(self: *const Self) bool {
        return self.head == null;
    }

    /// Get number of elements.
    pub fn length(self: *const Self) usize {
        return self.len;
    }

    /// Push to back of list (enqueue).
    pub fn pushBack(self: *Self, node: *Node) void {
        std.debug.assert(!node.isLinked());

        node.next = null;
        node.prev = self.tail;

        if (self.tail) |tail| {
            tail.next = node;
        } else {
            self.head = node;
        }
        self.tail = node;
        self.len += 1;
    }

    /// Push to front of list.
    pub fn pushFront(self: *Self, node: *Node) void {
        std.debug.assert(!node.isLinked());

        node.prev = null;
        node.next = self.head;

        if (self.head) |head| {
            head.prev = node;
        } else {
            self.tail = node;
        }
        self.head = node;
        self.len += 1;
    }

    /// Pop from front of list (dequeue).
    pub fn popFront(self: *Self) ?*Node {
        const head = self.head orelse return null;

        self.head = head.next;
        if (self.head) |new_head| {
            new_head.prev = null;
        } else {
            self.tail = null;
        }

        head.reset();
        self.len -= 1;
        return head;
    }

    /// Pop from back of list.
    pub fn popBack(self: *Self) ?*Node {
        const tail = self.tail orelse return null;

        self.tail = tail.prev;
        if (self.tail) |new_tail| {
            new_tail.next = null;
        } else {
            self.head = null;
        }

        tail.reset();
        self.len -= 1;
        return tail;
    }

    /// Remove a specific node from the list.
    /// Node must be in this list.
    pub fn remove(self: *Self, node: *Node) void {
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.head = node.next;
        }

        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            self.tail = node.prev;
        }

        node.reset();
        self.len -= 1;
    }

    /// Peek at front without removing.
    pub fn peekFront(self: *const Self) ?*Node {
        return self.head;
    }

    /// Peek at back without removing.
    pub fn peekBack(self: *const Self) ?*Node {
        return self.tail;
    }

    /// Append another list to this one (O(1)).
    /// The other list becomes empty.
    pub fn append(self: *Self, other: *Self) void {
        if (other.isEmpty()) return;

        if (self.tail) |tail| {
            tail.next = other.head;
            other.head.?.prev = tail;
        } else {
            self.head = other.head;
        }
        self.tail = other.tail;
        self.len += other.len;

        other.* = .{};
    }

    /// Iterator for the list.
    pub fn iterator(self: *const Self) Iterator {
        return .{ .current = self.head };
    }

    pub const Iterator = struct {
        current: ?*Node,

        pub fn next(self: *Iterator) ?*Node {
            const node = self.current orelse return null;
            self.current = node.next;
            return node;
        }
    };
};

/// Atomic singly-linked list node for lock-free structures.
pub const AtomicNode = struct {
    const Self = @This();

    next: atomic.Atomic(?*Self),

    pub fn init() Self {
        return .{ .next = atomic.Atomic(?*Self).init(null) };
    }

    pub fn getNext(self: *const Self) ?*Self {
        return self.next.load();
    }

    pub fn setNext(self: *Self, node: ?*Self) void {
        self.next.store(node);
    }
};

/// Lock-free MPSC (multi-producer single-consumer) intrusive queue.
/// Multiple threads can push, single thread pops.
pub const MPSCQueue = struct {
    const Self = @This();

    /// Stub node to simplify empty queue handling
    stub: AtomicNode,
    /// Tail - producers push here (atomic)
    tail: atomic.Atomic(*AtomicNode),
    /// Head - consumer pops here (single-threaded access)
    head: *AtomicNode,

    pub fn init() Self {
        var self: Self = undefined;
        self.stub = AtomicNode.init();
        self.tail = atomic.Atomic(*AtomicNode).init(&self.stub);
        self.head = &self.stub;
        return self;
    }

    /// Push a node (thread-safe for multiple producers).
    pub fn push(self: *Self, node: *AtomicNode) void {
        node.setNext(null);

        // Atomically swap tail, get previous tail
        const prev = self.tail.swap(node);

        // Link previous tail to new node
        // This is the linearization point for the push
        prev.setNext(node);
    }

    /// Pop a node (single consumer only).
    /// Returns null if queue is empty or temporarily inconsistent.
    pub fn pop(self: *Self) ?*AtomicNode {
        var head = self.head;
        var next = head.getNext();

        // Skip stub node
        if (head == &self.stub) {
            if (next == null) return null;
            self.head = next.?;
            head = next.?;
            next = head.getNext();
        }

        if (next) |n| {
            self.head = n;
            return head;
        }

        // Check if we're at the tail
        if (head != self.tail.load()) {
            // Another push in progress, spin briefly
            return null;
        }

        // Re-insert stub to maintain invariant
        self.push(&self.stub);
        next = head.getNext();

        if (next) |n| {
            self.head = n;
            return head;
        }

        return null;
    }

    /// Check if queue appears empty.
    /// May return false negative during concurrent push.
    pub fn isEmpty(self: *const Self) bool {
        const head = self.head;
        return head == &self.stub and head.getNext() == null;
    }
};

/// Stack (LIFO) using intrusive nodes - single-threaded.
pub const Stack = struct {
    const Self = @This();

    top: ?*Node = null,
    len: usize = 0,

    pub fn init() Self {
        return .{};
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.top == null;
    }

    pub fn length(self: *const Self) usize {
        return self.len;
    }

    pub fn push(self: *Self, node: *Node) void {
        node.next = self.top;
        node.prev = null;
        self.top = node;
        self.len += 1;
    }

    pub fn pop(self: *Self) ?*Node {
        const top = self.top orelse return null;
        self.top = top.next;
        top.reset();
        self.len -= 1;
        return top;
    }

    pub fn peek(self: *const Self) ?*Node {
        return self.top;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Node basic operations" {
    var node = Node{};
    try std.testing.expect(!node.isLinked());

    node.next = &node;
    try std.testing.expect(node.isLinked());

    node.reset();
    try std.testing.expect(!node.isLinked());
}

test "List push and pop" {
    const Item = struct {
        value: u32,
        node: Node = .{},

        fn fromNode(node: *Node) *@This() {
            return @fieldParentPtr("node", node);
        }
    };

    var list = List.init();
    try std.testing.expect(list.isEmpty());

    var items: [5]Item = undefined;
    for (&items, 0..) |*item, i| {
        item.* = .{ .value = @intCast(i) };
        list.pushBack(&item.node);
    }

    try std.testing.expectEqual(@as(usize, 5), list.length());
    try std.testing.expect(!list.isEmpty());

    // Pop in FIFO order
    for (0..5) |i| {
        const node = list.popFront().?;
        const item = Item.fromNode(node);
        try std.testing.expectEqual(@as(u32, @intCast(i)), item.value);
    }

    try std.testing.expect(list.isEmpty());
    try std.testing.expect(list.popFront() == null);
}

test "List pushFront and popBack" {
    var list = List.init();

    var n1 = Node{};
    var n2 = Node{};
    var n3 = Node{};

    list.pushFront(&n1);
    list.pushFront(&n2);
    list.pushFront(&n3);

    // Order: n3 -> n2 -> n1
    try std.testing.expectEqual(&n3, list.peekFront().?);
    try std.testing.expectEqual(&n1, list.peekBack().?);

    try std.testing.expectEqual(&n1, list.popBack().?);
    try std.testing.expectEqual(&n2, list.popBack().?);
    try std.testing.expectEqual(&n3, list.popBack().?);
}

test "List remove" {
    var list = List.init();

    var n1 = Node{};
    var n2 = Node{};
    var n3 = Node{};

    list.pushBack(&n1);
    list.pushBack(&n2);
    list.pushBack(&n3);

    // Remove middle
    list.remove(&n2);
    try std.testing.expectEqual(@as(usize, 2), list.length());
    try std.testing.expectEqual(&n1, list.popFront().?);
    try std.testing.expectEqual(&n3, list.popFront().?);
}

test "List append" {
    var list1 = List.init();
    var list2 = List.init();

    var n1 = Node{};
    var n2 = Node{};
    var n3 = Node{};
    var n4 = Node{};

    list1.pushBack(&n1);
    list1.pushBack(&n2);
    list2.pushBack(&n3);
    list2.pushBack(&n4);

    list1.append(&list2);

    try std.testing.expectEqual(@as(usize, 4), list1.length());
    try std.testing.expect(list2.isEmpty());

    try std.testing.expectEqual(&n1, list1.popFront().?);
    try std.testing.expectEqual(&n2, list1.popFront().?);
    try std.testing.expectEqual(&n3, list1.popFront().?);
    try std.testing.expectEqual(&n4, list1.popFront().?);
}

test "List iterator" {
    var list = List.init();

    var nodes: [3]Node = .{ .{}, .{}, .{} };
    for (&nodes) |*n| {
        list.pushBack(n);
    }

    var iter = list.iterator();
    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "Stack operations" {
    const Item = struct {
        value: u32,
        node: Node = .{},

        fn fromNode(node: *Node) *@This() {
            return @fieldParentPtr("node", node);
        }
    };

    var stack = Stack.init();
    try std.testing.expect(stack.isEmpty());

    var items: [3]Item = undefined;
    for (&items, 0..) |*item, i| {
        item.* = .{ .value = @intCast(i) };
        stack.push(&item.node);
    }

    try std.testing.expectEqual(@as(usize, 3), stack.length());

    // Pop in LIFO order
    try std.testing.expectEqual(@as(u32, 2), Item.fromNode(stack.pop().?).value);
    try std.testing.expectEqual(@as(u32, 1), Item.fromNode(stack.pop().?).value);
    try std.testing.expectEqual(@as(u32, 0), Item.fromNode(stack.pop().?).value);

    try std.testing.expect(stack.isEmpty());
}

test "MPSCQueue push" {
    // Test that push operations don't crash
    // Full MPSC queue testing with proper pop semantics will be in Phase 2
    var queue = MPSCQueue.init();

    var node1 = AtomicNode.init();
    var node2 = AtomicNode.init();

    queue.push(&node1);
    queue.push(&node2);

    // Verify tail was updated
    try std.testing.expectEqual(&node2, queue.tail.load());
}
