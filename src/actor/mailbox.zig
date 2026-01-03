//! Actor mailbox for message passing.
//!
//! A mailbox is a thread-safe message queue that actors use to receive
//! messages. It supports both bounded and unbounded operation modes.
//!
//! ## Example
//!
//! ```zig
//! var mailbox = try Mailbox(MyMessage).init(allocator, .{});
//! defer mailbox.deinit();
//!
//! // Send a message
//! try mailbox.send(.{ .data = 42 });
//!
//! // Receive a message
//! if (mailbox.receive()) |msg| {
//!     handleMessage(msg);
//! }
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const Allocator = std.mem.Allocator;

/// Mailbox configuration.
pub const MailboxConfig = struct {
    /// Maximum capacity (0 = unbounded).
    capacity: usize = 0,

    /// High water mark for backpressure.
    high_water_mark: usize = 1000,

    /// Enable priority queue mode.
    priority_queue: bool = false,
};

/// Mailbox state.
pub const MailboxState = enum(u8) {
    /// Mailbox is open and accepting messages.
    open = 0,
    /// Mailbox is closed, no new messages accepted.
    closed = 1,
    /// Mailbox is suspended (messages queued but not delivered).
    suspended = 2,
};

/// A thread-safe message queue for actors.
pub fn Mailbox(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Message node in the queue.
        const Node = struct {
            value: T,
            next: ?*Node,
            priority: u8,
        };

        /// Head of the queue (oldest message).
        head: ?*Node,

        /// Tail of the queue (newest message).
        tail: ?*Node,

        /// Number of messages in the queue.
        count: atomic.Atomic(usize),

        /// Mailbox state.
        state: atomic.Atomic(MailboxState),

        /// Mutex for thread safety.
        mutex: std.Thread.Mutex,

        /// Condition for waiting on messages.
        cond: std.Thread.Condition,

        /// Configuration.
        config: MailboxConfig,

        /// Allocator.
        allocator: Allocator,

        /// Initialize a new mailbox.
        pub fn init(allocator: Allocator, config: MailboxConfig) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .head = null,
                .tail = null,
                .count = atomic.Atomic(usize).init(0),
                .state = atomic.Atomic(MailboxState).init(.open),
                .mutex = .{},
                .cond = .{},
                .config = config,
                .allocator = allocator,
            };
            return self;
        }

        /// Deinitialize and free all pending messages.
        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            var node = self.head;
            while (node) |n| {
                const next = n.next;
                self.allocator.destroy(n);
                node = next;
            }
            self.mutex.unlock();
            self.allocator.destroy(self);
        }

        /// Send a message to the mailbox.
        pub fn send(self: *Self, message: T) SendError!void {
            return self.sendWithPriority(message, 0);
        }

        /// Send a message with priority (higher = more urgent).
        pub fn sendWithPriority(self: *Self, message: T, priority: u8) SendError!void {
            if (self.state.load() != .open) {
                return SendError.Closed;
            }

            // Check capacity
            if (self.config.capacity > 0 and self.count.load() >= self.config.capacity) {
                return SendError.Full;
            }

            const node = self.allocator.create(Node) catch return SendError.OutOfMemory;
            node.* = .{
                .value = message,
                .next = null,
                .priority = priority,
            };

            self.mutex.lock();
            defer self.mutex.unlock();

            // Check state again under lock
            if (self.state.load() != .open) {
                self.allocator.destroy(node);
                return SendError.Closed;
            }

            if (self.config.priority_queue and priority > 0) {
                // Insert by priority
                self.insertByPriority(node);
            } else {
                // Append to tail
                if (self.tail) |t| {
                    t.next = node;
                } else {
                    self.head = node;
                }
                self.tail = node;
            }

            _ = self.count.fetchAdd(1);
            self.cond.signal();
        }

        fn insertByPriority(self: *Self, node: *Node) void {
            if (self.head == null) {
                self.head = node;
                self.tail = node;
                return;
            }

            // Find insertion point
            var prev: ?*Node = null;
            var curr = self.head;

            while (curr) |c| {
                if (node.priority > c.priority) {
                    // Insert before curr
                    node.next = c;
                    if (prev) |p| {
                        p.next = node;
                    } else {
                        self.head = node;
                    }
                    return;
                }
                prev = c;
                curr = c.next;
            }

            // Insert at end
            if (prev) |p| {
                p.next = node;
            }
            self.tail = node;
        }

        /// Try to send without blocking.
        pub fn trySend(self: *Self, message: T) SendError!void {
            return self.send(message);
        }

        /// Receive a message (non-blocking).
        pub fn receive(self: *Self) ?T {
            if (self.state.load() == .suspended) {
                return null;
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.head) |node| {
                self.head = node.next;
                if (self.head == null) {
                    self.tail = null;
                }
                _ = self.count.fetchSub(1);

                const value = node.value;
                self.allocator.destroy(node);
                return value;
            }

            return null;
        }

        /// Receive a message, blocking if none available.
        pub fn receiveBlocking(self: *Self) ReceiveError!T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.head == null) {
                if (self.state.load() == .closed) {
                    return ReceiveError.Closed;
                }
                self.cond.wait(&self.mutex);
            }

            const node = self.head.?;
            self.head = node.next;
            if (self.head == null) {
                self.tail = null;
            }
            _ = self.count.fetchSub(1);

            const value = node.value;
            self.allocator.destroy(node);
            return value;
        }

        /// Receive with timeout.
        pub fn receiveTimeout(self: *Self, timeout_ns: u64) ReceiveError!?T {
            const deadline = @as(u64, @intCast(std.time.nanoTimestamp())) + timeout_ns;

            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.head == null) {
                if (self.state.load() == .closed) {
                    return ReceiveError.Closed;
                }

                const now = @as(u64, @intCast(std.time.nanoTimestamp()));
                if (now >= deadline) {
                    return null; // Timeout
                }

                self.cond.timedWait(&self.mutex, deadline - now) catch {};
            }

            const node = self.head.?;
            self.head = node.next;
            if (self.head == null) {
                self.tail = null;
            }
            _ = self.count.fetchSub(1);

            const value = node.value;
            self.allocator.destroy(node);
            return value;
        }

        /// Peek at the next message without removing it.
        pub fn peek(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.head) |node| {
                return node.value;
            }
            return null;
        }

        /// Close the mailbox.
        pub fn close(self: *Self) void {
            self.state.store(.closed);
            self.cond.broadcast();
        }

        /// Suspend message delivery.
        pub fn suspendDelivery(self: *Self) void {
            self.state.store(.suspended);
        }

        /// Resume message delivery.
        pub fn resumeDelivery(self: *Self) void {
            if (self.state.load() == .suspended) {
                self.state.store(.open);
                self.cond.broadcast();
            }
        }

        /// Get number of pending messages.
        pub fn len(self: *const Self) usize {
            return self.count.load();
        }

        /// Check if mailbox is empty.
        pub fn isEmpty(self: *const Self) bool {
            return self.count.load() == 0;
        }

        /// Check if mailbox is closed.
        pub fn isClosed(self: *const Self) bool {
            return self.state.load() == .closed;
        }

        /// Check if at high water mark.
        pub fn isAtHighWaterMark(self: *const Self) bool {
            return self.count.load() >= self.config.high_water_mark;
        }

        /// Drain all messages.
        pub fn drain(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();

            var drained: usize = 0;
            while (self.head) |node| {
                self.head = node.next;
                self.allocator.destroy(node);
                drained += 1;
            }
            self.tail = null;
            self.count.store(0);

            return drained;
        }
    };
}

