//! Actor Example
//!
//! Demonstrates Erlang-style actors with message passing.

const std = @import("std");
const zr = @import("zig_routines");

// Define a simple counter actor that accumulates values
const CounterActor = zr.actor.Actor(u32, u32, struct {
    pub fn handle(state: *u32, msg: u32) void {
        state.* += msg;
        std.debug.print("  Counter received {}, total: {}\n", .{ msg, state.* });
    }

    pub fn onStart(state: *u32) void {
        _ = state;
        std.debug.print("  Counter actor started!\n", .{});
    }

    pub fn onStop(state: *u32) void {
        std.debug.print("  Counter actor stopped. Final value: {}\n", .{state.*});
    }
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Zig-Routines: Actor Example ===\n\n", .{});

    // Spawn a counter actor with initial state 0
    std.debug.print("Spawning counter actor...\n", .{});
    var actor = try CounterActor.spawn(allocator, 0);

    // Give time for the actor to start
    std.Thread.sleep(10_000_000); // 10ms

    std.debug.print("\nSending messages to actor...\n", .{});

    // Send some messages
    try actor.send(5);
    try actor.send(10);
    try actor.send(7);

    // Give time for messages to be processed
    std.Thread.sleep(50_000_000); // 50ms

    std.debug.print("\nStopping actor...\n", .{});
    actor.stop();

    std.debug.print("\n=== Example Complete ===\n", .{});
}
