//! Future combinators: all, race, any, allSettled.
//!
//! These combinators allow combining multiple futures in different ways,
//! similar to JavaScript's Promise.all, Promise.race, etc.
//!
//! ## Combinators
//!
//! - `all`: Wait for all futures to complete successfully
//! - `race`: Return the first future to complete
//! - `any`: Return the first successful future
//! - `allSettled`: Wait for all futures regardless of success/failure

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const Future = @import("future.zig").Future;
const FutureState = @import("future.zig").FutureState;
const FutureError = @import("future.zig").FutureError;
const Allocator = std.mem.Allocator;

/// Result of allSettled - either fulfilled or rejected.
pub fn SettledResult(comptime T: type) type {
    return union(enum) {
        fulfilled: T,
        rejected: void,
    };
}

/// Wait for all futures to complete successfully.
/// Returns an array of results if all succeed, or the first error.
pub fn all(
    comptime T: type,
    allocator: Allocator,
    futures: []const *Future(T),
) ![]T {
    if (futures.len == 0) {
        return &[_]T{};
    }

    const results = try allocator.alloc(T, futures.len);
    errdefer allocator.free(results);

    for (futures, 0..) |future, i| {
        results[i] = try future.await();
    }

    return results;
}

/// Wait for all futures, returning results even for failures.
pub fn allSettled(
    comptime T: type,
    allocator: Allocator,
    futures: []const *Future(T),
) ![]SettledResult(T) {
    if (futures.len == 0) {
        return &[_]SettledResult(T){};
    }

    const results = try allocator.alloc(SettledResult(T), futures.len);

    for (futures, 0..) |future, i| {
        if (future.await()) |value| {
            results[i] = .{ .fulfilled = value };
        } else |_| {
            results[i] = .rejected;
        }
    }

    return results;
}

/// Return the first future to complete (success or failure).
pub fn race(
    comptime T: type,
    futures: []const *Future(T),
) FutureError!T {
    if (futures.len == 0) {
        return FutureError.NotReady;
    }

    // Poll until one is ready
    while (true) {
        for (futures) |future| {
            if (future.isReady()) {
                return future.await();
            }
        }
        // Brief sleep before polling again
        std.Thread.sleep(10_000); // 10us
    }
}

/// Return the first successful future, or error if all fail.
pub fn any(
    comptime T: type,
    futures: []const *Future(T),
) FutureError!T {
    if (futures.len == 0) {
        return FutureError.Failed;
    }

    var completed_count: usize = 0;

    // Poll until one succeeds or all fail
    while (completed_count < futures.len) {
        for (futures) |future| {
            const state = future.getState();
            switch (state) {
                .completed => return future.value,
                .failed, .cancelled => {
                    // Count as completed but keep looking
                },
                .pending => {},
            }
        }

        // Count completed futures
        completed_count = 0;
        for (futures) |future| {
            if (future.isReady()) {
                completed_count += 1;
            }
        }

        if (completed_count < futures.len) {
            std.Thread.sleep(10_000); // 10us
        }
    }

    // All failed
    return FutureError.Failed;
}

/// Race with timeout.
pub fn raceTimeout(
    comptime T: type,
    futures: []const *Future(T),
    timeout_ns: u64,
) FutureError!T {
    if (futures.len == 0) {
        return FutureError.NotReady;
    }

    const deadline = @as(u64, @intCast(std.time.nanoTimestamp())) + timeout_ns;

    while (true) {
        for (futures) |future| {
            if (future.isReady()) {
                return future.await();
            }
        }

        const now = @as(u64, @intCast(std.time.nanoTimestamp()));
        if (now >= deadline) {
            return FutureError.Timeout;
        }

        std.Thread.sleep(10_000); // 10us
    }
}

// ============================================================================
// Tests
// ============================================================================

test "all success" {
    var f1 = try Future(u32).ready(std.testing.allocator, 1);
    defer f1.deinit();
    var f2 = try Future(u32).ready(std.testing.allocator, 2);
    defer f2.deinit();
    var f3 = try Future(u32).ready(std.testing.allocator, 3);
    defer f3.deinit();

    const futures = [_]*Future(u32){ f1, f2, f3 };
    const results = try all(u32, std.testing.allocator, &futures);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqual(@as(u32, 1), results[0]);
    try std.testing.expectEqual(@as(u32, 2), results[1]);
    try std.testing.expectEqual(@as(u32, 3), results[2]);
}

test "all with failure" {
    var f1 = try Future(u32).ready(std.testing.allocator, 1);
    defer f1.deinit();
    var f2 = try Future(u32).init(std.testing.allocator);
    defer f2.deinit();
    f2.fail();

    const futures = [_]*Future(u32){ f1, f2 };
    try std.testing.expectError(FutureError.Failed, all(u32, std.testing.allocator, &futures));
}

test "allSettled" {
    var f1 = try Future(u32).ready(std.testing.allocator, 1);
    defer f1.deinit();
    var f2 = try Future(u32).init(std.testing.allocator);
    defer f2.deinit();
    f2.fail();
    var f3 = try Future(u32).ready(std.testing.allocator, 3);
    defer f3.deinit();

    const futures = [_]*Future(u32){ f1, f2, f3 };
    const results = try allSettled(u32, std.testing.allocator, &futures);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqual(SettledResult(u32){ .fulfilled = 1 }, results[0]);
    try std.testing.expectEqual(SettledResult(u32).rejected, results[1]);
    try std.testing.expectEqual(SettledResult(u32){ .fulfilled = 3 }, results[2]);
}

test "race" {
    var f1 = try Future(u32).ready(std.testing.allocator, 42);
    defer f1.deinit();
    var f2 = try Future(u32).init(std.testing.allocator);
    defer f2.deinit();

    const futures = [_]*Future(u32){ f1, f2 };
    const result = try race(u32, &futures);

    try std.testing.expectEqual(@as(u32, 42), result);
}

test "any success" {
    var f1 = try Future(u32).init(std.testing.allocator);
    defer f1.deinit();
    f1.fail();
    var f2 = try Future(u32).ready(std.testing.allocator, 99);
    defer f2.deinit();

    const futures = [_]*Future(u32){ f1, f2 };
    const result = try any(u32, &futures);

    try std.testing.expectEqual(@as(u32, 99), result);
}

test "any all fail" {
    var f1 = try Future(u32).init(std.testing.allocator);
    defer f1.deinit();
    f1.fail();
    var f2 = try Future(u32).init(std.testing.allocator);
    defer f2.deinit();
    f2.cancel();

    const futures = [_]*Future(u32){ f1, f2 };
    try std.testing.expectError(FutureError.Failed, any(u32, &futures));
}