/// Send error types.
pub const SendError = error{
    Closed,
    Full,
    OutOfMemory,
};

/// Receive error types.
pub const ReceiveError = error{
    Closed,
};

/// System mailbox for actor system messages.
pub const SystemMessage = union(enum) {
    /// Stop the actor.
    stop,
    /// Restart the actor.
    restart,
    /// Suspend the actor.
    @"suspend",
    /// Resume the actor.
    @"resume",
    /// Link to another actor.
    link: usize,
    /// Unlink from another actor.
    unlink: usize,
    /// Monitor another actor.
    monitor: usize,
    /// Actor terminated.
    terminated: struct {
        actor_id: usize,
        reason: TerminationReason,
    },
};

/// Termination reasons.
pub const TerminationReason = enum {
    normal,
    error_occurred,
    killed,
    supervisor_shutdown,
};

// ============================================================================
// Tests
// ============================================================================

test "Mailbox basic send/receive" {
    var mailbox = try Mailbox(u32).init(std.testing.allocator, .{});
    defer mailbox.deinit();

    try std.testing.expect(mailbox.isEmpty());

    try mailbox.send(42);
    try std.testing.expectEqual(@as(usize, 1), mailbox.len());

    const msg = mailbox.receive().?;
    try std.testing.expectEqual(@as(u32, 42), msg);
    try std.testing.expect(mailbox.isEmpty());
}

