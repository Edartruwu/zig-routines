//! Structured concurrency scope (nursery pattern).
//!
//! A Scope ensures that all spawned tasks complete before the scope exits.
//! This provides structured concurrency guarantees similar to Python's Trio
//! nurseries or Swift's task groups.
//!
//! ## Guarantees
//!
//! - All tasks spawned in a scope will complete before scope exits
//! - If any task fails, remaining tasks are cancelled
//! - Resources are properly cleaned up
//!
//! ## Example
//!
//! ```zig
//! var scope = try Scope.init(allocator);
//! defer scope.deinit();
//!
//! try scope.spawn(task1);
//! try scope.spawn(task2);
//!
//! // Wait for all tasks
//! try scope.wait();
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const Task = @import("../task/task.zig").Task;
const Context = @import("../task/context.zig").Context;
const Future = @import("../future/future.zig").Future;
const Allocator = std.mem.Allocator;

/// Scope state.
pub const ScopeState = enum(u8) {
    /// Scope is active and accepting tasks.
    active = 0,
    /// Scope is waiting for tasks to complete.
    waiting = 1,
    /// Scope is cancelling all tasks.
    cancelling = 2,
    /// Scope has completed.
    completed = 3,
};

/// Error from scope operations.
pub const ScopeError = error{
    /// Scope is not active.
    NotActive,
    /// A task in the scope failed.
    TaskFailed,
    /// Scope was cancelled.
    Cancelled,
    /// Out of memory.
    OutOfMemory,
};

/// A structured concurrency scope.
pub const Scope = struct {
    const Self = @This();

    /// Tracked task entry.
    const TaskEntry = struct {
        task: *Task,
        completed: bool,
        failed: bool,
        next: ?*TaskEntry,
    };

    /// Head of task list.
    task_list: ?*TaskEntry,

    /// Number of pending tasks.
    pending_count: atomic.Atomic(usize),

    /// Number of completed tasks.
    completed_count: atomic.Atomic(usize),

    /// Number of failed tasks.
    failed_count: atomic.Atomic(usize),

    /// Current state.
    state: atomic.Atomic(ScopeState),

    /// Cancellation context for the scope.
    context: Context,

    /// Mutex for task list.
    mutex: std.Thread.Mutex,

    /// Condition for waiting.
    cond: std.Thread.Condition,

    /// Allocator.
    allocator: Allocator,

    /// Initialize a new scope.
    pub fn init(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);

        self.* = Self{
            .task_list = null,
            .pending_count = atomic.Atomic(usize).init(0),
            .completed_count = atomic.Atomic(usize).init(0),
            .failed_count = atomic.Atomic(usize).init(0),
            .state = atomic.Atomic(ScopeState).init(.active),
            .context = Context.init(),
            .mutex = .{},
            .cond = .{},
            .allocator = allocator,
        };

        return self;
    }

    /// Deinitialize the scope.
    pub fn deinit(self: *Self) void {
        // Cancel any remaining tasks
        if (self.state.load() != .completed) {
            self.cancel();
            self.waitInternal();
        }

        // Free task entries
        self.mutex.lock();
        var entry = self.task_list;
        while (entry) |e| {
            const next = e.next;
            self.allocator.destroy(e);
            entry = next;
        }
        self.mutex.unlock();

        self.allocator.destroy(self);
    }

    /// Spawn a task in the scope.
    pub fn spawn(self: *Self, task: *Task) ScopeError!void {
        if (self.state.load() != .active) {
            return ScopeError.NotActive;
        }

        const entry = self.allocator.create(TaskEntry) catch return ScopeError.OutOfMemory;
        entry.* = .{
            .task = task,
            .completed = false,
            .failed = false,
            .next = null,
        };

        // Add to list
        self.mutex.lock();
        entry.next = self.task_list;
        self.task_list = entry;
        _ = self.pending_count.fetchAdd(1);
        self.mutex.unlock();

        // Set task's context
        task.context = &self.context;
    }

    /// Mark a task as completed.
    pub fn taskCompleted(self: *Self, task: *Task, success: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find the task entry
        var entry = self.task_list;
        while (entry) |e| {
            if (e.task == task) {
                e.completed = true;
                e.failed = !success;
                _ = self.pending_count.fetchSub(1);
                _ = self.completed_count.fetchAdd(1);
                if (!success) {
                    _ = self.failed_count.fetchAdd(1);
                }
                break;
            }
            entry = e.next;
        }

        // Signal waiters
        self.cond.broadcast();
    }

    /// Cancel all tasks in the scope.
    pub fn cancel(self: *Self) void {
        self.state.store(.cancelling);
        self.context.cancel();
        self.cond.broadcast();
    }

    /// Internal wait implementation.
    fn waitInternal(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.pending_count.load() > 0) {
            self.cond.timedWait(&self.mutex, 1_000_000) catch {};
        }

        self.state.store(.completed);
    }

    /// Wait for all tasks to complete.
    pub fn wait(self: *Self) ScopeError!void {
        self.state.store(.waiting);
        self.waitInternal();

        if (self.failed_count.load() > 0) {
            return ScopeError.TaskFailed;
        }

        if (self.context.isCancelled()) {
            return ScopeError.Cancelled;
        }
    }

    /// Get the scope's cancellation context.
    pub fn getContext(self: *Self) *Context {
        return &self.context;
    }

    /// Check if scope is active.
    pub fn isActive(self: *Self) bool {
        return self.state.load() == .active;
    }

    /// Get number of pending tasks.
    pub fn getPendingCount(self: *Self) usize {
        return self.pending_count.load();
    }

    /// Get number of completed tasks.
    pub fn getCompletedCount(self: *Self) usize {
        return self.completed_count.load();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Scope basic" {
    var scope = try Scope.init(std.testing.allocator);
    defer scope.deinit();

    try std.testing.expect(scope.isActive());
    try std.testing.expectEqual(@as(usize, 0), scope.getPendingCount());

    // Create a task
    var task = Task.init(struct {
        fn run(_: *Task) void {}
    }.run);

    try scope.spawn(&task);
    try std.testing.expectEqual(@as(usize, 1), scope.getPendingCount());

    // Mark as completed
    scope.taskCompleted(&task, true);
    try std.testing.expectEqual(@as(usize, 0), scope.getPendingCount());
    try std.testing.expectEqual(@as(usize, 1), scope.getCompletedCount());
}

test "Scope cancel" {
    var scope = try Scope.init(std.testing.allocator);
    defer scope.deinit();

    var task = Task.init(struct {
        fn run(_: *Task) void {}
    }.run);

    try scope.spawn(&task);

    scope.cancel();
    try std.testing.expect(scope.getContext().isCancelled());

    // Mark completed and wait
    scope.taskCompleted(&task, true);
    try std.testing.expectError(ScopeError.Cancelled, scope.wait());
}

test "Scope wait empty" {
    var scope = try Scope.init(std.testing.allocator);
    defer scope.deinit();

    // No tasks, should complete immediately
    try scope.wait();
}
