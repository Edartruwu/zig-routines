//! Async I/O interface for platform-agnostic event-driven I/O.
//!
//! This module provides a unified interface for async I/O operations
//! across different platforms (io_uring on Linux, kqueue on macOS/BSD).
//!
//! ## Example
//!
//! ```zig
//! var io = try Io.init(allocator, .{});
//! defer io.deinit();
//!
//! // Queue an async read
//! try io.read(fd, buffer, .{ .callback = onComplete });
//!
//! // Process completions
//! while (io.hasPending()) {
//!     _ = try io.poll(1000);
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// I/O operation types.
pub const OpType = enum(u8) {
    nop = 0,
    read = 1,
    write = 2,
    accept = 3,
    connect = 4,
    close = 5,
    timeout = 6,
    cancel = 7,
    poll_add = 8,
    poll_remove = 9,
    fsync = 10,
    recv = 11,
    send = 12,
    recvmsg = 13,
    sendmsg = 14,
};

/// I/O operation result.
pub const Result = struct {
    /// Number of bytes transferred (or error code if negative).
    bytes: i32,

    /// User data associated with the operation.
    user_data: u64,

    /// Operation flags.
    flags: u32,

    /// Check if operation succeeded.
    pub fn isSuccess(self: Result) bool {
        return self.bytes >= 0;
    }

    /// Get error if operation failed.
    pub fn getError(self: Result) ?std.posix.E {
        if (self.bytes < 0) {
            return @enumFromInt(@as(u16, @intCast(-self.bytes)));
        }
        return null;
    }
};

/// Completion callback type.
pub const CompletionCallback = *const fn (result: Result, user_data: ?*anyopaque) void;

/// I/O operation submission.
pub const Submission = struct {
    /// Operation type.
    op: OpType = .nop,

    /// File descriptor.
    fd: std.posix.fd_t = -1,

    /// Buffer for read/write.
    buffer: ?[]u8 = null,

    /// Offset for positioned I/O.
    offset: u64 = 0,

    /// User data to pass to completion.
    user_data: u64 = 0,

    /// Completion callback.
    callback: ?CompletionCallback = null,

    /// User context pointer.
    context: ?*anyopaque = null,

    /// Timeout in nanoseconds (for timeout ops).
    timeout_ns: u64 = 0,

    /// Flags.
    flags: u32 = 0,

    /// Socket address (for accept/connect).
    addr: ?*std.posix.sockaddr = null,
    addr_len: ?*std.posix.socklen_t = null,
};

/// I/O configuration.
pub const Config = struct {
    /// Size of the submission queue.
    sq_entries: u16 = 256,

    /// Size of the completion queue.
    cq_entries: u16 = 512,

    /// Enable kernel-side polling (SQPOLL).
    kernel_poll: bool = false,

    /// Attach to existing wq.
    attach_wq: ?std.posix.fd_t = null,
};

/// Backend type.
pub const Backend = enum {
    io_uring,
    epoll,
    kqueue,
    threaded,
};

