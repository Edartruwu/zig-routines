//! Extended atomic operations for lock-free programming.
//!
//! Provides utilities beyond std.atomic including:
//! - Atomic optional pointers with tag support
//! - Fetch operations with custom functions
//! - Backoff strategies for spin loops
//! - Memory ordering helpers

const std = @import("std");
const builtin = @import("builtin");

/// Cache line size for the target architecture.
/// Used for padding to prevent false sharing.
pub const cache_line_size: usize = switch (builtin.cpu.arch) {
    .x86_64, .x86 => 64,
    .aarch64, .arm => 64,
    .riscv64, .riscv32 => 64,
    else => 64, // Conservative default
};

/// Atomic value wrapper with enhanced operations.
pub fn Atomic(comptime T: type) type {
    return struct {
        const Self = @This();

        value: std.atomic.Value(T),

        pub fn init(initial: T) Self {
            return .{ .value = std.atomic.Value(T).init(initial) };
        }

        /// Load with acquire ordering (default for reads).
        pub inline fn load(self: *const Self) T {
            return self.value.load(.acquire);
        }

        /// Load with specified ordering.
        pub inline fn loadOrdering(self: *const Self, comptime ordering: std.atomic.Ordering) T {
            return self.value.load(ordering);
        }

        /// Store with release ordering (default for writes).
        pub inline fn store(self: *Self, val: T) void {
            self.value.store(val, .release);
        }

        /// Store with specified ordering.
        pub inline fn storeOrdering(self: *Self, val: T, comptime ordering: std.atomic.Ordering) void {
            self.value.store(val, ordering);
        }

        /// Atomic exchange - returns old value.
        pub inline fn swap(self: *Self, new_val: T) T {
            return self.value.swap(new_val, .acq_rel);
        }

        /// Compare and swap - returns old value.
        /// Success if old value equals `expected`, then stores `new_val`.
        pub inline fn compareAndSwap(self: *Self, expected: T, new_val: T) ?T {
            return self.value.cmpxchgWeak(expected, new_val, .acq_rel, .acquire);
        }

        /// Strong compare and swap - no spurious failures.
        pub inline fn compareAndSwapStrong(self: *Self, expected: T, new_val: T) ?T {
            return self.value.cmpxchgStrong(expected, new_val, .acq_rel, .acquire);
        }

        /// Fetch and add (for integer types).
        pub inline fn fetchAdd(self: *Self, delta: T) T {
            return self.value.fetchAdd(delta, .acq_rel);
        }

        /// Fetch and subtract (for integer types).
        pub inline fn fetchSub(self: *Self, delta: T) T {
            return self.value.fetchSub(delta, .acq_rel);
        }

        /// Fetch and bitwise OR.
        pub inline fn fetchOr(self: *Self, val: T) T {
            return self.value.fetchOr(val, .acq_rel);
        }

        /// Fetch and bitwise AND.
        pub inline fn fetchAnd(self: *Self, val: T) T {
            return self.value.fetchAnd(val, .acq_rel);
        }

        /// Fetch and bitwise XOR.
        pub inline fn fetchXor(self: *Self, val: T) T {
            return self.value.fetchXor(val, .acq_rel);
        }

        /// Raw access to underlying atomic value.
        pub inline fn raw(self: *Self) *std.atomic.Value(T) {
            return &self.value;
        }

        /// Raw const access to underlying atomic value.
        pub inline fn rawConst(self: *const Self) *const std.atomic.Value(T) {
            return &self.value;
        }
    };
}

