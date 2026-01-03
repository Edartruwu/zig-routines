//! Read-write lock for shared/exclusive access patterns.
//!
//! RwLock allows multiple concurrent readers OR a single writer.
//! Writers have priority to prevent starvation.
//!
//! ## Example
//!
//! ```zig
//! var lock = RwLock.init();
//!
//! // Read access (multiple allowed)
//! lock.lockShared();
//! defer lock.unlockShared();
//! const value = shared_data;
//!
//! // Write access (exclusive)
//! lock.lockExclusive();
//! defer lock.unlockExclusive();
//! shared_data = new_value;
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");

/// State encoding:
/// - Bits 0-29: reader count
/// - Bit 30: writer waiting flag
/// - Bit 31: writer active flag
const READER_MASK: u32 = 0x3FFFFFFF; // Lower 30 bits
const WRITER_WAITING: u32 = 0x40000000; // Bit 30
const WRITER_ACTIVE: u32 = 0x80000000; // Bit 31

/// Read-write lock with writer priority.
pub const RwLock = struct {
    const Self = @This();

    /// Lock state.
    state: atomic.Atomic(u32),

    /// Event for readers waiting.
    reader_event: std.Thread.ResetEvent,

    /// Event for writers waiting.
    writer_event: std.Thread.ResetEvent,

    /// Initialize an unlocked RwLock.
    pub fn init() Self {
        return .{
            .state = atomic.Atomic(u32).init(0),
            .reader_event = .{},
            .writer_event = .{},
        };
    }

    /// Acquire a shared (read) lock.
    pub fn lockShared(self: *Self) void {
        var backoff: atomic.Backoff = .{};

        while (true) {
            const state = self.state.load();

            // Can acquire if no writer active or waiting
            if ((state & (WRITER_ACTIVE | WRITER_WAITING)) == 0) {
                const new_state = state + 1;
                if (self.state.compareAndSwap(state, new_state) == null) {
                    return;
                }
            } else {
                // Writer active or waiting - wait
                self.reader_event.wait();
            }

            backoff.snooze();
        }
    }

    /// Release a shared lock.
    pub fn unlockShared(self: *Self) void {
        const old_state = self.state.fetchSub(1);
        const readers = (old_state & READER_MASK) - 1;

        // If this was the last reader and a writer is waiting, wake it
        if (readers == 0 and (old_state & WRITER_WAITING) != 0) {
            self.writer_event.set();
        }
    }

    /// Try to acquire a shared lock without blocking.
    pub fn tryLockShared(self: *Self) bool {
        const state = self.state.load();

        // Can't acquire if writer active or waiting
        if ((state & (WRITER_ACTIVE | WRITER_WAITING)) != 0) {
            return false;
        }

        return self.state.compareAndSwap(state, state + 1) == null;
    }

    /// Acquire an exclusive (write) lock.
    pub fn lockExclusive(self: *Self) void {
        var backoff: atomic.Backoff = .{};

        // First, set writer waiting flag
        while (true) {
            const state = self.state.load();

            if ((state & WRITER_WAITING) == 0) {
                if (self.state.compareAndSwap(state, state | WRITER_WAITING) == null) {
                    break;
                }
            } else {
                break;
            }
            backoff.snooze();
        }

        // Now wait for exclusive access
        while (true) {
            const state = self.state.load();
            const readers = state & READER_MASK;

            if (readers == 0 and (state & WRITER_ACTIVE) == 0) {
                // No readers and no active writer - acquire
                const new_state = (state & ~WRITER_WAITING) | WRITER_ACTIVE;
                if (self.state.compareAndSwap(state, new_state) == null) {
                    return;
                }
            } else {
                // Wait for readers/writer to finish
                self.writer_event.wait();
                self.writer_event.reset();
            }

            backoff.snooze();
        }
    }

    /// Release an exclusive lock.
    pub fn unlockExclusive(self: *Self) void {
        _ = self.state.raw().fetchAnd(~WRITER_ACTIVE, .release);

        // Wake all waiting readers
        self.reader_event.set();
        std.Thread.yield() catch {};
        self.reader_event.reset();
    }

    /// Try to acquire an exclusive lock without blocking.
    pub fn tryLockExclusive(self: *Self) bool {
        const state = self.state.load();

        // Can only acquire if completely unlocked
        if (state != 0) {
            return false;
        }

        return self.state.compareAndSwap(0, WRITER_ACTIVE) == null;
    }

    /// Try to upgrade a shared lock to exclusive.
    /// Returns false if upgrade not possible (other readers present).
    pub fn tryUpgrade(self: *Self) bool {
        const state = self.state.load();
        const readers = state & READER_MASK;

        // Can only upgrade if we're the only reader
        if (readers != 1) {
            return false;
        }

        // Try to swap from 1 reader to writer active
        return self.state.compareAndSwap(1, WRITER_ACTIVE) == null;
    }

    /// Downgrade an exclusive lock to shared.
    pub fn downgrade(self: *Self) void {
        // Swap from writer active to 1 reader
        const old_state = self.state.raw().swap(1, .acq_rel);
        std.debug.assert((old_state & WRITER_ACTIVE) != 0);

        // Wake waiting readers
        self.reader_event.set();
        std.Thread.yield() catch {};
        self.reader_event.reset();
    }

    /// Get current reader count.
    pub fn readerCount(self: *const Self) u32 {
        return self.state.load() & READER_MASK;
    }

    /// Check if a writer is active.
    pub fn isWriteLocked(self: *const Self) bool {
        return (self.state.load() & WRITER_ACTIVE) != 0;
    }

    /// Check if any readers are active.
    pub fn isReadLocked(self: *const Self) bool {
        return (self.state.load() & READER_MASK) > 0;
    }
};

