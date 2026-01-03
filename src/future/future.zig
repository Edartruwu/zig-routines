//! Future type for asynchronous value computation.
//!
//! A Future represents a value that will be available at some point.
//! It can be polled to check completion or awaited to block until ready.
//!
//! ## Example
//!
//! ```zig
//! const future = try Future(u32).init(allocator);
//!
//! // In producer
//! future.complete(42);
//!
//! // In consumer
//! const value = try future.await();
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const Allocator = std.mem.Allocator;

/// Future state.
pub const FutureState = enum(u8) {
    /// Future is pending (no value yet).
    pending = 0,
    /// Future completed successfully.
    completed = 1,
    /// Future completed with error.
    failed = 2,
    /// Future was cancelled.
    cancelled = 3,
};

/// Error from future operations.
pub const FutureError = error{
    /// Future was cancelled.
    Cancelled,
    /// Future failed with an error.
    Failed,
    /// Future is not ready (for tryGet).
    NotReady,
    /// Timeout expired.
    Timeout,
};

/// A future that will eventually contain a value of type T.
pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The result value (valid when state == completed).
        value: T,

        /// Current state.
        state: atomic.Atomic(FutureState),

        /// Mutex for waiting.
        mutex: std.Thread.Mutex,

        /// Condition for waiting.
        cond: std.Thread.Condition,

        /// Reference count for shared ownership.
        ref_count: atomic.Atomic(usize),

        /// Allocator.
        allocator: Allocator,

        /// Initialize a new pending future.
        pub fn init(allocator: Allocator) !*Self {
            const self = try allocator.create(Self);

            self.* = Self{
                .value = undefined,
                .state = atomic.Atomic(FutureState).init(.pending),
                .mutex = .{},
                .cond = .{},
                .ref_count = atomic.Atomic(usize).init(1),
                .allocator = allocator,
            };

            return self;
        }

        /// Create a future that's already completed.
        pub fn ready(allocator: Allocator, value: T) !*Self {
            const self = try init(allocator);
            self.value = value;
            self.state.store(.completed);
            return self;
        }

        /// Acquire a reference.
        pub fn acquire(self: *Self) *Self {
            _ = self.ref_count.fetchAdd(1);
            return self;
        }

        /// Release a reference.
        pub fn release(self: *Self) void {
            if (self.ref_count.fetchSub(1) == 1) {
                self.allocator.destroy(self);
            }
        }

        /// Deinitialize (alias for release).
        pub fn deinit(self: *Self) void {
            self.release();
        }

        /// Complete the future with a value.
        pub fn complete(self: *Self, value: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state.load() != .pending) return;

            self.value = value;
            self.state.store(.completed);
            self.cond.broadcast();
        }

        /// Fail the future.
        pub fn fail(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state.load() != .pending) return;

            self.state.store(.failed);
            self.cond.broadcast();
        }

        /// Cancel the future.
        pub fn cancel(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state.load() != .pending) return;

            self.state.store(.cancelled);
            self.cond.broadcast();
        }

        /// Poll the future (non-blocking).
        pub fn poll(self: *Self) ?T {
            const state = self.state.load();
            if (state == .completed) {
                return self.value;
            }
            return null;
        }

        /// Try to get the value without blocking.
        pub fn tryGet(self: *Self) FutureError!T {
            const state = self.state.load();
            return switch (state) {
                .pending => FutureError.NotReady,
                .completed => self.value,
                .failed => FutureError.Failed,
                .cancelled => FutureError.Cancelled,
            };
        }

        /// Await the future (blocking).
        pub fn await(self: *Self) FutureError!T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.state.load() == .pending) {
                self.cond.wait(&self.mutex);
            }

            return switch (self.state.load()) {
                .pending => unreachable,
                .completed => self.value,
                .failed => FutureError.Failed,
                .cancelled => FutureError.Cancelled,
            };
        }

        /// Await with timeout.
        pub fn awaitTimeout(self: *Self, timeout_ns: u64) FutureError!T {
            self.mutex.lock();
            defer self.mutex.unlock();

            const deadline = @as(u64, @intCast(std.time.nanoTimestamp())) + timeout_ns;

            while (self.state.load() == .pending) {
                const now = @as(u64, @intCast(std.time.nanoTimestamp()));
                if (now >= deadline) {
                    return FutureError.Timeout;
                }

                const remaining = deadline - now;
                self.cond.timedWait(&self.mutex, remaining) catch {};
            }

            return switch (self.state.load()) {
                .pending => FutureError.Timeout,
                .completed => self.value,
                .failed => FutureError.Failed,
                .cancelled => FutureError.Cancelled,
            };
        }

        /// Check if future is ready (completed, failed, or cancelled).
        pub fn isReady(self: *Self) bool {
            return self.state.load() != .pending;
        }

        /// Check if future completed successfully.
        pub fn isCompleted(self: *Self) bool {
            return self.state.load() == .completed;
        }

        /// Check if future is pending.
        pub fn isPending(self: *Self) bool {
            return self.state.load() == .pending;
        }

        /// Get the state.
        pub fn getState(self: *Self) FutureState {
            return self.state.load();
        }

        /// Map the future's value using a function.
        pub fn map(self: *Self, comptime U: type, allocator: Allocator, func: *const fn (T) U) !*Future(U) {
            const result = try Future(U).init(allocator);

            // If already complete, apply function immediately
            if (self.poll()) |value| {
                result.complete(func(value));
            }
            // Otherwise, caller must poll/wait and call map again
            // (Full implementation would spawn a task)

            return result;
        }
    };
}

