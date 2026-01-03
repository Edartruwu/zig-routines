//! Promise type - the writable side of a Future.
//!
//! A Promise provides a way to complete a Future from a producer.
//! It's split from Future to allow separate ownership semantics.
//!
//! ## Example
//!
//! ```zig
//! const pair = try Promise(u32).create(allocator);
//! const promise = pair.promise;
//! const future = pair.future;
//!
//! // Producer
//! promise.resolve(42);
//!
//! // Consumer
//! const value = try future.await();
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const Future = @import("future.zig").Future;
const FutureState = @import("future.zig").FutureState;
const FutureError = @import("future.zig").FutureError;
const Allocator = std.mem.Allocator;

/// A promise that can complete a future.
pub fn Promise(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The underlying future.
        future: *Future(T),

        /// Create a promise/future pair.
        pub fn create(allocator: Allocator) !struct { promise: Self, future: *Future(T) } {
            const future = try Future(T).init(allocator);

            return .{
                .promise = Self{ .future = future.acquire() },
                .future = future,
            };
        }

        /// Resolve the promise with a value.
        pub fn resolve(self: Self, value: T) void {
            self.future.complete(value);
        }

        /// Reject the promise (fail).
        pub fn reject(self: Self) void {
            self.future.fail();
        }

        /// Cancel the promise.
        pub fn cancel(self: Self) void {
            self.future.cancel();
        }

        /// Check if already resolved/rejected/cancelled.
        pub fn isSettled(self: Self) bool {
            return self.future.isReady();
        }

        /// Release the promise's reference to the future.
        pub fn deinit(self: Self) void {
            self.future.release();
        }
    };
}

/// Result type for settled promises.
pub fn SettledResult(comptime T: type) type {
    return union(enum) {
        /// Promise resolved with a value.
        fulfilled: T,
        /// Promise was rejected.
        rejected: void,
        /// Promise was cancelled.
        cancelled: void,
    };
}

/// Create a promise/future pair.
pub fn promise(comptime T: type, allocator: Allocator) !struct {
    prom: Promise(T),
    future: *Future(T),
} {
    const pair = try Promise(T).create(allocator);
    return .{
        .prom = pair.promise,
        .future = pair.future,
    };
}

/// Create an already-resolved promise.
pub fn resolved(comptime T: type, allocator: Allocator, value: T) !*Future(T) {
    return Future(T).ready(allocator, value);
}

// ============================================================================
// Tests
// ============================================================================

test "Promise basic" {
    const pair = try Promise(u32).create(std.testing.allocator);
    var prom = pair.promise;
    var future = pair.future;
    defer prom.deinit();
    defer future.deinit();

    try std.testing.expect(!prom.isSettled());
    try std.testing.expect(future.isPending());

    prom.resolve(42);

    try std.testing.expect(prom.isSettled());
    try std.testing.expect(future.isCompleted());

    const value = try future.await();
    try std.testing.expectEqual(@as(u32, 42), value);
}

test "Promise reject" {
    const pair = try Promise(u32).create(std.testing.allocator);
    var prom = pair.promise;
    var future = pair.future;
    defer prom.deinit();
    defer future.deinit();

    prom.reject();

    try std.testing.expect(prom.isSettled());
    try std.testing.expectError(FutureError.Failed, future.await());
}

test "Promise cancel" {
    const pair = try Promise(u32).create(std.testing.allocator);
    var prom = pair.promise;
    var future = pair.future;
    defer prom.deinit();
    defer future.deinit();

    prom.cancel();

    try std.testing.expect(prom.isSettled());
    try std.testing.expectError(FutureError.Cancelled, future.await());
}

test "promise helper" {
    const pair = try promise(u32, std.testing.allocator);
    var p = pair.prom;
    var future = pair.future;
    defer p.deinit();
    defer future.deinit();

    p.resolve(123);
    try std.testing.expectEqual(@as(u32, 123), try future.await());
}

test "resolved helper" {
    var future = try resolved(u32, std.testing.allocator, 99);
    defer future.deinit();

    try std.testing.expect(future.isCompleted());
    try std.testing.expectEqual(@as(u32, 99), try future.await());
}
