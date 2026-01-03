//! macOS/BSD kqueue backend for async I/O.
//!
//! kqueue is the BSD/macOS event notification mechanism providing:
//! - Efficient file descriptor monitoring
//! - Timer events
//! - Process/signal monitoring
//!
//! This backend is available on macOS, FreeBSD, and other BSD variants.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const io = @import("io.zig");

/// kqueue backend implementation.
pub const Kqueue = struct {
    const Self = @This();

    const is_bsd = builtin.os.tag == .macos or
        builtin.os.tag == .freebsd or
        builtin.os.tag == .openbsd or
        builtin.os.tag == .netbsd;

    /// kqueue file descriptor.
    kq: std.posix.fd_t,

    /// Pending operations.
    pending: std.AutoHashMap(u64, PendingOp),

    /// Next operation ID.
    next_id: u64,

    /// Allocator.
    allocator: Allocator,

    const PendingOp = struct {
        submission: io.Submission,
        callback: ?io.CompletionCallback,
        context: ?*anyopaque,
    };

    /// VTable for Io interface.
    pub const vtable = io.Io.VTable{
        .submit = submitVTable,
        .poll = pollVTable,
        .pending = pendingVTable,
        .deinit = deinitVTable,
    };

    fn submitVTable(ptr: *anyopaque, sub: *const io.Submission) io.Io.SubmitError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.submit(sub);
    }

    fn pollVTable(ptr: *anyopaque, timeout_ms: i32) io.Io.PollError!usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.poll(timeout_ms);
    }

    fn pendingVTable(ptr: *anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.pending.count();
    }

    fn deinitVTable(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    /// Initialize kqueue.
    pub fn init(allocator: Allocator, config: io.Config) !*Self {
        _ = config;

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        if (is_bsd) {
            self.kq = std.posix.kqueue() catch |err| {
                allocator.destroy(self);
                return err;
            };
        } else {
            self.kq = -1;
        }

        self.pending = std.AutoHashMap(u64, PendingOp).init(allocator);
        self.next_id = 1;
        self.allocator = allocator;

        return self;
    }

    /// Deinitialize.
    pub fn deinit(self: *Self) void {
        if (self.kq >= 0) {
            std.posix.close(self.kq);
        }
        self.pending.deinit();
        self.allocator.destroy(self);
    }

    /// Submit an operation.
    pub fn submit(self: *Self, sub: *const io.Submission) io.Io.SubmitError!void {
        if (!is_bsd) {
            return io.Io.SubmitError.SystemError;
        }

        const id = self.next_id;
        self.next_id +%= 1;

        // Store the pending operation
        self.pending.put(id, .{
            .submission = sub.*,
            .callback = sub.callback,
            .context = sub.context,
        }) catch return io.Io.SubmitError.SystemError;

        // Create kevent for the operation
        var changelist: [1]std.posix.Kevent = undefined;

        if (sub.op == .read or sub.op == .recv or sub.op == .accept) {
            changelist[0] = .{
                .ident = @intCast(sub.fd),
                .filter = std.posix.system.EVFILT.READ,
                .flags = std.posix.system.EV.ADD | std.posix.system.EV.ONESHOT,
                .fflags = 0,
                .data = 0,
                .udata = id,
            };
        } else if (sub.op == .write or sub.op == .send or sub.op == .connect) {
            changelist[0] = .{
                .ident = @intCast(sub.fd),
                .filter = std.posix.system.EVFILT.WRITE,
                .flags = std.posix.system.EV.ADD | std.posix.system.EV.ONESHOT,
                .fflags = 0,
                .data = 0,
                .udata = id,
            };
        } else if (sub.op == .timeout) {
            changelist[0] = .{
                .ident = id,
                .filter = std.posix.system.EVFILT.TIMER,
                .flags = std.posix.system.EV.ADD | std.posix.system.EV.ONESHOT,
                .fflags = std.posix.system.NOTE.NSECONDS,
                .data = @intCast(sub.timeout_ns),
                .udata = id,
            };
        } else if (sub.op == .close) {
            // Close is synchronous
            std.posix.close(sub.fd);
            const result = io.Result{
                .bytes = 0,
                .user_data = id,
                .flags = 0,
            };
            if (sub.callback) |cb| {
                cb(result, sub.context);
            }
            _ = self.pending.remove(id);
            return;
        } else if (sub.op == .nop) {
            // NOP completes immediately
            const result = io.Result{
                .bytes = 0,
                .user_data = id,
                .flags = 0,
            };
            if (sub.callback) |cb| {
                cb(result, sub.context);
            }
            _ = self.pending.remove(id);
            return;
        } else {
            return io.Io.SubmitError.InvalidOperation;
        }

        // Register the event
        var eventlist: [0]std.posix.Kevent = undefined;
        _ = std.posix.kevent(self.kq, &changelist, &eventlist, null) catch {
            _ = self.pending.remove(id);
            return io.Io.SubmitError.SystemError;
        };
    }

    /// Poll for completions.
    pub fn poll(self: *Self, timeout_ms: i32) io.Io.PollError!usize {
        if (!is_bsd) {
            return 0;
        }

        var eventlist: [64]std.posix.Kevent = undefined;
        var ts: ?std.posix.timespec = null;

        if (timeout_ms >= 0) {
            ts = .{
                .sec = @divFloor(timeout_ms, 1000),
                .nsec = @mod(timeout_ms, 1000) * 1_000_000,
            };
        }

        const nevents = std.posix.kevent(self.kq, &.{}, &eventlist, if (ts) |*t| t else null) catch |err| {
            if (err == error.Interrupted) {
                return io.Io.PollError.Interrupted;
            }
            return io.Io.PollError.SystemError;
        };

        var completed: usize = 0;

        for (eventlist[0..nevents]) |event| {
            const id = event.udata;

            if (self.pending.get(id)) |pending_op| {
                var result = io.Result{
                    .bytes = 0,
                    .user_data = id,
                    .flags = 0,
                };

                // Check for errors
                if ((event.flags & std.posix.system.EV.ERROR) != 0) {
                    result.bytes = -@as(i32, @intCast(event.data));
                } else {
                    // Perform the actual I/O
                    const sub = &pending_op.submission;
                    switch (sub.op) {
                        .read => {
                            if (sub.buffer) |buf| {
                                const n = std.posix.read(sub.fd, buf) catch |err| {
                                    result.bytes = -@as(i32, @intCast(@intFromEnum(errToErrno(err))));
                                    break;
                                };
                                result.bytes = @intCast(n);
                            }
                        },
                        .write => {
                            if (sub.buffer) |buf| {
                                const n = std.posix.write(sub.fd, buf) catch |err| {
                                    result.bytes = -@as(i32, @intCast(@intFromEnum(errToErrno(err))));
                                    break;
                                };
                                result.bytes = @intCast(n);
                            }
                        },
                        .accept => {
                            const fd = std.posix.accept(sub.fd, sub.addr, sub.addr_len, 0) catch |err| {
                                result.bytes = -@as(i32, @intCast(@intFromEnum(errToErrno(err))));
                                break;
                            };
                            result.bytes = @intCast(fd);
                        },
                        .timeout => {
                            // Timer expired
                            result.bytes = 0;
                        },
                        else => {},
                    }
                }

                // Call callback
                if (pending_op.callback) |cb| {
                    cb(result, pending_op.context);
                }

                _ = self.pending.remove(id);
                completed += 1;
            }
        }

        return completed;
    }

    fn errToErrno(err: anyerror) std.posix.E {
        return switch (err) {
            error.WouldBlock => .AGAIN,
            error.ConnectionResetByPeer => .CONNRESET,
            error.BrokenPipe => .PIPE,
            error.NotOpenForReading => .BADF,
            error.InputOutput => .IO,
            else => .IO,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Kqueue vtable exists" {
    const vt = &Kqueue.vtable;
    try std.testing.expect(@intFromPtr(vt.submit) != 0);
    try std.testing.expect(@intFromPtr(vt.poll) != 0);
    try std.testing.expect(@intFromPtr(vt.pending) != 0);
    try std.testing.expect(@intFromPtr(vt.deinit) != 0);
}

test "Kqueue init and deinit" {
    if (comptime !(builtin.os.tag == .macos or builtin.os.tag == .freebsd)) {
        return error.SkipZigTest;
    }

    var kq = try Kqueue.init(std.testing.allocator, .{});
    defer kq.deinit();

    try std.testing.expect(kq.kq >= 0);
    try std.testing.expectEqual(@as(usize, 0), kq.pending.count());
}