/// Atomic optional pointer with ABA-prevention tag.
/// Uses upper bits for tag on 64-bit systems.
pub fn AtomicTaggedPtr(comptime T: type) type {
    const PtrInt = usize;
    const TagBits = 16; // Upper 16 bits for tag
    const TagMask: PtrInt = (@as(PtrInt, 1) << TagBits) - 1;
    const PtrMask: PtrInt = ~(TagMask << (64 - TagBits));

    return struct {
        const Self = @This();

        value: std.atomic.Value(PtrInt),

        pub const Tagged = struct {
            ptr: ?*T,
            tag: u16,
        };

        pub fn init(ptr: ?*T, tag: u16) Self {
            return .{ .value = std.atomic.Value(PtrInt).init(pack(ptr, tag)) };
        }

        fn pack(ptr: ?*T, tag: u16) PtrInt {
            const ptr_val: PtrInt = if (ptr) |p| @intFromPtr(p) else 0;
            return (ptr_val & PtrMask) | (@as(PtrInt, tag) << (64 - TagBits));
        }

        fn unpack(val: PtrInt) Tagged {
            const ptr_val = val & PtrMask;
            const tag: u16 = @truncate(val >> (64 - TagBits));
            return .{
                .ptr = if (ptr_val != 0) @ptrFromInt(ptr_val) else null,
                .tag = tag,
            };
        }

        pub fn load(self: *const Self) Tagged {
            return unpack(self.value.load(.acquire));
        }

        pub fn store(self: *Self, ptr: ?*T, tag: u16) void {
            self.value.store(pack(ptr, tag), .release);
        }

        /// Compare and swap with tag check for ABA prevention.
        pub fn compareAndSwap(
            self: *Self,
            expected_ptr: ?*T,
            expected_tag: u16,
            new_ptr: ?*T,
            new_tag: u16,
        ) ?Tagged {
            const expected = pack(expected_ptr, expected_tag);
            const new_val = pack(new_ptr, new_tag);
            if (self.value.cmpxchgWeak(expected, new_val, .acq_rel, .acquire)) |old| {
                return unpack(old);
            }
            return null;
        }
    };
}

/// Exponential backoff for spin loops.
/// Reduces contention and power consumption.
pub const Backoff = struct {
    const Self = @This();

    const MIN_SPIN: u32 = 4;
    const MAX_SPIN: u32 = 1024;

    spin_count: u32 = MIN_SPIN,

    /// Spin for a short time, increasing delay exponentially.
    pub fn spin(self: *Self) void {
        var i: u32 = 0;
        while (i < self.spin_count) : (i += 1) {
            std.atomic.spinLoopHint();
        }
        self.spin_count = @min(self.spin_count * 2, MAX_SPIN);
    }

    /// Reset backoff to minimum.
    pub fn reset(self: *Self) void {
        self.spin_count = MIN_SPIN;
    }

    /// Check if we've hit max backoff (should yield to OS).
    pub fn isMaxed(self: *const Self) bool {
        return self.spin_count >= MAX_SPIN;
    }

    /// Spin or yield depending on backoff state.
    pub fn snooze(self: *Self) void {
        if (self.isMaxed()) {
            std.Thread.yield() catch {};
        } else {
            self.spin();
        }
    }
};

/// Atomic flag (single bit) with test-and-set semantics.
pub const AtomicFlag = struct {
    const Self = @This();

    value: std.atomic.Value(u8),

    pub fn init(set: bool) Self {
        return .{ .value = std.atomic.Value(u8).init(if (set) 1 else 0) };
    }

    /// Test and set - returns previous value.
    pub fn testAndSet(self: *Self) bool {
        return self.value.swap(1, .acq_rel) != 0;
    }

    /// Clear the flag.
    pub fn clear(self: *Self) void {
        self.value.store(0, .release);
    }

    /// Check if set without modifying.
    pub fn isSet(self: *const Self) bool {
        return self.value.load(.acquire) != 0;
    }
};

