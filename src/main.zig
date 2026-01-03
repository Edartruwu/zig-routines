const std = @import("std");
const zr = @import("zig_routines");

pub fn main() !void {
    std.debug.print("=== Zig-Routines: Concurrency Library Demo ===\n\n", .{});
    std.debug.print("Version: {s}\n", .{zr.version_string});
    std.debug.print("\nAvailable features:\n", .{});
    std.debug.print("  - Channels (bounded, unbounded, oneshot)\n", .{});
    std.debug.print("  - Futures & Promises with combinators\n", .{});
    std.debug.print("  - Actors with supervision trees\n", .{});
    std.debug.print("  - GenServer (OTP-style request-response)\n", .{});
    std.debug.print("  - Structured concurrency (Scope, TaskGroup)\n", .{});
    std.debug.print("  - Lock-free data structures\n", .{});
    std.debug.print("  - Work-stealing schedulers\n", .{});
    std.debug.print("  - Async I/O backends (io_uring, kqueue, epoll)\n", .{});
    std.debug.print("\nRun examples with:\n", .{});
    std.debug.print("  zig build basic_channel\n", .{});
    std.debug.print("  zig build actor_example\n", .{});
    std.debug.print("  zig build genserver_example\n", .{});
    std.debug.print("  zig build futures_example\n", .{});
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
