//! Unbounded channel implementation.
//!
//! An unbounded channel that never blocks on send (unless out of memory).
//! Uses a linked list of nodes for dynamic growth.
//!
//! ## Semantics
//!
//! - Send never blocks (allocates on demand)
//! - Receive blocks when empty
//! - Good for producer-consumer patterns where producer shouldn't block
//!
//! ## Example
//!
//! ```zig
//! var ch = try UnboundedChannel(u32).init(allocator);
//! defer ch.deinit();
//!
//! // Send never blocks
//! try ch.send(1);
//! try ch.send(2);
//! try ch.send(3);
//!
//! // Receive gets items in order
//! while (ch.tryRecv()) |value| {
//!     std.debug.print("{}\n", .{value});
//! }
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const channel = @import("channel.zig");
const Allocator = std.mem.Allocator;

const ChannelState = channel.ChannelState;
const SendError = channel.SendError;
const RecvError = channel.RecvError;
const Channel = channel.Channel;

/// Unbounded channel with dynamic allocation.
pub fn UnboundedChannel(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Node in the linked list.
        const Node = struct {
            value: T,
            next: ?*Node,
        };

        /// Head of the list (dequeue here).
        head: ?*Node,

        /// Tail of the list (enqueue here).
        tail: ?*Node,

        /// Number of items.
        count: usize,

        /// Channel state.
        state: atomic.Atomic(ChannelState),

        /// Mutex for synchronization.
        mutex: std.Thread.Mutex,

        /// Condition for receivers.
        not_empty: std.Thread.Condition,

        /// Allocator.
        allocator: Allocator,

        /// Initialize an unbounded channel.
        pub fn init(allocator: Allocator) !*Self {
            const self = try allocator.create(Self);

            self.* = Self{
                .head = null,
                .tail = null,
                .count = 0,
                .state = atomic.Atomic(ChannelState).init(.open),
                .mutex = .{},
                .not_empty = .{},
                .allocator = allocator,
            };

            return self;
        }

        /// Deinitialize and free all nodes.
        pub fn deinit(self: *Self) void {
            // Collect allocator before freeing
            const allocator = self.allocator;

            // Lock to get the list
            self.mutex.lock();
            const head = self.head;
            self.head = null;
            self.tail = null;
            self.mutex.unlock();

            // Free all nodes without lock
            var node = head;
            while (node) |n| {
                const next = n.next;
                allocator.destroy(n);
                node = next;
            }

            allocator.destroy(self);
        }

        /// Send a value (never blocks, may allocate).
        pub fn send(self: *Self, value: T) SendError!void {
            if (self.state.load() == .closed) {
                return SendError.Closed;
            }

            const node = self.allocator.create(Node) catch return SendError.Full;
            node.* = .{ .value = value, .next = null };

            self.mutex.lock();
            defer self.mutex.unlock();

            // Double-check closed under lock
            if (self.state.load() == .closed) {
                self.allocator.destroy(node);
                return SendError.Closed;
            }

            // Enqueue
            if (self.tail) |tail| {
                tail.next = node;
            } else {
                self.head = node;
            }
            self.tail = node;
            self.count += 1;

            // Signal receiver
            self.not_empty.signal();
        }

        /// Try to send (same as send for unbounded).
        pub fn trySend(self: *Self, value: T) SendError!void {
            return self.send(value);
        }

        /// Receive a value (blocks if empty).
        pub fn recv(self: *Self) RecvError!T {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Wait for item or closed
            while (self.head == null) {
                if (self.state.load() == .closed) {
                    return RecvError.Closed;
                }
                self.not_empty.wait(&self.mutex);
            }

            // Dequeue
            const node = self.head.?;
            self.head = node.next;
            if (self.head == null) {
                self.tail = null;
            }
            self.count -= 1;

            const value = node.value;
            self.allocator.destroy(node);

            return value;
        }

        /// Try to receive without blocking.
        pub fn tryRecv(self: *Self) RecvError!T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.head == null) {
                if (self.state.load() == .closed) {
                    return RecvError.Closed;
                }
                return RecvError.Empty;
            }

            const node = self.head.?;
            self.head = node.next;
            if (self.head == null) {
                self.tail = null;
            }
            self.count -= 1;

            const value = node.value;
            self.allocator.destroy(node);

            return value;
        }

        /// Close the channel.
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.state.store(.closed);
            self.not_empty.broadcast();
        }

        /// Check if closed.
        pub fn isClosed(self: *Self) bool {
            return self.state.load() == .closed;
        }

        /// Get number of items.
        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count;
        }

        /// Check if empty.
        pub fn isEmpty(self: *Self) bool {
            return self.len() == 0;
        }

        /// Get channel interface.
        pub fn asChannel(self: *Self) Channel(T) {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        const vtable = Channel(T).VTable{
            .send = sendVtable,
            .trySend = trySendVtable,
            .recv = recvVtable,
            .tryRecv = tryRecvVtable,
            .close = closeVtable,
            .isClosed = isClosedVtable,
            .len = lenVtable,
            .isEmpty = isEmptyVtable,
            .deinit = deinitVtable,
        };

        fn sendVtable(ptr: *anyopaque, value: T) SendError!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.send(value);
        }

        fn trySendVtable(ptr: *anyopaque, value: T) SendError!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.trySend(value);
        }

        fn recvVtable(ptr: *anyopaque) RecvError!T {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.recv();
        }

        fn tryRecvVtable(ptr: *anyopaque) RecvError!T {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.tryRecv();
        }

        fn closeVtable(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.close();
        }

        fn isClosedVtable(ptr: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.isClosed();
        }

        fn lenVtable(ptr: *anyopaque) usize {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.len();
        }

        fn isEmptyVtable(ptr: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.isEmpty();
        }

        fn deinitVtable(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.deinit();
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "UnboundedChannel basic" {
    var ch = try UnboundedChannel(u32).init(std.testing.allocator);
    defer ch.deinit();

    try std.testing.expect(!ch.isClosed());
    try std.testing.expect(ch.isEmpty());

    try ch.send(1);
    try ch.send(2);
    try ch.send(3);

    try std.testing.expectEqual(@as(usize, 3), ch.len());

    try std.testing.expectEqual(@as(u32, 1), try ch.recv());
    try std.testing.expectEqual(@as(u32, 2), try ch.recv());
    try std.testing.expectEqual(@as(u32, 3), try ch.recv());

    try std.testing.expect(ch.isEmpty());
}

test "UnboundedChannel many items" {
    var ch = try UnboundedChannel(u32).init(std.testing.allocator);
    defer ch.deinit();

    // Send many items
    for (0..100) |i| {
        try ch.send(@intCast(i));
    }

    try std.testing.expectEqual(@as(usize, 100), ch.len());

    // Receive all
    for (0..100) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), try ch.recv());
    }
}

test "UnboundedChannel close" {
    var ch = try UnboundedChannel(u32).init(std.testing.allocator);
    defer ch.deinit();

    try ch.send(42);
    ch.close();

    // Can receive pending
    try std.testing.expectEqual(@as(u32, 42), try ch.recv());

    // Now errors
    try std.testing.expectError(RecvError.Closed, ch.recv());
    try std.testing.expectError(SendError.Closed, ch.send(1));
}

test "UnboundedChannel tryRecv" {
    var ch = try UnboundedChannel(u32).init(std.testing.allocator);
    defer ch.deinit();

    try std.testing.expectError(RecvError.Empty, ch.tryRecv());

    try ch.send(42);
    try std.testing.expectEqual(@as(u32, 42), try ch.tryRecv());
    try std.testing.expectError(RecvError.Empty, ch.tryRecv());
}