/// I/O backend interface using vtable pattern.
pub const Io = struct {
    const Self = @This();

    /// VTable for backend operations.
    pub const VTable = struct {
        submit: *const fn (self: *anyopaque, sub: *const Submission) SubmitError!void,
        poll: *const fn (self: *anyopaque, timeout_ms: i32) PollError!usize,
        pending: *const fn (self: *anyopaque) usize,
        deinit: *const fn (self: *anyopaque) void,
    };

    /// Pointer to backend implementation.
    ptr: *anyopaque,

    /// VTable.
    vtable: *const VTable,

    /// Allocator.
    allocator: Allocator,

    /// Backend type.
    backend: Backend,

    /// Submit error type.
    pub const SubmitError = error{
        QueueFull,
        InvalidFd,
        InvalidBuffer,
        InvalidOperation,
        SystemError,
    };

    /// Poll error type.
    pub const PollError = error{
        Interrupted,
        SystemError,
    };

    /// Initialize with the best available backend for the platform.
    pub fn init(allocator: Allocator, config: Config) !Self {
        if (comptime builtin.os.tag == .linux) {
            // Try io_uring first, fall back to epoll
            if (IoUring.init(allocator, config)) |uring| {
                return Self{
                    .ptr = uring,
                    .vtable = &IoUring.vtable,
                    .allocator = allocator,
                    .backend = .io_uring,
                };
            } else |_| {
                const ep = try Epoll.init(allocator, config);
                return Self{
                    .ptr = ep,
                    .vtable = &Epoll.vtable,
                    .allocator = allocator,
                    .backend = .epoll,
                };
            }
        } else if (comptime builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
            const kq = try Kqueue.init(allocator, config);
            return Self{
                .ptr = kq,
                .vtable = &Kqueue.vtable,
                .allocator = allocator,
                .backend = .kqueue,
            };
        } else {
            // Fall back to threaded I/O
            const thr = try ThreadedIo.init(allocator, config);
            return Self{
                .ptr = thr,
                .vtable = &ThreadedIo.vtable,
                .allocator = allocator,
                .backend = .threaded,
            };
        }
    }

    /// Deinitialize.
    pub fn deinit(self: *Self) void {
        self.vtable.deinit(self.ptr);
    }

    /// Submit an I/O operation.
    pub fn submit(self: *Self, sub: *const Submission) SubmitError!void {
        return self.vtable.submit(self.ptr, sub);
    }

    /// Poll for completions.
    /// Returns the number of completions processed.
    pub fn poll(self: *Self, timeout_ms: i32) PollError!usize {
        return self.vtable.poll(self.ptr, timeout_ms);
    }

    /// Get number of pending operations.
    pub fn pending(self: *Self) usize {
        return self.vtable.pending(self.ptr);
    }

    /// Check if there are pending operations.
    pub fn hasPending(self: *Self) bool {
        return self.pending() > 0;
    }

    // Convenience methods

    /// Queue a read operation.
    pub fn read(self: *Self, fd: std.posix.fd_t, buffer: []u8, opts: struct {
        offset: u64 = 0,
        callback: ?CompletionCallback = null,
        context: ?*anyopaque = null,
        user_data: u64 = 0,
    }) SubmitError!void {
        return self.submit(&.{
            .op = .read,
            .fd = fd,
            .buffer = buffer,
            .offset = opts.offset,
            .callback = opts.callback,
            .context = opts.context,
            .user_data = opts.user_data,
        });
    }

    /// Queue a write operation.
    pub fn write(self: *Self, fd: std.posix.fd_t, buffer: []const u8, opts: struct {
        offset: u64 = 0,
        callback: ?CompletionCallback = null,
        context: ?*anyopaque = null,
        user_data: u64 = 0,
    }) SubmitError!void {
        return self.submit(&.{
            .op = .write,
            .fd = fd,
            .buffer = @constCast(buffer),
            .offset = opts.offset,
            .callback = opts.callback,
            .context = opts.context,
            .user_data = opts.user_data,
        });
    }

    /// Queue an accept operation.
    pub fn accept(self: *Self, fd: std.posix.fd_t, opts: struct {
        addr: ?*std.posix.sockaddr = null,
        addr_len: ?*std.posix.socklen_t = null,
        callback: ?CompletionCallback = null,
        context: ?*anyopaque = null,
        user_data: u64 = 0,
    }) SubmitError!void {
        return self.submit(&.{
            .op = .accept,
            .fd = fd,
            .addr = opts.addr,
            .addr_len = opts.addr_len,
            .callback = opts.callback,
            .context = opts.context,
            .user_data = opts.user_data,
        });
    }

    /// Queue a close operation.
    pub fn close(self: *Self, fd: std.posix.fd_t, opts: struct {
        callback: ?CompletionCallback = null,
        context: ?*anyopaque = null,
        user_data: u64 = 0,
    }) SubmitError!void {
        return self.submit(&.{
            .op = .close,
            .fd = fd,
            .callback = opts.callback,
            .context = opts.context,
            .user_data = opts.user_data,
        });
    }

    /// Queue a timeout operation.
    pub fn timeout(self: *Self, timeout_ns: u64, opts: struct {
        callback: ?CompletionCallback = null,
        context: ?*anyopaque = null,
        user_data: u64 = 0,
    }) SubmitError!void {
        return self.submit(&.{
            .op = .timeout,
            .timeout_ns = timeout_ns,
            .callback = opts.callback,
            .context = opts.context,
            .user_data = opts.user_data,
        });
    }

    /// Get the backend type.
    pub fn getBackend(self: *const Self) Backend {
        return self.backend;
    }
};

