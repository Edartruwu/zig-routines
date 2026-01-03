//! Cancellation context for cooperative task cancellation.
//!
//! Contexts provide a structured way to propagate cancellation signals
//! through a hierarchy of tasks. Inspired by Go's context package.
//!
//! ## Usage
//!
//! ```zig
//! // Create a cancellable context
//! var ctx = Context.init();
//!
//! // Pass to tasks
//! var task = Task.initWithContext(myCallback, &ctx);
//!
//! // Tasks check for cancellation
//! fn myCallback(task: *Task) void {
//!     while (doWork()) {
//!         if (task.isCancelled()) return;
//!     }
//! }
//!
//! // Cancel from another thread/task
//! ctx.cancel();
//! ```
//!
//! ## Hierarchical Cancellation
//!
//! Contexts can form a tree. Cancelling a parent cancels all children:
//!
//! ```zig
//! var parent = Context.init();
//! var child = Context.withParent(&parent);
//!
//! parent.cancel(); // Also cancels child
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");

/// Reason for cancellation.
pub const CancelReason = enum(u8) {
    /// Not cancelled
    none,
    /// Explicitly cancelled via cancel()
    cancelled,
    /// Cancelled due to timeout/deadline
    timeout,
    /// Cancelled because parent was cancelled
    parent_cancelled,
    /// Cancelled due to error in sibling task
    error_propagation,
};

/// Context for cancellation propagation.
///
/// Contexts are thread-safe and support hierarchical cancellation.
/// Multiple tasks can share a context, and cancelling it signals
/// all associated tasks to stop.
pub const Context = struct {
    const Self = @This();

    /// Cancellation state (atomic for thread-safe access)
    cancelled: atomic.Atomic(CancelReason),

    /// Parent context (for hierarchical cancellation)
    parent: ?*const Self = null,

    /// Optional deadline (nanoseconds since epoch, 0 = no deadline)
    deadline_ns: u64 = 0,

    /// User data pointer for context values
    user_data: ?*anyopaque = null,

    /// Create a new context.
    pub fn init() Self {
        return .{
            .cancelled = atomic.Atomic(CancelReason).init(.none),
        };
    }

    /// Create a context with a parent.
    /// Cancelling the parent will cancel this context.
    pub fn withParent(parent: *const Self) Self {
        return .{
            .cancelled = atomic.Atomic(CancelReason).init(.none),
            .parent = parent,
        };
    }

    /// Create a context with a deadline.
    /// The context is automatically considered cancelled after the deadline.
    pub fn withDeadline(deadline_ns: u64) Self {
        return .{
            .cancelled = atomic.Atomic(CancelReason).init(.none),
            .deadline_ns = deadline_ns,
        };
    }

    /// Create a context with a timeout from now.
    pub fn withTimeout(timeout_ns: u64) Self {
        const now = @as(u64, @intCast(std.time.nanoTimestamp()));
        return withDeadline(now + timeout_ns);
    }

    /// Create a child context with deadline.
    pub fn withParentAndDeadline(parent: *const Self, deadline_ns: u64) Self {
        // Use earlier deadline
        const effective_deadline = if (parent.deadline_ns > 0)
            @min(parent.deadline_ns, deadline_ns)
        else
            deadline_ns;

        return .{
            .cancelled = atomic.Atomic(CancelReason).init(.none),
            .parent = parent,
            .deadline_ns = effective_deadline,
        };
    }

    /// Check if this context is cancelled.
    /// Also checks parent contexts and deadlines.
    pub fn isCancelled(self: *const Self) bool {
        return self.reason() != .none;
    }

    /// Get the cancellation reason.
    pub fn reason(self: *const Self) CancelReason {
        // Check direct cancellation
        const direct = self.cancelled.load();
        if (direct != .none) {
            return direct;
        }

        // Check deadline
        if (self.deadline_ns > 0) {
            const now = @as(u64, @intCast(std.time.nanoTimestamp()));
            if (now >= self.deadline_ns) {
                return .timeout;
            }
        }

        // Check parent
        if (self.parent) |parent| {
            if (parent.isCancelled()) {
                return .parent_cancelled;
            }
        }

        return .none;
    }

    /// Cancel this context.
    pub fn cancel(self: *Self) void {
        self.cancelWithReason(.cancelled);
    }

    /// Cancel with a specific reason.
    pub fn cancelWithReason(self: *Self, r: CancelReason) void {
        _ = self.cancelled.compareAndSwap(.none, r);
    }

    /// Get remaining time until deadline (0 if no deadline or expired).
    pub fn remainingNs(self: *const Self) u64 {
        if (self.deadline_ns == 0) return 0;

        const now = @as(u64, @intCast(std.time.nanoTimestamp()));
        if (now >= self.deadline_ns) return 0;

        return self.deadline_ns - now;
    }

    /// Set user data for context values.
    pub fn setUserData(self: *Self, data: ?*anyopaque) void {
        self.user_data = data;
    }

    /// Get user data.
    pub fn getUserData(self: *const Self) ?*anyopaque {
        // Check this context first, then parent
        if (self.user_data) |data| return data;
        if (self.parent) |parent| return parent.getUserData();
        return null;
    }

    /// Get typed user data.
    pub fn getUserDataAs(self: *const Self, comptime T: type) ?*T {
        if (self.getUserData()) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return null;
    }

    /// Check if context is still valid (not cancelled, deadline not passed).
    pub fn isValid(self: *const Self) bool {
        return !self.isCancelled();
    }

    /// Wait until cancelled or deadline reached.
    /// Returns immediately if already cancelled.
    pub fn done(self: *const Self) CancelReason {
        // Spin with backoff until cancelled
        var backoff = atomic.Backoff{};

        while (true) {
            const r = self.reason();
            if (r != .none) return r;

            backoff.snooze();
        }
    }
};

