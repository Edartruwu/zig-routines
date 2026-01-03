//! Cache-line alignment utilities for preventing false sharing.
//!
//! False sharing occurs when multiple threads access different variables
//! that happen to reside on the same cache line, causing unnecessary
//! cache invalidation and performance degradation.
//!
//! This module provides:
//! - Cache-line aligned wrappers for atomic values
//! - Padding utilities for struct layout
//! - Platform-specific cache line size detection

const std = @import("std");
const builtin = @import("builtin");
const atomic = @import("atomic.zig");

/// Cache line size in bytes for the target architecture.
pub const size: usize = atomic.cache_line_size;

/// Aligns a type to cache line boundary with padding.
/// Use this to prevent false sharing between frequently accessed values.
///
/// Example:
/// ```zig
/// const counters = struct {
///     read_count: CacheLinePadded(Atomic(u64)),
///     write_count: CacheLinePadded(Atomic(u64)),
/// };
/// ```
pub fn Padded(comptime T: type) type {
    const t_size = @sizeOf(T);
    const remainder = t_size % size;
    const padding_size = if (remainder == 0) 0 else size - remainder;

    return struct {
        const Self = @This();

        value: T align(size),
        _padding: [padding_size]u8 = undefined,

        pub fn init(val: T) Self {
            return .{ .value = val };
        }

        pub fn get(self: *Self) *T {
            return &self.value;
        }

        pub fn getConst(self: *const Self) *const T {
            return &self.value;
        }
    };
}

/// Aligned allocation wrapper - ensures cache-line alignment.
/// Useful for arrays of values that will be accessed by different threads.
pub fn Aligned(comptime T: type) type {
    // Calculate log2 of cache line size for Alignment enum
    const log2_size = std.math.log2_int(usize, size);
    const alignment: std.mem.Alignment = @enumFromInt(log2_size);

    return struct {
        const Self = @This();

        data: []align(size) T,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, count: usize) !Self {
            const data = try allocator.alignedAlloc(T, alignment, count);
            return .{
                .data = data,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.data);
        }

        pub fn slice(self: *Self) []T {
            return self.data;
        }

        pub fn at(self: *Self, index: usize) *T {
            return &self.data[index];
        }
    };
}

/// Cache-line padded atomic counter.
/// Common pattern for per-thread counters that are later aggregated.
pub fn PaddedAtomic(comptime T: type) type {
    return Padded(atomic.Atomic(T));
}

/// Array of cache-line padded values.
/// Each element is on its own cache line to prevent false sharing.
pub fn PaddedArray(comptime T: type, comptime N: usize) type {
    return struct {
        const Self = @This();

        items: [N]Padded(T),

        pub fn init(default: T) Self {
            var self: Self = undefined;
            for (&self.items) |*item| {
                item.* = Padded(T).init(default);
            }
            return self;
        }

        pub fn initWith(f: fn (usize) T) Self {
            var self: Self = undefined;
            for (&self.items, 0..) |*item, i| {
                item.* = Padded(T).init(f(i));
            }
            return self;
        }

        pub fn at(self: *Self, index: usize) *T {
            return self.items[index].get();
        }

        pub fn atConst(self: *const Self, index: usize) *const T {
            return self.items[index].getConst();
        }
    };
}

/// Padding bytes to insert between struct fields.
/// Use when you need explicit control over struct layout.
pub fn padding(comptime current_offset: usize) type {
    const remainder = current_offset % size;
    const pad_size = if (remainder == 0) 0 else size - remainder;
    return [pad_size]u8;
}

/// Check if a pointer is cache-line aligned.
pub fn isAligned(ptr: anytype) bool {
    return @intFromPtr(ptr) % size == 0;
}

/// Round up a size to the next cache line boundary.
pub fn alignUp(n: usize) usize {
    return (n + size - 1) & ~(size - 1);
}

/// Calculate padding needed to align to cache line.
pub fn paddingNeeded(current_size: usize) usize {
    const remainder = current_size % size;
    return if (remainder == 0) 0 else size - remainder;
}

// ============================================================================
// Tests
// ============================================================================

test "Padded size is cache line aligned" {
    const P1 = Padded(u8);
    try std.testing.expectEqual(size, @sizeOf(P1));

    const P2 = Padded(u64);
    try std.testing.expectEqual(size, @sizeOf(P2));

    // Larger than cache line - should be multiple
    const BigStruct = struct { data: [100]u8 };
    const P3 = Padded(BigStruct);
    try std.testing.expect(@sizeOf(P3) % size == 0);
}

test "Padded value access" {
    var padded = Padded(u32).init(42);
    try std.testing.expectEqual(@as(u32, 42), padded.value);

    padded.get().* = 100;
    try std.testing.expectEqual(@as(u32, 100), padded.value);
}

test "PaddedAtomic operations" {
    var counter = PaddedAtomic(u64).init(atomic.Atomic(u64).init(0));

    counter.get().store(42);
    try std.testing.expectEqual(@as(u64, 42), counter.get().load());

    _ = counter.get().fetchAdd(8);
    try std.testing.expectEqual(@as(u64, 50), counter.get().load());
}

test "PaddedArray independence" {
    var arr = PaddedArray(u64, 4).init(0);

    arr.at(0).* = 1;
    arr.at(1).* = 2;
    arr.at(2).* = 3;
    arr.at(3).* = 4;

    try std.testing.expectEqual(@as(u64, 1), arr.at(0).*);
    try std.testing.expectEqual(@as(u64, 2), arr.at(1).*);
    try std.testing.expectEqual(@as(u64, 3), arr.at(2).*);
    try std.testing.expectEqual(@as(u64, 4), arr.at(3).*);

    // Each element should be on different cache lines
    const addr0 = @intFromPtr(arr.at(0));
    const addr1 = @intFromPtr(arr.at(1));
    try std.testing.expect(addr1 - addr0 >= size);
}

test "Aligned allocation" {
    var aligned = try Aligned(u64).init(std.testing.allocator, 16);
    defer aligned.deinit();

    try std.testing.expect(isAligned(aligned.data.ptr));

    for (aligned.slice(), 0..) |*val, i| {
        val.* = @intCast(i);
    }

    try std.testing.expectEqual(@as(u64, 5), aligned.at(5).*);
}

test "alignUp" {
    try std.testing.expectEqual(size, alignUp(1));
    try std.testing.expectEqual(size, alignUp(size - 1));
    try std.testing.expectEqual(size, alignUp(size));
    try std.testing.expectEqual(2 * size, alignUp(size + 1));
}

test "paddingNeeded" {
    try std.testing.expectEqual(@as(usize, 0), paddingNeeded(0));
    try std.testing.expectEqual(@as(usize, 0), paddingNeeded(size));
    try std.testing.expectEqual(size - 1, paddingNeeded(1));
    try std.testing.expectEqual(@as(usize, 1), paddingNeeded(size - 1));
}