// Forward declarations for backends (defined in separate files)
const IoUring = @import("uring.zig").IoUring;
const Epoll = @import("epoll.zig").Epoll;
const Kqueue = @import("kqueue.zig").Kqueue;
const ThreadedIo = @import("threaded.zig").ThreadedIo;

/// Completion ring buffer for storing results.
pub fn CompletionRing(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]Result = undefined,
        head: usize = 0,
        tail: usize = 0,

        pub fn push(self: *Self, result: Result) bool {
            const next = (self.tail + 1) % capacity;
            if (next == self.head) {
                return false; // Full
            }
            self.buffer[self.tail] = result;
            self.tail = next;
            return true;
        }

        pub fn pop(self: *Self) ?Result {
            if (self.head == self.tail) {
                return null; // Empty
            }
            const result = self.buffer[self.head];
            self.head = (self.head + 1) % capacity;
            return result;
        }

        pub fn len(self: *const Self) usize {
            if (self.tail >= self.head) {
                return self.tail - self.head;
            }
            return capacity - self.head + self.tail;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.head == self.tail;
        }

        pub fn isFull(self: *const Self) bool {
            return (self.tail + 1) % capacity == self.head;
        }
    };
}

/// Pending operation tracker.
pub const PendingOp = struct {
    submission: Submission,
    submitted_at: i64,
    completed: bool = false,
    result: ?Result = null,
};

// ============================================================================
// Tests
// ============================================================================

test "CompletionRing" {
    var ring = CompletionRing(4){};

    try std.testing.expect(ring.isEmpty());
    try std.testing.expect(!ring.isFull());

    try std.testing.expect(ring.push(.{ .bytes = 10, .user_data = 1, .flags = 0 }));
    try std.testing.expect(ring.push(.{ .bytes = 20, .user_data = 2, .flags = 0 }));
    try std.testing.expect(ring.push(.{ .bytes = 30, .user_data = 3, .flags = 0 }));

    try std.testing.expect(ring.isFull());
    try std.testing.expect(!ring.push(.{ .bytes = 40, .user_data = 4, .flags = 0 }));

    const r1 = ring.pop().?;
    try std.testing.expectEqual(@as(i32, 10), r1.bytes);

    const r2 = ring.pop().?;
    try std.testing.expectEqual(@as(i32, 20), r2.bytes);

    try std.testing.expect(!ring.isEmpty());
    try std.testing.expect(!ring.isFull());

    _ = ring.pop();
    try std.testing.expect(ring.isEmpty());
    try std.testing.expect(ring.pop() == null);
}

test "Result" {
    const success = Result{ .bytes = 100, .user_data = 1, .flags = 0 };
    try std.testing.expect(success.isSuccess());
    try std.testing.expect(success.getError() == null);

    const failure = Result{ .bytes = -2, .user_data = 2, .flags = 0 }; // ENOENT
    try std.testing.expect(!failure.isSuccess());
    try std.testing.expect(failure.getError() != null);
}

test "Submission defaults" {
    const sub = Submission{};
    try std.testing.expectEqual(OpType.nop, sub.op);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), sub.fd);
    try std.testing.expect(sub.buffer == null);
}

test "Config defaults" {
    const config = Config{};
    try std.testing.expectEqual(@as(u16, 256), config.sq_entries);
    try std.testing.expectEqual(@as(u16, 512), config.cq_entries);
    try std.testing.expect(!config.kernel_poll);
}
