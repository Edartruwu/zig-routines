//! Linux epoll backend for async I/O.
//!
//! epoll is Linux's traditional event notification mechanism.
//! Used as a fallback when io_uring is not available.
//!
//! Note: epoll is edge-triggered by default in this implementation.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const io = @import("io.zig");

/// epoll backend implementation.
pub const Epoll = struct {
    const Self = @This();

    const is_linux = builtin.os.tag == .linux;

    /// epoll file descriptor.
    epfd: if (is_linux) std.posix.fd_t else i32,

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

    /// Initialize epoll.
    pub fn init(allocator: Allocator, config: io.Config) !*Self {
        _ = config;

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        if (is_linux) {
            self.epfd = std.posix.epoll_create1(std.os.linux.EPOLL.CLOEXEC) catch |err| {
                allocator.destroy(self);
                return err;
            };
        } else {
            self.epfd = -1;
        }

        self.pending = std.AutoHashMap(u64, PendingOp).init(allocator);
        self.next_id = 1;
        self.allocator = allocator;

        return self;
    }

    /// Deinitialize.
    pub fn deinit(self: *Self) void {
        if (is_linux and self.epfd >= 0) {
            std.posix.close(self.epfd);
        }
        self.pending.deinit();
        self.allocator.destroy(self);
    }

    /// Submit an operation.
    pub fn submit(self: *Self, sub: *const io.Submission) io.Io.SubmitError!void {
        if (!is_linux) {
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

        // For read/write operations, add fd to epoll
        if (sub.op == .read or sub.op == .recv) {
            var event = std.os.linux.epoll_event{
                .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ET,
                .data = .{ .u64 = id },
            };
            std.posix.epoll_ctl(self.epfd, std.os.linux.EPOLL.CTL_ADD, sub.fd, &event) catch |err| {
                // If already added, modify instead
                if (err == error.FileDescriptorAlreadyPresentInSet) {
                    std.posix.epoll_ctl(self.epfd, std.os.linux.EPOLL.CTL_MOD, sub.fd, &event) catch {
                        return io.Io.SubmitError.SystemError;
                    };
                } else {
                    return io.Io.SubmitError.SystemError;
                }
            };
        } else if (sub.op == .write or sub.op == .send) {
            var event = std.os.linux.epoll_event{
                .events = std.os.linux.EPOLL.OUT | std.os.linux.EPOLL.ET,
                .data = .{ .u64 = id },
            };
            std.posix.epoll_ctl(self.epfd, std.os.linux.EPOLL.CTL_ADD, sub.fd, &event) catch |err| {
                if (err == error.FileDescriptorAlreadyPresentInSet) {
                    std.posix.epoll_ctl(self.epfd, std.os.linux.EPOLL.CTL_MOD, sub.fd, &event) catch {
                        return io.Io.SubmitError.SystemError;
                    };
                } else {
                    return io.Io.SubmitError.SystemError;
                }
            };
        } else if (sub.op == .accept) {
            var event = std.os.linux.epoll_event{
                .events = std.os.linux.EPOLL.IN,
                .data = .{ .u64 = id },
            };
            std.posix.epoll_ctl(self.epfd, std.os.linux.EPOLL.CTL_ADD, sub.fd, &event) catch |err| {
                if (err == error.FileDescriptorAlreadyPresentInSet) {
                    std.posix.epoll_ctl(self.epfd, std.os.linux.EPOLL.CTL_MOD, sub.fd, &event) catch {
                        return io.Io.SubmitError.SystemError;
                    };
                } else {
                    return io.Io.SubmitError.SystemError;
                }
            };
        }
    }

    /// Poll for completions.
    pub fn poll(self: *Self, timeout_ms: i32) io.Io.PollError!usize {
        if (!is_linux) {
            return 0;
        }

        var events: [64]std.os.linux.epoll_event = undefined;
        const nfds = std.posix.epoll_wait(self.epfd, &events, timeout_ms) catch |err| {
            if (err == error.Interrupted) {
                return io.Io.PollError.Interrupted;
            }
            return io.Io.PollError.SystemError;
        };

        var completed: usize = 0;

        for (events[0..nfds]) |event| {
            const id = event.data.u64;

            if (self.pending.get(id)) |pending_op| {
                var result = io.Result{
                    .bytes = 0,
                    .user_data = id,
                    .flags = 0,
                };

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
                    else => {},
                }

                // Remove from epoll
                std.posix.epoll_ctl(self.epfd, std.os.linux.EPOLL.CTL_DEL, sub.fd, null) catch {};

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

test "Epoll vtable exists" {
    const vt = &Epoll.vtable;
    try std.testing.expect(@intFromPtr(vt.submit) != 0);
    try std.testing.expect(@intFromPtr(vt.poll) != 0);
    try std.testing.expect(@intFromPtr(vt.pending) != 0);
    try std.testing.expect(@intFromPtr(vt.deinit) != 0);
}
