//! Scheduler interface and common types.
//!
//! This module defines the core scheduler abstraction that all scheduler
//! implementations must follow. Schedulers are responsible for executing
//! tasks across one or more threads.
//!
//! ## Scheduler Types
//!
//! - `ThreadPool`: Fixed thread pool with work queue
//! - `WorkStealingScheduler`: Work-stealing for load balancing
//! - `CurrentThread`: Single-threaded for async I/O
//!
//! ## Example
//!
//! ```zig
//! var scheduler = try ThreadPool.init(allocator, .{});
//! defer scheduler.deinit();
//!
//! try scheduler.spawn(myTask);
//! scheduler.shutdown();
//! ```

const std = @import("std");
const Task = @import("../task/task.zig").Task;
const Allocator = std.mem.Allocator;

/// Scheduler configuration options.
pub const Config = struct {
    /// Number of worker threads. 0 means use CPU count.
    thread_count: usize = 0,

    /// Stack size for worker threads (0 = default).
    stack_size: usize = 0,

    /// Whether to start workers immediately.
    start_paused: bool = false,

    /// Name prefix for worker threads (for debugging).
    thread_name_prefix: ?[]const u8 = null,

    /// Get the actual thread count to use.
    pub fn getThreadCount(self: Config) usize {
        if (self.thread_count == 0) {
            return std.Thread.getCpuCount() catch 1;
        }
        return self.thread_count;
    }
};

/// Scheduler state.
pub const State = enum(u8) {
    /// Scheduler is initializing.
    initializing = 0,
    /// Scheduler is running and accepting tasks.
    running = 1,
    /// Scheduler is shutting down, not accepting new tasks.
    shutting_down = 2,
    /// Scheduler has stopped.
    stopped = 3,
};

/// Result of a spawn operation.
pub const SpawnError = error{
    /// Scheduler is shutting down.
    ShuttingDown,
    /// Task queue is full.
    QueueFull,
    /// Out of memory.
    OutOfMemory,
};

/// Abstract scheduler interface.
/// All scheduler implementations provide these operations.
pub const Scheduler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Spawn a task for execution.
        spawn: *const fn (ptr: *anyopaque, task: *Task) SpawnError!void,

        /// Spawn a batch of tasks.
        spawnBatch: *const fn (ptr: *anyopaque, first: *Task, last: *Task, count: usize) SpawnError!void,

        /// Request graceful shutdown.
        shutdown: *const fn (ptr: *anyopaque) void,

        /// Force immediate shutdown.
        shutdownNow: *const fn (ptr: *anyopaque) void,

        /// Wait for all tasks to complete.
        wait: *const fn (ptr: *anyopaque) void,

        /// Get current state.
        getState: *const fn (ptr: *anyopaque) State,

        /// Get number of worker threads.
        getWorkerCount: *const fn (ptr: *anyopaque) usize,

        /// Get approximate number of pending tasks.
        getPendingCount: *const fn (ptr: *anyopaque) usize,
    };

    /// Spawn a task for execution.
    pub fn spawn(self: Scheduler, task: *Task) SpawnError!void {
        return self.vtable.spawn(self.ptr, task);
    }

    /// Spawn a batch of tasks.
    pub fn spawnBatch(self: Scheduler, first: *Task, last: *Task, count: usize) SpawnError!void {
        return self.vtable.spawnBatch(self.ptr, first, last, count);
    }

    /// Request graceful shutdown (finish pending tasks).
    pub fn shutdown(self: Scheduler) void {
        self.vtable.shutdown(self.ptr);
    }

    /// Force immediate shutdown (cancel pending tasks).
    pub fn shutdownNow(self: Scheduler) void {
        self.vtable.shutdownNow(self.ptr);
    }

    /// Wait for all tasks to complete.
    pub fn wait(self: Scheduler) void {
        self.vtable.wait(self.ptr);
    }

    /// Get current scheduler state.
    pub fn getState(self: Scheduler) State {
        return self.vtable.getState(self.ptr);
    }

    /// Get number of worker threads.
    pub fn getWorkerCount(self: Scheduler) usize {
        return self.vtable.getWorkerCount(self.ptr);
    }

    /// Get approximate number of pending tasks.
    pub fn getPendingCount(self: Scheduler) usize {
        return self.vtable.getPendingCount(self.ptr);
    }
};

/// Worker thread context passed to task execution.
pub const WorkerContext = struct {
    /// Worker ID (0-based index).
    worker_id: usize,

    /// Total number of workers.
    worker_count: usize,

    /// The scheduler this worker belongs to.
    scheduler: Scheduler,

    /// Allocator for task-local allocations.
    allocator: Allocator,
};

/// Helper to create a Scheduler interface from a concrete implementation.
pub fn SchedulerImpl(comptime T: type) type {
    return struct {
        pub fn scheduler(self: *T) Scheduler {
            return .{
                .ptr = self,
                .vtable = &.{
                    .spawn = spawnImpl,
                    .spawnBatch = spawnBatchImpl,
                    .shutdown = shutdownImpl,
                    .shutdownNow = shutdownNowImpl,
                    .wait = waitImpl,
                    .getState = getStateImpl,
                    .getWorkerCount = getWorkerCountImpl,
                    .getPendingCount = getPendingCountImpl,
                },
            };
        }

        fn spawnImpl(ptr: *anyopaque, task: *Task) SpawnError!void {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.spawn(task);
        }

        fn spawnBatchImpl(ptr: *anyopaque, first: *Task, last: *Task, count: usize) SpawnError!void {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.spawnBatch(first, last, count);
        }

        fn shutdownImpl(ptr: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.shutdown();
        }

        fn shutdownNowImpl(ptr: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.shutdownNow();
        }

        fn waitImpl(ptr: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.wait();
        }

        fn getStateImpl(ptr: *anyopaque) State {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.getState();
        }

        fn getWorkerCountImpl(ptr: *anyopaque) usize {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.getWorkerCount();
        }

        fn getPendingCountImpl(ptr: *anyopaque) usize {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.getPendingCount();
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Config defaults" {
    const config = Config{};
    try std.testing.expect(config.thread_count == 0);
    try std.testing.expect(config.getThreadCount() >= 1);
}

test "Config explicit thread count" {
    const config = Config{ .thread_count = 4 };
    try std.testing.expectEqual(@as(usize, 4), config.getThreadCount());
}
