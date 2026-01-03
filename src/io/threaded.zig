//! Thread-pool based I/O backend (fallback).
//!
//! This backend uses a thread pool to perform blocking I/O operations
//! asynchronously. It works on all platforms but has higher overhead
//! than native async I/O mechanisms.
//!
//! Used as a fallback when io_uring, epoll, or kqueue are unavailable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const io = @import("io.zig");

/// Thread-pool based I/O backend.
pub const ThreadedIo = struct {
    const Self = @This();

    /// Thread pool for I/O operations.
    pool: std.Thread.Pool,

    /// Pending operations.
    pending: std.AutoHashMap(u64, PendingOp),

    /// Completed results queue.
    completed: CompletionQueue,

    /// Mutex for thread safety.
    mutex: std.Thread.Mutex,

    /// Next operation ID.
    next_id: u64,

    /// Allocator.
    allocator: Allocator,

    const PendingOp = struct {
        submission: io.Submission,
        callback: ?io.CompletionCallback,
        context: ?*anyopaque,
    };

    const CompletionQueue = struct {
        items: std.ArrayListUnmanaged(io.Result),
        allocator: Allocator,

        fn init(allocator: Allocator) CompletionQueue {
            return .{
                .items = .{},
                .allocator = allocator,
            };
        }

        fn deinit(self: *CompletionQueue) void {
            self.items.deinit(self.allocator);
        }

        fn push(self: *CompletionQueue, result: io.Result) !void {
            try self.items.append(self.allocator, result);
        }

        fn pop(self: *CompletionQueue) ?io.Result {
            if (self.items.items.len == 0) return null;
            return self.items.orderedRemove(0);
        }

        fn len(self: *const CompletionQueue) usize {
            return self.items.items.len;
        }
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
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pending.count();
    }

    fn deinitVTable(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    /// Initialize threaded I/O.
    pub fn init(allocator: Allocator, config: io.Config) !*Self {
        _ = config;

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.pool = .{};
        self.pool.init(.{
            .allocator = allocator,
            .n_jobs = 4,
        });

        self.pending = std.AutoHashMap(u64, PendingOp).init(allocator);
        self.completed = CompletionQueue.init(allocator);
        self.mutex = .{};
        self.next_id = 1;
        self.allocator = allocator;

        return self;
    }

    /// Deinitialize.
    pub fn deinit(self: *Self) void {
        self.pool.deinit();
        self.pending.deinit();
        self.completed.deinit();
        self.allocator.destroy(self);
    }

    /// Submit an operation.
    pub fn submit(self: *Self, sub: *const io.Submission) io.Io.SubmitError!void {
        self.mutex.lock();

        const id = self.next_id;
        self.next_id +%= 1;

        // Store the pending operation
        self.pending.put(id, .{
            .submission = sub.*,
            .callback = sub.callback,
            .context = sub.context,
        }) catch {
            self.mutex.unlock();
            return io.Io.SubmitError.SystemError;
        };

        self.mutex.unlock();

        // Spawn a task to perform the I/O
        const task_data = TaskData{
            .self = self,
            .id = id,
            .submission = sub.*,
        };

        self.pool.spawn(executeIo, .{task_data}) catch {
            self.mutex.lock();
            _ = self.pending.remove(id);
            self.mutex.unlock();
            return io.Io.SubmitError.SystemError;
        };
    }

    const TaskData = struct {
        self: *Self,
        id: u64,
        submission: io.Submission,
    };

    fn executeIo(data: TaskData) void {
        const self = data.self;
        const id = data.id;
        const sub = data.submission;

        const bytes: i32 = switch (sub.op) {
            .nop => 0,
            .read => blk: {
                if (sub.buffer) |buf| {
                    const n = std.posix.read(sub.fd, buf) catch |err| {
                        break :blk -@as(i32, @intCast(@intFromEnum(errToErrno(err))));
                    };
                    break :blk @intCast(n);
                }
                break :blk 0;
            },
            .write => blk: {
                if (sub.buffer) |buf| {
                    const n = std.posix.write(sub.fd, buf) catch |err| {
                        break :blk -@as(i32, @intCast(@intFromEnum(errToErrno(err))));
                    };
                    break :blk @intCast(n);
                }
                break :blk 0;
            },
            .accept => blk: {
                const fd = std.posix.accept(sub.fd, sub.addr, sub.addr_len, 0) catch |err| {
                    break :blk -@as(i32, @intCast(@intFromEnum(errToErrno(err))));
                };
                break :blk @intCast(fd);
            },
            .close => blk: {
                std.posix.close(sub.fd);
                break :blk 0;
            },
            .timeout => blk: {
                std.Thread.sleep(sub.timeout_ns);
                break :blk 0;
            },
            else => -@as(i32, @intCast(@intFromEnum(std.posix.E.NOSYS))),
        };

        const result = io.Result{
            .bytes = bytes,
            .user_data = id,
            .flags = 0,
        };

        // Store result and call callback
        self.mutex.lock();

        if (self.pending.get(id)) |pending_op| {
            if (pending_op.callback) |cb| {
                self.mutex.unlock();
                cb(result, pending_op.context);
                self.mutex.lock();
            }
            _ = self.pending.remove(id);
        }

        self.completed.push(result) catch {};
        self.mutex.unlock();
    }

    /// Poll for completions.
    pub fn poll(self: *Self, timeout_ms: i32) io.Io.PollError!usize {
        const deadline = if (timeout_ms >= 0)
            @as(u64, @intCast(std.time.nanoTimestamp())) + @as(u64, @intCast(timeout_ms)) * 1_000_000
        else
            0;

        var completed: usize = 0;

        while (true) {
            self.mutex.lock();
            const has_completed = self.completed.len() > 0;
            if (has_completed) {
                while (self.completed.pop()) |_| {
                    completed += 1;
                }
            }
            const pending_count = self.pending.count();
            self.mutex.unlock();

            if (completed > 0 or pending_count == 0) {
                break;
            }

            if (timeout_ms >= 0) {
                const now = @as(u64, @intCast(std.time.nanoTimestamp()));
                if (now >= deadline) {
                    break;
                }
            }

            // Brief sleep before checking again
            std.Thread.sleep(1_000_000); // 1ms
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

test "ThreadedIo vtable exists" {
    const vt = &ThreadedIo.vtable;
    try std.testing.expect(@intFromPtr(vt.submit) != 0);
    try std.testing.expect(@intFromPtr(vt.poll) != 0);
    try std.testing.expect(@intFromPtr(vt.pending) != 0);
    try std.testing.expect(@intFromPtr(vt.deinit) != 0);
}
