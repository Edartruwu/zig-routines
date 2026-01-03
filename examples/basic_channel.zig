//! Basic Channel Example
//!
//! Demonstrates Go-style CSP channels for communication between threads.

const std = @import("std");
const zr = @import("zig_routines");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Zig-Routines: Basic Channel Example ===\n\n", .{});

    // Create a bounded channel with capacity 5
    var ch = try zr.channel.BoundedChannel(u32).init(allocator, 5);
    defer ch.deinit();

    std.debug.print("Created bounded channel with capacity 5\n", .{});

    // Send some values
    try ch.send(10);
    try ch.send(20);
    try ch.send(30);
    std.debug.print("Sent: 10, 20, 30\n", .{});
    std.debug.print("Channel length: {}\n", .{ch.len()});

    // Receive values
    const val1 = try ch.recv();
    std.debug.print("Received: {}\n", .{val1});

    const val2 = try ch.recv();
    std.debug.print("Received: {}\n", .{val2});

    const val3 = try ch.recv();
    std.debug.print("Received: {}\n", .{val3});

    std.debug.print("\nChannel is empty: {}\n", .{ch.isEmpty()});

    // Close the channel
    ch.close();
    std.debug.print("Channel closed\n", .{});

    std.debug.print("\n=== Example Complete ===\n", .{});
}
