//! Cancellation tokens for cooperative cancellation.
//!
//! CancelToken provides a lightweight way to propagate cancellation
//! through a computation tree. It's simpler than full Context when
//! you only need cancellation (no deadlines/values).
//!
//! ## Example
//!
//! ```zig
//! var token = CancelToken.init();
//!
//! // Pass to workers
//! spawnWorker(&token);
//!
//! // Later, cancel all workers
//! token.cancel();
//!
//! // Workers check:
//! if (token.isCancelled()) return;
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const Allocator = std.mem.Allocator;

/// Cancel token state.
pub const TokenState = enum(u8) {
    /// Token is active (not cancelled).
    active = 0,
    /// Token has been cancelled.
    cancelled = 1,
};

/// A lightweight cancellation token.
pub const CancelToken = struct {
    const Self = @This();

    /// Current state.
    state: atomic.Atomic(TokenState),

    /// Optional callback on cancellation.
    on_cancel: ?*const fn () void,

    /// Initialize a new active token.
    pub fn init() Self {
        return .{
            .state = atomic.Atomic(TokenState).init(.active),
            .on_cancel = null,
        };
    }

    /// Initialize with a cancellation callback.
    pub fn initWithCallback(callback: *const fn () void) Self {
        return .{
            .state = atomic.Atomic(TokenState).init(.active),
            .on_cancel = callback,
        };
    }

    /// Cancel the token.
    pub fn cancel(self: *Self) void {
        const prev = self.state.compareAndSwap(.active, .cancelled);
        if (prev == null) {
            // Successfully cancelled
            if (self.on_cancel) |callback| {
                callback();
            }
        }
    }

    /// Check if cancelled.
    pub fn isCancelled(self: *const Self) bool {
        return self.state.load() == .cancelled;
    }

    /// Check if active.
    pub fn isActive(self: *const Self) bool {
        return self.state.load() == .active;
    }

    /// Throw if cancelled.
    pub fn throwIfCancelled(self: *const Self) CancelError!void {
        if (self.isCancelled()) {
            return CancelError.Cancelled;
        }
    }

    /// Reset to active state.
    pub fn reset(self: *Self) void {
        self.state.store(.active);
    }
};

/// Error from cancellation check.
pub const CancelError = error{
    Cancelled,
};

/// A cancellation token source that can create child tokens.
pub const CancelTokenSource = struct {
    const Self = @This();

    /// The root token.
    token: CancelToken,

    /// Child tokens (for propagation).
    children: std.ArrayListUnmanaged(*CancelToken),

    /// Allocator.
    allocator: Allocator,

    /// Mutex for child list.
    mutex: std.Thread.Mutex,

    /// Initialize a new token source.
    pub fn init(allocator: Allocator) Self {
        return .{
            .token = CancelToken.init(),
            .children = .{},
            .allocator = allocator,
            .mutex = .{},
        };
    }

    /// Deinitialize.
    pub fn deinit(self: *Self) void {
        self.children.deinit(self.allocator);
    }

    /// Get the token.
    pub fn getToken(self: *Self) *CancelToken {
        return &self.token;
    }

    /// Register a child token to be cancelled when this is cancelled.
    pub fn registerChild(self: *Self, child: *CancelToken) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.children.append(self.allocator, child);

        // If already cancelled, cancel child immediately
        if (self.token.isCancelled()) {
            child.cancel();
        }
    }

    /// Unregister a child token.
    pub fn unregisterChild(self: *Self, child: *CancelToken) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.children.items, 0..) |c, i| {
            if (c == child) {
                _ = self.children.swapRemove(i);
                break;
            }
        }
    }

    /// Cancel this source and all children.
    pub fn cancel(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.token.cancel();

        // Cancel all children
        for (self.children.items) |child| {
            child.cancel();
        }
    }

    /// Check if cancelled.
    pub fn isCancelled(self: *const Self) bool {
        return self.token.isCancelled();
    }
};

/// Linked cancellation token - cancelled when any parent is cancelled.
pub const LinkedCancelToken = struct {
    const Self = @This();

    /// The token.
    token: CancelToken,

    /// Parent tokens.
    parents: []*const CancelToken,

    /// Initialize linked to parents.
    pub fn init(parents: []*const CancelToken) Self {
        return .{
            .token = CancelToken.init(),
            .parents = parents,
        };
    }

    /// Check if cancelled (self or any parent).
    pub fn isCancelled(self: *const Self) bool {
        if (self.token.isCancelled()) return true;

        for (self.parents) |parent| {
            if (parent.isCancelled()) return true;
        }

        return false;
    }

    /// Cancel this token.
    pub fn cancel(self: *Self) void {
        self.token.cancel();
    }

    /// Get as a regular CancelToken pointer.
    pub fn asToken(self: *Self) *CancelToken {
        return &self.token;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "CancelToken basic" {
    var token = CancelToken.init();

    try std.testing.expect(token.isActive());
    try std.testing.expect(!token.isCancelled());

    token.cancel();

    try std.testing.expect(!token.isActive());
    try std.testing.expect(token.isCancelled());
}

test "CancelToken throwIfCancelled" {
    var token = CancelToken.init();

    try token.throwIfCancelled(); // Should not throw

    token.cancel();

    try std.testing.expectError(CancelError.Cancelled, token.throwIfCancelled());
}

test "CancelToken callback" {
    // Test that callback mechanism exists
    var token = CancelToken.initWithCallback(struct {
        fn callback() void {
            // This would be called on cancellation
        }
    }.callback);

    try std.testing.expect(token.isActive());
    try std.testing.expect(token.on_cancel != null);

    token.cancel();
    try std.testing.expect(token.isCancelled());
}

test "CancelToken reset" {
    var token = CancelToken.init();

    token.cancel();
    try std.testing.expect(token.isCancelled());

    token.reset();
    try std.testing.expect(token.isActive());
}

test "CancelTokenSource" {
    var source = CancelTokenSource.init(std.testing.allocator);
    defer source.deinit();

    var child = CancelToken.init();

    try source.registerChild(&child);

    try std.testing.expect(!source.isCancelled());
    try std.testing.expect(!child.isCancelled());

    source.cancel();

    try std.testing.expect(source.isCancelled());
    try std.testing.expect(child.isCancelled());
}

test "LinkedCancelToken" {
    var parent1 = CancelToken.init();
    var parent2 = CancelToken.init();

    const parents = [_]*const CancelToken{ &parent1, &parent2 };
    var linked = LinkedCancelToken.init(@constCast(&parents));

    try std.testing.expect(!linked.isCancelled());

    parent1.cancel();

    try std.testing.expect(linked.isCancelled());
}