test "Mailbox multiple messages" {
    var mailbox = try Mailbox(u32).init(std.testing.allocator, .{});
    defer mailbox.deinit();

    try mailbox.send(1);
    try mailbox.send(2);
    try mailbox.send(3);

    try std.testing.expectEqual(@as(usize, 3), mailbox.len());

    try std.testing.expectEqual(@as(u32, 1), mailbox.receive().?);
    try std.testing.expectEqual(@as(u32, 2), mailbox.receive().?);
    try std.testing.expectEqual(@as(u32, 3), mailbox.receive().?);
    try std.testing.expect(mailbox.receive() == null);
}

test "Mailbox peek" {
    var mailbox = try Mailbox(u32).init(std.testing.allocator, .{});
    defer mailbox.deinit();

    try mailbox.send(99);

    try std.testing.expectEqual(@as(u32, 99), mailbox.peek().?);
    try std.testing.expectEqual(@as(usize, 1), mailbox.len()); // Still there

    _ = mailbox.receive();
    try std.testing.expect(mailbox.peek() == null);
}

test "Mailbox close" {
    var mailbox = try Mailbox(u32).init(std.testing.allocator, .{});
    defer mailbox.deinit();

    try std.testing.expect(!mailbox.isClosed());

    mailbox.close();

    try std.testing.expect(mailbox.isClosed());
    try std.testing.expectError(SendError.Closed, mailbox.send(1));
}

test "Mailbox bounded capacity" {
    var mailbox = try Mailbox(u32).init(std.testing.allocator, .{ .capacity = 2 });
    defer mailbox.deinit();

    try mailbox.send(1);
    try mailbox.send(2);
    try std.testing.expectError(SendError.Full, mailbox.send(3));

    _ = mailbox.receive();
    try mailbox.send(3); // Now has room
}

test "Mailbox drain" {
    var mailbox = try Mailbox(u32).init(std.testing.allocator, .{});
    defer mailbox.deinit();

    try mailbox.send(1);
    try mailbox.send(2);
    try mailbox.send(3);

    const drained = mailbox.drain();
    try std.testing.expectEqual(@as(usize, 3), drained);
    try std.testing.expect(mailbox.isEmpty());
}

test "Mailbox high water mark" {
    var mailbox = try Mailbox(u32).init(std.testing.allocator, .{ .high_water_mark = 2 });
    defer mailbox.deinit();

    try std.testing.expect(!mailbox.isAtHighWaterMark());

    try mailbox.send(1);
    try std.testing.expect(!mailbox.isAtHighWaterMark());

    try mailbox.send(2);
    try std.testing.expect(mailbox.isAtHighWaterMark());
}

test "Mailbox priority queue" {
    var mailbox = try Mailbox(u32).init(std.testing.allocator, .{ .priority_queue = true });
    defer mailbox.deinit();

    try mailbox.sendWithPriority(1, 0); // Low priority
    try mailbox.sendWithPriority(2, 10); // High priority
    try mailbox.sendWithPriority(3, 5); // Medium priority

    // Should receive in priority order
    try std.testing.expectEqual(@as(u32, 2), mailbox.receive().?); // Priority 10
    try std.testing.expectEqual(@as(u32, 3), mailbox.receive().?); // Priority 5
    try std.testing.expectEqual(@as(u32, 1), mailbox.receive().?); // Priority 0
}
