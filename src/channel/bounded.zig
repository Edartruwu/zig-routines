//! Bounded (buffered) channel implementation.
//!
//! A fixed-capacity channel that blocks senders when full and receivers
//! when empty. This is the classic Go-style buffered channel.
//!
//! ## Semantics
//!
//! - Send blocks when buffer is full
//! - Receive blocks when buffer is empty
//! - Close prevents new sends but allows draining remaining items
//!
//! ## Example
//!
//! ```zig
//! var ch = try BoundedChannel(u32).init(allocator, 10);
//! defer ch.deinit();
//!
//! try ch.send(1);
//! try ch.send(2);
//!
//! const v1 = try ch.recv(); // 1
//! const v2 = try ch.recv(); // 2
//!
//! ch.close();
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const channel = @import("channel.zig");
const Allocator = std.mem.Allocator;

const ChannelState = channel.ChannelState;
const SendError = channel.SendError;
const RecvError = channel.RecvError;
const Channel = channel.Channel;

/// Bounded channel with fixed capacity.
pub fn BoundedChannel(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Ring buffer for items.
        buffer: []T,

        /// Capacity mask (capacity - 1).
        mask: usize,

        /// Write position.
        write_pos: usize,

        /// Read position.
        read_pos: usize,

        /// Number of items in buffer.
        count: usize,

        /// Channel state.
        state: atomic.Atomic(ChannelState),

        /// Mutex for synchronization.
        mutex: std.Thread.Mutex,

        /// Condition for senders (buffer not full).
        not_full: std.Thread.Condition,

        /// Condition for receivers (buffer not empty).
        not_empty: std.Thread.Condition,

        /// Allocator.
        allocator: Allocator,

        /// Initialize a bounded channel.
        pub fn init(allocator: Allocator, min_capacity: usize) !*Self {
            const cap = std.math.ceilPowerOfTwo(usize, @max(min_capacity, 1)) catch return error.OutOfMemory;

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const buffer = try allocator.alloc(T, cap);

            self.* = Self{
                .buffer = buffer,
                .mask = cap - 1,
                .write_pos = 0,
                .read_pos = 0,
                .count = 0,
                .state = atomic.Atomic(ChannelState).init(.open),
                .mutex = .{},
                .not_full = .{},
                .not_empty = .{},
                .allocator = allocator,
            };

            return self;
        }

        /// Deinitialize the channel.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            self.allocator.destroy(self);
        }

        /// Send a value (blocks if full).
        pub fn send(self: *Self, value: T) SendError!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Wait for space or closed
            while (self.count == self.buffer.len) {
                if (self.state.load() == .closed) {
                    return SendError.Closed;
                }
                self.not_full.wait(&self.mutex);
            }

            // Check closed after waking
            if (self.state.load() == .closed) {
                return SendError.Closed;
            }

            // Write to buffer
            self.buffer[self.write_pos] = value;
            self.write_pos = (self.write_pos + 1) & self.mask;
            self.count += 1;

            // Signal receiver
            self.not_empty.signal();
        }

        /// Try to send without blocking.
        pub fn trySend(self: *Self, value: T) SendError!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state.load() == .closed) {
                return SendError.Closed;
            }

            if (self.count == self.buffer.len) {
                return SendError.Full;
            }

            self.buffer[self.write_pos] = value;
            self.write_pos = (self.write_pos + 1) & self.mask;
            self.count += 1;

            self.not_empty.signal();
        }

        /// Receive a value (blocks if empty).
        pub fn recv(self: *Self) RecvError!T {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Wait for item or closed+empty
            while (self.count == 0) {
                if (self.state.load() == .closed) {
                    return RecvError.Closed;
                }
                self.not_empty.wait(&self.mutex);
            }

            // Read from buffer
            const value = self.buffer[self.read_pos];
            self.read_pos = (self.read_pos + 1) & self.mask;
            self.count -= 1;

            // Signal sender
            self.not_full.signal();

            return value;
        }

        /// Try to receive without blocking.
        pub fn tryRecv(self: *Self) RecvError!T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count == 0) {
                if (self.state.load() == .closed) {
                    return RecvError.Closed;
                }
                return RecvError.Empty;
            }

            const value = self.buffer[self.read_pos];
            self.read_pos = (self.read_pos + 1) & self.mask;
            self.count -= 1;

            self.not_full.signal();

            return value;
        }

        /// Close the channel.
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.state.store(.closed);

            // Wake all waiters
            self.not_full.broadcast();
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

        /// Get capacity.
        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
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

test "BoundedChannel basic" {
    var ch = try BoundedChannel(u32).init(std.testing.allocator, 4);
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

test "BoundedChannel trySend tryRecv" {
    var ch = try BoundedChannel(u32).init(std.testing.allocator, 2);
    defer ch.deinit();

    try ch.trySend(1);
    try ch.trySend(2);

    // Should fail - full
    try std.testing.expectError(SendError.Full, ch.trySend(3));

    try std.testing.expectEqual(@as(u32, 1), try ch.tryRecv());
    try std.testing.expectEqual(@as(u32, 2), try ch.tryRecv());

    // Should fail - empty
    try std.testing.expectError(RecvError.Empty, ch.tryRecv());
}

test "BoundedChannel close" {
    var ch = try BoundedChannel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    try ch.send(42);
    ch.close();

    try std.testing.expect(ch.isClosed());

    // Can still receive pending items
    try std.testing.expectEqual(@as(u32, 42), try ch.recv());

    // Now should error
    try std.testing.expectError(RecvError.Closed, ch.recv());
    try std.testing.expectError(SendError.Closed, ch.send(1));
}

test "BoundedChannel asChannel" {
    var ch = try BoundedChannel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    const generic = ch.asChannel();

    try generic.send(100);
    try std.testing.expectEqual(@as(u32, 100), try generic.recv());
}
