//! Thread pool scheduler implementation.
//!
//! A simple but efficient thread pool that maintains a fixed number of worker
//! threads. Tasks are submitted to a shared queue and executed by available
//! workers.
//!
//! ## Features
//!
//! - Fixed number of worker threads
//! - FIFO task execution order
//! - Graceful and immediate shutdown modes
//! - Configurable queue capacity
//!
//! ## Example
//!
//! ```zig
//! var pool = try ThreadPool.init(allocator, .{ .thread_count = 4 });
//! defer pool.deinit();
//!
//! // Spawn tasks
//! try pool.spawn(&task);
//!
//! // Wait for completion and shutdown
//! pool.shutdown();
//! pool.wait();
//! ```

const std = @import("std");
const Task = @import("../task/task.zig").Task;
const atomic = @import("../core/atomic.zig");
const scheduler = @import("scheduler.zig");
const MPMCQueue = @import("../lockfree/queue.zig").MPMCQueue;
const Allocator = std.mem.Allocator;

const Config = scheduler.Config;
const State = scheduler.State;
const SpawnError = scheduler.SpawnError;
const Scheduler = scheduler.Scheduler;

/// Thread pool scheduler.
pub const ThreadPool = struct {
    const Self = @This();

    /// Worker thread handle.
    const Worker = struct {
        thread: std.Thread,
        id: usize,
    };

    /// Configuration.
    config: Config,

    /// Worker threads.
    workers: []Worker,

    /// Task queue.
    queue: MPMCQueue(*Task),

    /// Current state.
    state: atomic.Atomic(State),

    /// Number of active workers.
    active_workers: atomic.Atomic(usize),

    /// Pending task count.
    pending_count: atomic.Atomic(usize),

    /// Condition for workers to wait on.
    worker_cond: std.Thread.Condition,

    /// Mutex for condition.
    mutex: std.Thread.Mutex,

    /// Allocator.
    allocator: Allocator,

    /// Initialize a new thread pool.
    pub fn init(alloc: Allocator, config: Config) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        const thread_count = config.getThreadCount();

        self.* = Self{
            .config = config,
            .workers = try alloc.alloc(Worker, thread_count),
            .queue = try MPMCQueue(*Task).init(alloc, 4096),
            .state = atomic.Atomic(State).init(if (config.start_paused) .initializing else .running),
            .active_workers = atomic.Atomic(usize).init(0),
            .pending_count = atomic.Atomic(usize).init(0),
            .worker_cond = .{},
            .mutex = .{},
            .allocator = alloc,
        };

        // Start worker threads
        if (!config.start_paused) {
            try self.startWorkers();
        }

        return self;
    }

    /// Deinitialize the thread pool.
    pub fn deinit(self: *Self) void {
        // Ensure shutdown and wait for workers
        const state = self.state.load();
        if (state == .running or state == .shutting_down) {
            if (state == .running) {
                self.shutdown();
            }
            self.waitInternal();
        }

        self.allocator.free(self.workers);
        self.queue.deinit();
        self.allocator.destroy(self);
    }

    /// Start worker threads.
    fn startWorkers(self: *Self) !void {
        for (self.workers, 0..) |*worker, i| {
            worker.id = i;
            const spawn_config = std.Thread.SpawnConfig{
                .stack_size = if (self.config.stack_size > 0) self.config.stack_size else std.Thread.SpawnConfig.default_stack_size,
            };
            worker.thread = try std.Thread.spawn(spawn_config, workerLoop, .{ self, i });
        }
    }

    /// Worker thread main loop.
    fn workerLoop(self: *Self, worker_id: usize) void {
        _ = worker_id;
        _ = self.active_workers.fetchAdd(1);
        defer _ = self.active_workers.fetchSub(1);

        while (true) {
            // Check for shutdown
            const state = self.state.load();
            if (state == .stopped) break;
            if (state == .shutting_down and self.pending_count.load() == 0) break;

            // Try to get a task
            if (self.queue.pop()) |task| {
                _ = self.pending_count.fetchSub(1);
                task.run();
            } else {
                // No task available, wait
                self.mutex.lock();
                defer self.mutex.unlock();

                // Double-check state under lock
                const s = self.state.load();
                if (s == .stopped) break;
                if (s == .shutting_down and self.pending_count.load() == 0) break;

                // Wait for signal
                self.worker_cond.timedWait(&self.mutex, 1_000_000) catch {};
            }
        }
    }

    /// Spawn a task.
    pub fn spawn(self: *Self, task: *Task) SpawnError!void {
        const state = self.state.load();
        if (state == .shutting_down or state == .stopped) {
            return SpawnError.ShuttingDown;
        }

        if (!self.queue.push(task)) {
            return SpawnError.QueueFull;
        }

        _ = self.pending_count.fetchAdd(1);

        // Signal a worker
        self.worker_cond.signal();
    }

    /// Spawn a batch of tasks.
    pub fn spawnBatch(self: *Self, first: *Task, last: *Task, count: usize) SpawnError!void {
        _ = last;
        const state = self.state.load();
        if (state == .shutting_down or state == .stopped) {
            return SpawnError.ShuttingDown;
        }

        // Push each task in the batch
        var task: ?*Task = first;
        var pushed: usize = 0;
        while (task) |t| {
            if (!self.queue.push(t)) {
                // Rollback pending count on failure
                _ = self.pending_count.fetchSub(pushed);
                return SpawnError.QueueFull;
            }
            pushed += 1;
            task = t.next;
        }

        _ = self.pending_count.fetchAdd(count);

        // Wake all workers for batch
        self.worker_cond.broadcast();
    }

    /// Request graceful shutdown.
    pub fn shutdown(self: *Self) void {
        self.state.store(.shutting_down);
        self.worker_cond.broadcast();
    }

    /// Force immediate shutdown.
    pub fn shutdownNow(self: *Self) void {
        self.state.store(.stopped);
        self.worker_cond.broadcast();
    }

    /// Internal wait implementation.
    fn waitInternal(self: *Self) void {
        for (self.workers) |*worker| {
            worker.thread.join();
        }
        self.state.store(.stopped);
    }

    /// Wait for all workers to finish.
    pub fn wait(self: *Self) void {
        const state = self.state.load();
        if (state == .stopped) return; // Already stopped
        self.waitInternal();
    }

    /// Get current state.
    pub fn getState(self: *Self) State {
        return self.state.load();
    }

    /// Get number of workers.
    pub fn getWorkerCount(self: *Self) usize {
        return self.workers.len;
    }

    /// Get pending task count.
    pub fn getPendingCount(self: *Self) usize {
        return self.pending_count.load();
    }

    /// Get scheduler interface.
    pub fn asScheduler(self: *Self) Scheduler {
        return scheduler.SchedulerImpl(Self).scheduler(self);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ThreadPool basic" {
    var completed = atomic.Atomic(usize).init(0);

    const TestTask = struct {
        task: Task,
        counter: *atomic.Atomic(usize),

        fn init(counter: *atomic.Atomic(usize)) @This() {
            return .{
                .task = Task.init(run),
                .counter = counter,
            };
        }

        fn run(task: *Task) void {
            const self: *@This() = @fieldParentPtr("task", task);
            _ = self.counter.fetchAdd(1);
        }
    };

    var pool = try ThreadPool.init(std.testing.allocator, .{ .thread_count = 2 });
    defer pool.deinit();

    // Create and spawn tasks
    var tasks: [10]TestTask = undefined;
    for (&tasks) |*t| {
        t.* = TestTask.init(&completed);
        try pool.spawn(&t.task);
    }

    // Shutdown and wait
    pool.shutdown();
    pool.wait();

    try std.testing.expectEqual(@as(usize, 10), completed.load());
}

test "ThreadPool shutdown" {
    var pool = try ThreadPool.init(std.testing.allocator, .{ .thread_count = 2 });

    try std.testing.expectEqual(State.running, pool.getState());
    try std.testing.expectEqual(@as(usize, 2), pool.getWorkerCount());

    pool.shutdown();
    try std.testing.expectEqual(State.shutting_down, pool.getState());

    pool.wait();
    try std.testing.expectEqual(State.stopped, pool.getState());

    pool.deinit();
}