/// A cancellation token that can be used to cancel multiple contexts.
/// Useful for structured concurrency where a scope should cancel all children.
pub const CancelToken = struct {
    const Self = @This();

    cancelled: atomic.Atomic(bool),

    pub fn init() Self {
        return .{
            .cancelled = atomic.Atomic(bool).init(false),
        };
    }

    pub fn cancel(self: *Self) void {
        self.cancelled.store(true);
    }

    pub fn isCancelled(self: *const Self) bool {
        return self.cancelled.load();
    }
};

/// Context builder for fluent API.
pub const ContextBuilder = struct {
    const Self = @This();

    ctx: Context,

    pub fn new() Self {
        return .{ .ctx = Context.init() };
    }

    pub fn withParent(self: *Self, parent: *const Context) *Self {
        self.ctx.parent = parent;
        if (parent.deadline_ns > 0) {
            if (self.ctx.deadline_ns == 0 or parent.deadline_ns < self.ctx.deadline_ns) {
                self.ctx.deadline_ns = parent.deadline_ns;
            }
        }
        return self;
    }

    pub fn withDeadline(self: *Self, deadline_ns: u64) *Self {
        if (self.ctx.deadline_ns == 0 or deadline_ns < self.ctx.deadline_ns) {
            self.ctx.deadline_ns = deadline_ns;
        }
        return self;
    }

    pub fn withTimeout(self: *Self, timeout_ns: u64) *Self {
        const now = @as(u64, @intCast(std.time.nanoTimestamp()));
        return self.withDeadline(now + timeout_ns);
    }

    pub fn withUserData(self: *Self, data: ?*anyopaque) *Self {
        self.ctx.user_data = data;
        return self;
    }

    pub fn build(self: *Self) Context {
        return self.ctx;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Context basic cancellation" {
    var ctx = Context.init();

    try std.testing.expect(!ctx.isCancelled());
    try std.testing.expectEqual(CancelReason.none, ctx.reason());

    ctx.cancel();

    try std.testing.expect(ctx.isCancelled());
    try std.testing.expectEqual(CancelReason.cancelled, ctx.reason());
}

test "Context hierarchical cancellation" {
    var parent = Context.init();
    var child = Context.withParent(&parent);

    try std.testing.expect(!child.isCancelled());

    parent.cancel();

    try std.testing.expect(child.isCancelled());
    try std.testing.expectEqual(CancelReason.parent_cancelled, child.reason());
}

test "Context with deadline" {
    const now = @as(u64, @intCast(std.time.nanoTimestamp()));
    var ctx = Context.withDeadline(now - 1); // Already expired

    try std.testing.expect(ctx.isCancelled());
    try std.testing.expectEqual(CancelReason.timeout, ctx.reason());
}

test "Context remaining time" {
    const now = @as(u64, @intCast(std.time.nanoTimestamp()));
    const timeout = std.time.ns_per_s; // 1 second
    var ctx = Context.withDeadline(now + timeout);

    const remaining = ctx.remainingNs();
    try std.testing.expect(remaining > 0);
    try std.testing.expect(remaining <= timeout);
}

test "Context user data" {
    var data: u32 = 42;

    var ctx = Context.init();
    ctx.setUserData(&data);

    const retrieved = ctx.getUserDataAs(u32);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u32, 42), retrieved.?.*);
}

test "Context user data inheritance" {
    var data: u32 = 100;

    var parent = Context.init();
    parent.setUserData(&data);

    var child = Context.withParent(&parent);

    // Child inherits parent's user data
    const retrieved = child.getUserDataAs(u32);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u32, 100), retrieved.?.*);
}

test "CancelToken" {
    var token = CancelToken.init();

    try std.testing.expect(!token.isCancelled());

    token.cancel();

    try std.testing.expect(token.isCancelled());
}

test "ContextBuilder" {
    var parent = Context.init();
    var data: u32 = 55;

    var builder = ContextBuilder.new();
    const ctx = builder
        .withParent(&parent)
        .withUserData(&data)
        .build();

    try std.testing.expectEqual(&parent, ctx.parent.?);
    try std.testing.expectEqual(@as(u32, 55), ctx.getUserDataAs(u32).?.*);
}

test "Context cancel reason precedence" {
    var ctx = Context.init();

    // First cancellation wins
    ctx.cancelWithReason(.timeout);
    ctx.cancelWithReason(.cancelled);

    try std.testing.expectEqual(CancelReason.timeout, ctx.reason());
}

test "Context deadline inheritance" {
    const now = @as(u64, @intCast(std.time.nanoTimestamp()));
    const parent_deadline = now + std.time.ns_per_s * 10;
    const child_deadline = now + std.time.ns_per_s * 5;

    var parent = Context.withDeadline(parent_deadline);
    const child = Context.withParentAndDeadline(&parent, child_deadline);

    // Child should use earlier deadline (its own)
    try std.testing.expectEqual(child_deadline, child.deadline_ns);

    // If child deadline is later, use parent's
    const child2 = Context.withParentAndDeadline(&parent, now + std.time.ns_per_s * 20);
    try std.testing.expectEqual(parent_deadline, child2.deadline_ns);
}