/// Sequence lock for optimistic readers with writer exclusion.
/// Readers retry if write occurred during read.
pub const SeqLock = struct {
    const Self = @This();

    sequence: Atomic(usize),

    pub fn init() Self {
        return .{ .sequence = Atomic(usize).init(0) };
    }

    /// Begin write - acquires exclusive access.
    pub fn writeLock(self: *Self) void {
        // Increment to odd (write in progress)
        // Use acq_rel ordering for the fence effect
        _ = self.sequence.raw().fetchAdd(1, .acq_rel);
    }

    /// End write - releases exclusive access.
    pub fn writeUnlock(self: *Self) void {
        // Increment to even (write complete)
        // Use release ordering
        _ = self.sequence.raw().fetchAdd(1, .release);
    }

    /// Begin read - returns sequence number to validate.
    pub fn readBegin(self: *const Self) usize {
        var seq = self.sequence.rawConst().load(.acquire);
        while (seq & 1 != 0) {
            // Write in progress, spin
            std.atomic.spinLoopHint();
            seq = self.sequence.rawConst().load(.acquire);
        }
        return seq;
    }

    /// Validate read - returns true if read was consistent.
    pub fn readValidate(self: *const Self, start_seq: usize) bool {
        // Load with acquire ordering to ensure we see all writes
        return self.sequence.rawConst().load(.acquire) == start_seq;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Atomic basic operations" {
    var a = Atomic(u64).init(0);

    a.store(42);
    try std.testing.expectEqual(@as(u64, 42), a.load());

    const old = a.swap(100);
    try std.testing.expectEqual(@as(u64, 42), old);
    try std.testing.expectEqual(@as(u64, 100), a.load());
}

test "Atomic compare and swap" {
    var a = Atomic(u64).init(10);

    // Should fail - expected doesn't match
    const result1 = a.compareAndSwap(5, 20);
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual(@as(u64, 10), a.load());

    // Should succeed
    const result2 = a.compareAndSwap(10, 20);
    try std.testing.expect(result2 == null);
    try std.testing.expectEqual(@as(u64, 20), a.load());
}

test "Atomic fetch operations" {
    var a = Atomic(i32).init(10);

    try std.testing.expectEqual(@as(i32, 10), a.fetchAdd(5));
    try std.testing.expectEqual(@as(i32, 15), a.load());

    try std.testing.expectEqual(@as(i32, 15), a.fetchSub(3));
    try std.testing.expectEqual(@as(i32, 12), a.load());
}

test "AtomicTaggedPtr" {
    var node: u64 = 42;

    var tagged = AtomicTaggedPtr(u64).init(&node, 0);
    const loaded = tagged.load();
    try std.testing.expectEqual(&node, loaded.ptr.?);
    try std.testing.expectEqual(@as(u16, 0), loaded.tag);

    // Update with new tag
    tagged.store(&node, 1);
    const loaded2 = tagged.load();
    try std.testing.expectEqual(@as(u16, 1), loaded2.tag);
}

test "Backoff exponential growth" {
    var backoff = Backoff{};

    try std.testing.expectEqual(@as(u32, 4), backoff.spin_count);

    backoff.spin();
    try std.testing.expectEqual(@as(u32, 8), backoff.spin_count);

    backoff.spin();
    try std.testing.expectEqual(@as(u32, 16), backoff.spin_count);

    backoff.reset();
    try std.testing.expectEqual(@as(u32, 4), backoff.spin_count);
}

test "AtomicFlag" {
    var flag = AtomicFlag.init(false);

    try std.testing.expect(!flag.isSet());
    try std.testing.expect(!flag.testAndSet());
    try std.testing.expect(flag.isSet());
    try std.testing.expect(flag.testAndSet());

    flag.clear();
    try std.testing.expect(!flag.isSet());
}

test "SeqLock basic usage" {
    var lock = SeqLock.init();

    // Read without contention
    const seq = lock.readBegin();
    try std.testing.expect(lock.readValidate(seq));

    // Write then read
    lock.writeLock();
    lock.writeUnlock();

    const seq2 = lock.readBegin();
    try std.testing.expect(lock.readValidate(seq2));
    try std.testing.expect(seq2 > seq);
}