/// Create a completed future.
pub fn ready(comptime T: type, allocator: Allocator, value: T) !*Future(T) {
    return Future(T).ready(allocator, value);
}

// ============================================================================
// Tests
// ============================================================================

test "Future basic" {
    var future = try Future(u32).init(std.testing.allocator);
    defer future.deinit();

    try std.testing.expect(future.isPending());
    try std.testing.expect(!future.isReady());

    future.complete(42);

    try std.testing.expect(!future.isPending());
    try std.testing.expect(future.isReady());
    try std.testing.expect(future.isCompleted());

    const value = try future.await();
    try std.testing.expectEqual(@as(u32, 42), value);
}

test "Future poll" {
    var future = try Future(u32).init(std.testing.allocator);
    defer future.deinit();

    try std.testing.expect(future.poll() == null);

    future.complete(99);

    try std.testing.expectEqual(@as(?u32, 99), future.poll());
}

test "Future tryGet" {
    var future = try Future(u32).init(std.testing.allocator);
    defer future.deinit();

    try std.testing.expectError(FutureError.NotReady, future.tryGet());

    future.complete(123);

    try std.testing.expectEqual(@as(u32, 123), try future.tryGet());
}

test "Future cancel" {
    var future = try Future(u32).init(std.testing.allocator);
    defer future.deinit();

    future.cancel();

    try std.testing.expect(future.getState() == .cancelled);
    try std.testing.expectError(FutureError.Cancelled, future.await());
}

test "Future fail" {
    var future = try Future(u32).init(std.testing.allocator);
    defer future.deinit();

    future.fail();

    try std.testing.expect(future.getState() == .failed);
    try std.testing.expectError(FutureError.Failed, future.await());
}

test "Future ready" {
    var future = try ready(u32, std.testing.allocator, 42);
    defer future.deinit();

    try std.testing.expect(future.isCompleted());
    try std.testing.expectEqual(@as(u32, 42), try future.await());
}

test "Future reference counting" {
    var future = try Future(u32).init(std.testing.allocator);

    const ref = future.acquire();
    try std.testing.expect(ref == future);

    future.complete(1);

    future.release(); // First release
    ref.release(); // Second release - this frees
}
