//! One-shot channel for single-use promise/future pattern.
//!
//! A oneshot channel allows exactly one value to be sent and received.
//! This is the foundation for implementing promises and futures.
//!
//! ## Semantics
//!
//! - Can only be used once (send + recv)
//! - Send completes immediately
//! - Recv blocks until value is available or channel is dropped
//!
//! ## Example
//!
//! ```zig
//! const pair = try OneshotChannel(u32).init(allocator);
//! const sender = pair.sender;
//! const receiver = pair.receiver;
//!
//! // In one task
//! sender.send(42);
//!
//! // In another task
//! const value = try receiver.recv(); // 42
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const Allocator = std.mem.Allocator;

/// Oneshot channel state.
pub const OneshotState = enum(u8) {
    /// Waiting for value.
    empty = 0,
    /// Value is available.
    ready = 1,
    /// Channel was closed/dropped without value.
    closed = 2,
};

/// Error from oneshot operations.
pub const OneshotError = error{
    /// Channel was closed without sending a value.
    Closed,
    /// Already sent a value.
    AlreadySent,
};

/// One-shot channel for single value transfer.
pub fn OneshotChannel(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Shared state between sender and receiver.
        const Shared = struct {
            /// The value (valid when state == ready).
            value: T,

            /// Current state.
            state: atomic.Atomic(OneshotState),

            /// Mutex for waiting.
            mutex: std.Thread.Mutex,

            /// Condition for waiting.
            cond: std.Thread.Condition,

            /// Reference count.
            ref_count: atomic.Atomic(usize),

            /// Allocator.
            allocator: Allocator,

            fn acquire(self: *Shared) void {
                _ = self.ref_count.fetchAdd(1);
            }

            fn release(self: *Shared) void {
                if (self.ref_count.fetchSub(1) == 1) {
                    self.allocator.destroy(self);
                }
            }
        };

        /// Sender half (can only send once).
        pub const Sender = struct {
            shared: *Shared,

            /// Send a value.
            pub fn send(self: Sender, value: T) OneshotError!void {
                // Try to transition from empty to ready
                if (self.shared.state.compareAndSwap(.empty, .ready)) |_| {
                    return OneshotError.AlreadySent;
                }

                self.shared.value = value;

                // Signal waiter
                self.shared.mutex.lock();
                defer self.shared.mutex.unlock();
                self.shared.cond.signal();
            }

            /// Close without sending.
            pub fn close(self: Sender) void {
                _ = self.shared.state.compareAndSwap(.empty, .closed);

                self.shared.mutex.lock();
                defer self.shared.mutex.unlock();
                self.shared.cond.signal();
            }

            /// Check if already sent.
            pub fn isSent(self: Sender) bool {
                return self.shared.state.load() != .empty;
            }

            /// Release the sender.
            pub fn deinit(self: Sender) void {
                self.shared.release();
            }
        };

        /// Receiver half (can only receive once).
        pub const Receiver = struct {
            shared: *Shared,

            /// Receive the value (blocks until ready).
            pub fn recv(self: Receiver) OneshotError!T {
                self.shared.mutex.lock();
                defer self.shared.mutex.unlock();

                while (self.shared.state.load() == .empty) {
                    self.shared.cond.wait(&self.shared.mutex);
                }

                if (self.shared.state.load() == .closed) {
                    return OneshotError.Closed;
                }

                return self.shared.value;
            }

            /// Try to receive without blocking.
            pub fn tryRecv(self: Receiver) ?T {
                const state = self.shared.state.load();
                if (state == .ready) {
                    return self.shared.value;
                }
                return null;
            }

            /// Check if value is ready.
            pub fn isReady(self: Receiver) bool {
                return self.shared.state.load() == .ready;
            }

            /// Check if closed without value.
            pub fn isClosed(self: Receiver) bool {
                return self.shared.state.load() == .closed;
            }

            /// Release the receiver.
            pub fn deinit(self: Receiver) void {
                self.shared.release();
            }
        };

        /// Create a sender/receiver pair.
        pub fn init(allocator: Allocator) !struct { sender: Sender, receiver: Receiver } {
            const shared = try allocator.create(Shared);

            shared.* = .{
                .value = undefined,
                .state = atomic.Atomic(OneshotState).init(.empty),
                .mutex = .{},
                .cond = .{},
                .ref_count = atomic.Atomic(usize).init(2), // One for each half
                .allocator = allocator,
            };

            return .{
                .sender = .{ .shared = shared },
                .receiver = .{ .shared = shared },
            };
        }
    };
}

/// Create a oneshot channel pair.
pub fn oneshot(comptime T: type, allocator: Allocator) !struct {
    sender: OneshotChannel(T).Sender,
    receiver: OneshotChannel(T).Receiver,
} {
    const result = try OneshotChannel(T).init(allocator);
    return .{
        .sender = result.sender,
        .receiver = result.receiver,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "OneshotChannel basic" {
    const pair = try OneshotChannel(u32).init(std.testing.allocator);
    var sender = pair.sender;
    var receiver = pair.receiver;
    defer sender.deinit();
    defer receiver.deinit();

    try std.testing.expect(!sender.isSent());
    try std.testing.expect(!receiver.isReady());

    try sender.send(42);

    try std.testing.expect(sender.isSent());
    try std.testing.expect(receiver.isReady());

    const value = try receiver.recv();
    try std.testing.expectEqual(@as(u32, 42), value);
}

test "OneshotChannel tryRecv" {
    const pair = try OneshotChannel(u32).init(std.testing.allocator);
    var sender = pair.sender;
    var receiver = pair.receiver;
    defer sender.deinit();
    defer receiver.deinit();

    try std.testing.expect(receiver.tryRecv() == null);

    try sender.send(99);

    try std.testing.expectEqual(@as(?u32, 99), receiver.tryRecv());
}

test "OneshotChannel close" {
    const pair = try OneshotChannel(u32).init(std.testing.allocator);
    var sender = pair.sender;
    var receiver = pair.receiver;
    defer sender.deinit();
    defer receiver.deinit();

    sender.close();

    try std.testing.expect(receiver.isClosed());
    try std.testing.expectError(OneshotError.Closed, receiver.recv());
}

test "OneshotChannel double send" {
    const pair = try OneshotChannel(u32).init(std.testing.allocator);
    var sender = pair.sender;
    const receiver = pair.receiver;
    defer sender.deinit();
    defer receiver.deinit();

    try sender.send(1);
    try std.testing.expectError(OneshotError.AlreadySent, sender.send(2));
}

test "oneshot helper" {
    const pair = try oneshot(u32, std.testing.allocator);
    var sender = pair.sender;
    var receiver = pair.receiver;
    defer sender.deinit();
    defer receiver.deinit();

    try sender.send(123);
    try std.testing.expectEqual(@as(u32, 123), try receiver.recv());
}
