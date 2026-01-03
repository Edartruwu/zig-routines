//! Channel interface and common types for CSP-style communication.
//!
//! Channels provide typed, thread-safe communication between concurrent tasks.
//! Inspired by Go's channels, they support both synchronous and buffered modes.
//!
//! ## Channel Types
//!
//! - `BoundedChannel`: Fixed-capacity buffered channel
//! - `UnboundedChannel`: Dynamically growing channel
//! - `OneshotChannel`: Single-use promise/future pattern
//!
//! ## Example
//!
//! ```zig
//! // Create a buffered channel
//! var ch = try Channel(u32).bounded(allocator, 10);
//! defer ch.deinit();
//!
//! // Send values
//! try ch.send(42);
//!
//! // Receive values
//! if (ch.recv()) |value| {
//!     std.debug.print("Got: {}\n", .{value});
//! }
//!
//! // Close the channel
//! ch.close();
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Channel state.
pub const ChannelState = enum(u8) {
    /// Channel is open and operational.
    open = 0,
    /// Channel is closed, no more sends allowed.
    closed = 1,
};

/// Result of a send operation.
pub const SendError = error{
    /// Channel is closed.
    Closed,
    /// Channel is full (for try_send).
    Full,
    /// Operation timed out.
    Timeout,
};

/// Result of a receive operation.
pub const RecvError = error{
    /// Channel is closed and empty.
    Closed,
    /// Channel is empty (for try_recv).
    Empty,
    /// Operation timed out.
    Timeout,
};

/// Generic channel interface.
/// Provides a unified API for all channel types.
pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            /// Send a value to the channel.
            send: *const fn (ptr: *anyopaque, value: T) SendError!void,

            /// Try to send without blocking.
            trySend: *const fn (ptr: *anyopaque, value: T) SendError!void,

            /// Receive a value from the channel.
            recv: *const fn (ptr: *anyopaque) RecvError!T,

            /// Try to receive without blocking.
            tryRecv: *const fn (ptr: *anyopaque) RecvError!T,

            /// Close the channel.
            close: *const fn (ptr: *anyopaque) void,

            /// Check if channel is closed.
            isClosed: *const fn (ptr: *anyopaque) bool,

            /// Get approximate number of items in channel.
            len: *const fn (ptr: *anyopaque) usize,

            /// Check if channel is empty.
            isEmpty: *const fn (ptr: *anyopaque) bool,

            /// Deinitialize and free resources.
            deinit: *const fn (ptr: *anyopaque) void,
        };

        /// Send a value to the channel (may block).
        pub fn send(self: Self, value: T) SendError!void {
            return self.vtable.send(self.ptr, value);
        }

        /// Try to send without blocking.
        pub fn trySend(self: Self, value: T) SendError!void {
            return self.vtable.trySend(self.ptr, value);
        }

        /// Receive a value from the channel (may block).
        pub fn recv(self: Self) RecvError!T {
            return self.vtable.recv(self.ptr);
        }

        /// Try to receive without blocking.
        pub fn tryRecv(self: Self) RecvError!T {
            return self.vtable.tryRecv(self.ptr);
        }

        /// Close the channel.
        pub fn close(self: Self) void {
            self.vtable.close(self.ptr);
        }

        /// Check if channel is closed.
        pub fn isClosed(self: Self) bool {
            return self.vtable.isClosed(self.ptr);
        }

        /// Get approximate number of items.
        pub fn len(self: Self) usize {
            return self.vtable.len(self.ptr);
        }

        /// Check if channel is empty.
        pub fn isEmpty(self: Self) bool {
            return self.vtable.isEmpty(self.ptr);
        }

        /// Deinitialize the channel.
        pub fn deinit(self: Self) void {
            self.vtable.deinit(self.ptr);
        }

        /// Create a bounded (buffered) channel.
        pub fn bounded(allocator: Allocator, capacity: usize) !Self {
            const BoundedChannel = @import("bounded.zig").BoundedChannel;
            const ch = try BoundedChannel(T).init(allocator, capacity);
            return ch.asChannel();
        }

        /// Create an unbounded channel.
        pub fn unbounded(allocator: Allocator) !Self {
            const UnboundedChannel = @import("unbounded.zig").UnboundedChannel;
            const ch = try UnboundedChannel(T).init(allocator);
            return ch.asChannel();
        }
    };
}

/// Sender half of a channel (can be cloned for multiple producers).
pub fn Sender(comptime T: type) type {
    return struct {
        const Self = @This();

        channel: Channel(T),

        pub fn init(channel: Channel(T)) Self {
            return .{ .channel = channel };
        }

        pub fn send(self: Self, value: T) SendError!void {
            return self.channel.send(value);
        }

        pub fn trySend(self: Self, value: T) SendError!void {
            return self.channel.trySend(value);
        }

        pub fn isClosed(self: Self) bool {
            return self.channel.isClosed();
        }
    };
}

/// Receiver half of a channel.
pub fn Receiver(comptime T: type) type {
    return struct {
        const Self = @This();

        channel: Channel(T),

        pub fn init(channel: Channel(T)) Self {
            return .{ .channel = channel };
        }

        pub fn recv(self: Self) RecvError!T {
            return self.channel.recv();
        }

        pub fn tryRecv(self: Self) RecvError!T {
            return self.channel.tryRecv();
        }

        pub fn isClosed(self: Self) bool {
            return self.channel.isClosed();
        }

        /// Iterator interface for use in for loops.
        pub fn iterator(self: Self) Iterator {
            return .{ .receiver = self };
        }

        pub const Iterator = struct {
            receiver: Self,

            pub fn next(self: *Iterator) ?T {
                return self.receiver.recv() catch null;
            }
        };
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Channel types compile" {
    // Just verify the types compile correctly
    const IntChannel = Channel(u32);
    _ = IntChannel;
    const IntSender = Sender(u32);
    _ = IntSender;
    const IntReceiver = Receiver(u32);
    _ = IntReceiver;
}
