//! Select statement for multiplexing channel operations.
//!
//! Allows waiting on multiple channel operations simultaneously,
//! similar to Go's select statement.
//!
//! ## Example
//!
//! ```zig
//! var sel = Select.init();
//!
//! sel.recv(ch1, 0);
//! sel.recv(ch2, 1);
//! sel.send(ch3, value, 2);
//!
//! switch (sel.select()) {
//!     0 => |value| handleCh1(value),
//!     1 => |value| handleCh2(value),
//!     2 => sentToCh3(),
//!     else => unreachable,
//! }
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const channel = @import("channel.zig");

const SendError = channel.SendError;
const RecvError = channel.RecvError;

/// Maximum number of cases in a select.
pub const MAX_SELECT_CASES = 16;

/// Type of select operation.
pub const SelectOp = enum {
    /// Receive from channel.
    recv,
    /// Send to channel.
    send,
    /// Default case (non-blocking).
    default,
};

/// Result of a select operation.
pub const SelectResult = union(enum) {
    /// Received a value.
    recv: usize, // Index of the channel that was ready

    /// Sent a value.
    sent: usize, // Index of the channel that was ready

    /// Default case was selected.
    default: void,

    /// All channels are closed.
    closed: void,

    /// Timeout expired.
    timeout: void,
};

/// A single case in a select statement.
pub fn SelectCase(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Operation type.
        op: SelectOp,

        /// Channel pointer (type-erased).
        channel_ptr: *anyopaque,

        /// Value for send operations.
        send_value: ?T,

        /// Received value (filled after select).
        recv_value: ?T,

        /// User-defined tag/index.
        tag: usize,

        /// Try receive function.
        try_recv_fn: ?*const fn (*anyopaque) RecvError!T,

        /// Try send function.
        try_send_fn: ?*const fn (*anyopaque, T) SendError!void,

        /// Is closed function.
        is_closed_fn: *const fn (*anyopaque) bool,

        pub fn initRecv(
            ch: anytype,
            tag: usize,
        ) Self {
            const ChType = @TypeOf(ch.*);
            return .{
                .op = .recv,
                .channel_ptr = ch,
                .send_value = null,
                .recv_value = null,
                .tag = tag,
                .try_recv_fn = struct {
                    fn tryRecv(ptr: *anyopaque) RecvError!T {
                        const self: *ChType = @ptrCast(@alignCast(ptr));
                        return self.tryRecv();
                    }
                }.tryRecv,
                .try_send_fn = null,
                .is_closed_fn = struct {
                    fn isClosed(ptr: *anyopaque) bool {
                        const self: *ChType = @ptrCast(@alignCast(ptr));
                        return self.isClosed();
                    }
                }.isClosed,
            };
        }

        pub fn initSend(
            ch: anytype,
            value: T,
            tag: usize,
        ) Self {
            const ChType = @TypeOf(ch.*);
            return .{
                .op = .send,
                .channel_ptr = ch,
                .send_value = value,
                .recv_value = null,
                .tag = tag,
                .try_recv_fn = null,
                .try_send_fn = struct {
                    fn trySend(ptr: *anyopaque, v: T) SendError!void {
                        const self: *ChType = @ptrCast(@alignCast(ptr));
                        return self.trySend(v);
                    }
                }.trySend,
                .is_closed_fn = struct {
                    fn isClosed(ptr: *anyopaque) bool {
                        const self: *ChType = @ptrCast(@alignCast(ptr));
                        return self.isClosed();
                    }
                }.isClosed,
            };
        }

        pub fn initDefault(tag: usize) Self {
            return .{
                .op = .default,
                .channel_ptr = undefined,
                .send_value = null,
                .recv_value = null,
                .tag = tag,
                .try_recv_fn = null,
                .try_send_fn = null,
                .is_closed_fn = struct {
                    fn isClosed(_: *anyopaque) bool {
                        return false;
                    }
                }.isClosed,
            };
        }
    };
}

