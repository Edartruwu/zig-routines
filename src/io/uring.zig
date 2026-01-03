//! Linux io_uring backend for async I/O.
//!
//! io_uring is Linux's modern async I/O interface providing:
//! - True async I/O with kernel-managed completion
//! - Batched submissions for reduced syscall overhead
//! - Optional kernel-side polling (SQPOLL)
//!
//! This backend is only available on Linux 5.1+.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const io = @import("io.zig");

/// io_uring backend implementation.
pub const IoUring = struct {
    const Self = @This();

    /// Zig's io_uring wrapper.
    ring: if (is_linux) std.os.linux.IoUring else void,

    /// Pending operation count.
    pending_count: usize,

    /// Completion callbacks.
    callbacks: std.AutoHashMap(u64, CallbackEntry),

    /// Next user data ID.
    next_id: u64,

    /// Allocator.
    allocator: Allocator,

    const CallbackEntry = struct {
        callback: ?io.CompletionCallback,
        context: ?*anyopaque,
    };

    const is_linux = builtin.os.tag == .linux;

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
        return self.pending_count;
    }

    fn deinitVTable(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    /// Initialize io_uring.
    pub fn init(allocator: Allocator, config: io.Config) !*Self {
        if (!is_linux) {
            return error.UnsupportedPlatform;
        }

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        if (is_linux) {
            var params = std.mem.zeroes(std.os.linux.io_uring_params);

            if (config.kernel_poll) {
                params.flags |= std.os.linux.IORING_SETUP_SQPOLL;
            }

            self.ring = std.os.linux.IoUring.init(config.sq_entries, &params) catch |err| {
                allocator.destroy(self);
                return err;
            };
        }

        self.pending_count = 0;
        self.callbacks = std.AutoHashMap(u64, CallbackEntry).init(allocator);
        self.next_id = 1;
        self.allocator = allocator;

        return self;
    }

    /// Deinitialize.
    pub fn deinit(self: *Self) void {
        if (is_linux) {
            self.ring.deinit();
        }
        self.callbacks.deinit();
        self.allocator.destroy(self);
    }

    /// Submit an operation.
    pub fn submit(self: *Self, sub: *const io.Submission) io.Io.SubmitError!void {
        if (!is_linux) {
            return io.Io.SubmitError.SystemError;
        }

        const user_data = self.next_id;
        self.next_id +%= 1;

        // Store callback
        self.callbacks.put(user_data, .{
            .callback = sub.callback,
            .context = sub.context,
        }) catch return io.Io.SubmitError.SystemError;

        // Get SQE
        var sqe = self.ring.get_sqe() orelse return io.Io.SubmitError.QueueFull;
        sqe.user_data = user_data;

        switch (sub.op) {
            .nop => {
                sqe.prep_nop();
            },
            .read => {
                if (sub.buffer) |buf| {
                    sqe.prep_read(sub.fd, buf, sub.offset);
                } else {
                    return io.Io.SubmitError.InvalidBuffer;
                }
            },
            .write => {
                if (sub.buffer) |buf| {
                    sqe.prep_write(sub.fd, buf, sub.offset);
                } else {
                    return io.Io.SubmitError.InvalidBuffer;
                }
            },
            .accept => {
                sqe.prep_accept(sub.fd, sub.addr, sub.addr_len, 0);
            },
            .connect => {
                if (sub.addr) |addr| {
                    if (sub.addr_len) |len| {
                        sqe.prep_connect(sub.fd, addr, len.*);
                    }
                }
            },
            .close => {
                sqe.prep_close(sub.fd);
            },
            .timeout => {
                var ts: std.os.linux.kernel_timespec = .{
                    .tv_sec = @intCast(sub.timeout_ns / 1_000_000_000),
                    .tv_nsec = @intCast(sub.timeout_ns % 1_000_000_000),
                };
                sqe.prep_timeout(&ts, 0, 0);
            },
            .recv => {
                if (sub.buffer) |buf| {
                    sqe.prep_recv(sub.fd, buf, 0);
                } else {
                    return io.Io.SubmitError.InvalidBuffer;
                }
            },
            .send => {
                if (sub.buffer) |buf| {
                    sqe.prep_send(sub.fd, buf, 0);
                } else {
                    return io.Io.SubmitError.InvalidBuffer;
                }
            },
            else => {
                return io.Io.SubmitError.InvalidOperation;
            },
        }

        // Submit to kernel
        _ = self.ring.submit() catch return io.Io.SubmitError.SystemError;
        self.pending_count += 1;
    }

    /// Poll for completions.
    pub fn poll(self: *Self, timeout_ms: i32) io.Io.PollError!usize {
        _ = timeout_ms; // TODO: use for timed wait

        if (!is_linux) {
            return 0;
        }

        var completed: usize = 0;

        // Wait for at least one completion
        _ = self.ring.submit_and_wait(if (self.pending_count > 0) 1 else 0) catch |err| {
            if (err == error.Interrupted) {
                return io.Io.PollError.Interrupted;
            }
            return io.Io.PollError.SystemError;
        };

        // Process all available completions
        while (self.ring.cq_ready() > 0) {
            const cqe = self.ring.peek_cqe() orelse break;

            const result = io.Result{
                .bytes = cqe.res,
                .user_data = cqe.user_data,
                .flags = cqe.flags,
            };

            // Call callback if present
            if (self.callbacks.get(cqe.user_data)) |entry| {
                if (entry.callback) |cb| {
                    cb(result, entry.context);
                }
                _ = self.callbacks.remove(cqe.user_data);
            }

            self.ring.cq_advance(1);
            self.pending_count -|= 1;
            completed += 1;
        }

        return completed;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "IoUring vtable exists" {
    // Just verify the vtable is properly constructed
    const vt = &IoUring.vtable;
    try std.testing.expect(@intFromPtr(vt.submit) != 0);
    try std.testing.expect(@intFromPtr(vt.poll) != 0);
    try std.testing.expect(@intFromPtr(vt.pending) != 0);
    try std.testing.expect(@intFromPtr(vt.deinit) != 0);
}
