//! Futures Example
//!
//! Demonstrates async values with futures and promises.

const std = @import("std");
const zr = @import("zig_routines");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Zig-Routines: Futures Example ===\n\n", .{});

    // Create a promise/future pair
    std.debug.print("Creating promise/future pair...\n", .{});
    const pair = try zr.future.Promise(u32).create(allocator);
    const prom = pair.promise;
    var fut = pair.future;
    defer fut.deinit();
    defer prom.deinit();

    std.debug.print("Future state: {s}\n", .{@tagName(fut.getState())});

    // Resolve the promise
    std.debug.print("\nResolving promise with value 42...\n", .{});
    prom.resolve(42);

    std.debug.print("Future state: {s}\n", .{@tagName(fut.getState())});

    // Get the value
    if (fut.poll()) |value| {
        std.debug.print("Future resolved with value: {}\n", .{value});
    }

    // Demonstrate oneshot channel (single-use promise)
    std.debug.print("\n--- Oneshot Channel Demo ---\n", .{});

    const OneshotChannel = zr.channel.OneshotChannel;
    const oneshot_pair = try OneshotChannel(u32).init(allocator);
    const sender = oneshot_pair.sender;
    const receiver = oneshot_pair.receiver;
    defer sender.deinit();
    defer receiver.deinit();

    std.debug.print("Sending value through oneshot...\n", .{});
    try sender.send(123);

    if (receiver.tryRecv()) |msg| {
        std.debug.print("Received: {}\n", .{msg});
    }

    std.debug.print("\n=== Example Complete ===\n", .{});
}