/// Fair RwLock with FIFO ordering for waiters.
pub const FairRwLock = struct {
    const Self = @This();

    /// Reader count.
    readers: atomic.Atomic(u32),

    /// Writer active flag.
    writer_active: atomic.Atomic(bool),

    /// Next ticket.
    next_ticket: atomic.Atomic(u32),

    /// Now serving.
    now_serving: atomic.Atomic(u32),

    /// Initialize.
    pub fn init() Self {
        return .{
            .readers = atomic.Atomic(u32).init(0),
            .writer_active = atomic.Atomic(bool).init(false),
            .next_ticket = atomic.Atomic(u32).init(0),
            .now_serving = atomic.Atomic(u32).init(0),
        };
    }

    /// Acquire shared lock with FIFO ordering.
    pub fn lockShared(self: *Self) void {
        const ticket = self.next_ticket.fetchAdd(1);
        var backoff: atomic.Backoff = .{};

        // Wait for our turn
        while (self.now_serving.load() != ticket) {
            backoff.snooze();
        }

        // Wait for no writer
        while (self.writer_active.load()) {
            backoff.snooze();
        }

        _ = self.readers.fetchAdd(1);
        _ = self.now_serving.fetchAdd(1);
    }

    /// Release shared lock.
    pub fn unlockShared(self: *Self) void {
        _ = self.readers.fetchSub(1);
    }

    /// Acquire exclusive lock with FIFO ordering.
    pub fn lockExclusive(self: *Self) void {
        const ticket = self.next_ticket.fetchAdd(1);
        var backoff: atomic.Backoff = .{};

        // Wait for our turn
        while (self.now_serving.load() != ticket) {
            backoff.snooze();
        }

        // Wait for no readers and no writer
        while (self.readers.load() > 0 or self.writer_active.load()) {
            backoff.snooze();
        }

        self.writer_active.store(true);
        _ = self.now_serving.fetchAdd(1);
    }

    /// Release exclusive lock.
    pub fn unlockExclusive(self: *Self) void {
        self.writer_active.store(false);
    }
};

/// Scoped read guard.
pub fn ReadGuard(comptime LockType: type) type {
    return struct {
        const Self = @This();

        lock: *LockType,

        pub fn init(lock: *LockType) Self {
            lock.lockShared();
            return .{ .lock = lock };
        }

        pub fn deinit(self: Self) void {
            self.lock.unlockShared();
        }
    };
}

/// Scoped write guard.
pub fn WriteGuard(comptime LockType: type) type {
    return struct {
        const Self = @This();

        lock: *LockType,

        pub fn init(lock: *LockType) Self {
            lock.lockExclusive();
            return .{ .lock = lock };
        }

        pub fn deinit(self: Self) void {
            self.lock.unlockExclusive();
        }

        /// Downgrade to read guard.
        pub fn downgrade(self: *Self) ReadGuard(LockType) {
            self.lock.downgrade();
            return .{ .lock = self.lock };
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "RwLock shared basic" {
    var lock = RwLock.init();

    lock.lockShared();
    try std.testing.expect(lock.isReadLocked());
    try std.testing.expectEqual(@as(u32, 1), lock.readerCount());

    lock.lockShared(); // Multiple readers allowed
    try std.testing.expectEqual(@as(u32, 2), lock.readerCount());

    lock.unlockShared();
    lock.unlockShared();
    try std.testing.expect(!lock.isReadLocked());
}

test "RwLock exclusive basic" {
    var lock = RwLock.init();

    lock.lockExclusive();
    try std.testing.expect(lock.isWriteLocked());

    lock.unlockExclusive();
    try std.testing.expect(!lock.isWriteLocked());
}

test "RwLock tryLock" {
    var lock = RwLock.init();

    try std.testing.expect(lock.tryLockShared());
    try std.testing.expect(lock.tryLockShared()); // Multiple readers
    try std.testing.expect(!lock.tryLockExclusive()); // Can't get exclusive with readers

    lock.unlockShared();
    lock.unlockShared();

    try std.testing.expect(lock.tryLockExclusive());
    try std.testing.expect(!lock.tryLockShared()); // Can't read with writer
    try std.testing.expect(!lock.tryLockExclusive()); // Can't get another exclusive

    lock.unlockExclusive();
}

test "RwLock upgrade" {
    var lock = RwLock.init();

    lock.lockShared();
    try std.testing.expect(lock.tryUpgrade()); // Only reader, can upgrade
    try std.testing.expect(lock.isWriteLocked());

    lock.unlockExclusive();
}

test "RwLock downgrade" {
    var lock = RwLock.init();

    lock.lockExclusive();
    lock.downgrade();

    try std.testing.expect(!lock.isWriteLocked());
    try std.testing.expect(lock.isReadLocked());
    try std.testing.expectEqual(@as(u32, 1), lock.readerCount());

    lock.unlockShared();
}

test "FairRwLock basic" {
    var lock = FairRwLock.init();

    lock.lockShared();
    lock.unlockShared();

    lock.lockExclusive();
    lock.unlockExclusive();
}

test "ReadGuard" {
    var lock = RwLock.init();

    {
        const guard = ReadGuard(RwLock).init(&lock);
        defer guard.deinit();

        try std.testing.expect(lock.isReadLocked());
    }

    try std.testing.expect(!lock.isReadLocked());
}

test "WriteGuard" {
    var lock = RwLock.init();

    {
        const guard = WriteGuard(RwLock).init(&lock);
        defer guard.deinit();

        try std.testing.expect(lock.isWriteLocked());
    }

    try std.testing.expect(!lock.isWriteLocked());
}
