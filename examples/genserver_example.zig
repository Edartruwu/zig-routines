//! GenServer Example
//!
//! Demonstrates OTP-style GenServer for request-response actors.

const std = @import("std");
const zr = @import("zig_routines");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Zig-Routines: GenServer Example ===\n\n", .{});

    // Use the built-in CounterServer
    std.debug.print("Starting CounterServer...\n", .{});
    var server = try zr.actor.CounterServer.start(allocator);

    // Give time for the server to start
    std.Thread.sleep(10_000_000); // 10ms

    std.debug.print("Server is running: {}\n\n", .{server.isRunning()});

    // Make synchronous calls
    std.debug.print("Making synchronous calls...\n", .{});

    const result1 = try server.call(5);
    std.debug.print("  call(5) -> {}\n", .{result1});

    const result2 = try server.call(10);
    std.debug.print("  call(10) -> {}\n", .{result2});

    const result3 = try server.call(-3);
    std.debug.print("  call(-3) -> {}\n", .{result3});

    std.debug.print("\nFinal counter value: {}\n", .{result3});

    std.debug.print("\nStopping server...\n", .{});
    server.stop();

    std.debug.print("\n=== Example Complete ===\n", .{});
}