/// Select statement builder.
pub fn Select(comptime T: type) type {
    return struct {
        const Self = @This();
        const Case = SelectCase(T);

        /// Cases in the select.
        cases: [MAX_SELECT_CASES]Case,

        /// Number of active cases.
        case_count: usize,

        /// Whether there's a default case.
        has_default: bool,

        /// Default case index.
        default_index: usize,

        /// Initialize an empty select.
        pub fn init() Self {
            return .{
                .cases = undefined,
                .case_count = 0,
                .has_default = false,
                .default_index = 0,
            };
        }

        /// Add a receive case.
        pub fn recv(self: *Self, ch: anytype, tag: usize) *Self {
            if (self.case_count < MAX_SELECT_CASES) {
                self.cases[self.case_count] = Case.initRecv(ch, tag);
                self.case_count += 1;
            }
            return self;
        }

        /// Add a send case.
        pub fn send(self: *Self, ch: anytype, value: T, tag: usize) *Self {
            if (self.case_count < MAX_SELECT_CASES) {
                self.cases[self.case_count] = Case.initSend(ch, value, tag);
                self.case_count += 1;
            }
            return self;
        }

        /// Add a default case.
        pub fn setDefault(self: *Self, tag: usize) *Self {
            if (self.case_count < MAX_SELECT_CASES) {
                self.cases[self.case_count] = Case.initDefault(tag);
                self.default_index = self.case_count;
                self.has_default = true;
                self.case_count += 1;
            }
            return self;
        }

        /// Try to select a ready case (non-blocking).
        pub fn trySelect(self: *Self) ?SelectResult {
            // Shuffle order for fairness
            var order: [MAX_SELECT_CASES]usize = undefined;
            for (0..self.case_count) |i| {
                order[i] = i;
            }

            // Simple shuffle using xorshift
            var rng = @as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));
            for (0..self.case_count) |i| {
                rng ^= rng << 13;
                rng ^= rng >> 7;
                rng ^= rng << 17;
                const j = @as(usize, @truncate(rng)) % (self.case_count - i) + i;
                const tmp = order[i];
                order[i] = order[j];
                order[j] = tmp;
            }

            // Try each case in shuffled order
            var all_closed = true;

            for (0..self.case_count) |i| {
                const idx = order[i];
                const case = &self.cases[idx];

                switch (case.op) {
                    .recv => {
                        if (!case.is_closed_fn(case.channel_ptr)) {
                            all_closed = false;
                        }

                        if (case.try_recv_fn) |try_recv| {
                            if (try_recv(case.channel_ptr)) |value| {
                                case.recv_value = value;
                                return .{ .recv = case.tag };
                            } else |err| switch (err) {
                                RecvError.Empty => continue,
                                RecvError.Closed => continue,
                                else => continue,
                            }
                        }
                    },
                    .send => {
                        if (!case.is_closed_fn(case.channel_ptr)) {
                            all_closed = false;
                        }

                        if (case.try_send_fn) |try_send| {
                            if (case.send_value) |value| {
                                try_send(case.channel_ptr, value) catch |err| switch (err) {
                                    SendError.Full => continue,
                                    SendError.Closed => continue,
                                    else => continue,
                                };
                                return .{ .sent = case.tag };
                            }
                        }
                    },
                    .default => {
                        // Default is handled after all other cases
                    },
                }
            }

            // No case ready, check for default
            if (self.has_default) {
                return .default;
            }

            // Check if all channels are closed
            if (all_closed and self.case_count > 0) {
                return .closed;
            }

            return null;
        }

        /// Select with blocking (polls repeatedly).
        pub fn selectBlocking(self: *Self) SelectResult {
            while (true) {
                if (self.trySelect()) |result| {
                    return result;
                }

                // Brief sleep before retry
                std.time.sleep(100_000); // 100us
            }
        }

        /// Select with timeout.
        pub fn selectTimeout(self: *Self, timeout_ns: u64) SelectResult {
            const deadline = @as(u64, @intCast(std.time.nanoTimestamp())) + timeout_ns;

            while (true) {
                if (self.trySelect()) |result| {
                    return result;
                }

                const now = @as(u64, @intCast(std.time.nanoTimestamp()));
                if (now >= deadline) {
                    return .timeout;
                }

                std.time.sleep(100_000); // 100us
            }
        }

        /// Get the received value for a case.
        pub fn getRecvValue(self: *Self, tag: usize) ?T {
            for (0..self.case_count) |i| {
                if (self.cases[i].tag == tag) {
                    return self.cases[i].recv_value;
                }
            }
            return null;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Select basic" {
    const BoundedChannel = @import("bounded.zig").BoundedChannel;

    var ch1 = try BoundedChannel(u32).init(std.testing.allocator, 4);
    defer ch1.deinit();

    var ch2 = try BoundedChannel(u32).init(std.testing.allocator, 4);
    defer ch2.deinit();

    // Send to ch1
    try ch1.send(42);

    var sel = Select(u32).init();
    _ = sel.recv(ch1, 0);
    _ = sel.recv(ch2, 1);

    const result = sel.trySelect();
    try std.testing.expect(result != null);
    try std.testing.expectEqual(SelectResult{ .recv = 0 }, result.?);

    // Check received value
    try std.testing.expectEqual(@as(?u32, 42), sel.getRecvValue(0));
}

test "Select with default" {
    const BoundedChannel = @import("bounded.zig").BoundedChannel;

    var ch = try BoundedChannel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    var sel = Select(u32).init();
    _ = sel.recv(ch, 0);
    _ = sel.setDefault(1);

    // Channel is empty, should select default
    const result = sel.trySelect();
    try std.testing.expect(result != null);
    try std.testing.expectEqual(SelectResult.default, result.?);
}

test "Select send" {
    const BoundedChannel = @import("bounded.zig").BoundedChannel;

    var ch = try BoundedChannel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    var sel = Select(u32).init();
    _ = sel.send(ch, 99, 0);

    const result = sel.trySelect();
    try std.testing.expect(result != null);
    try std.testing.expectEqual(SelectResult{ .sent = 0 }, result.?);

    // Verify value was sent
    try std.testing.expectEqual(@as(u32, 99), try ch.recv());
}
