//! Work-stealing scheduler implementation.
//!
//! A high-performance scheduler that uses per-worker deques with work stealing
//! for load balancing. Each worker has its own local queue and can steal from
//! other workers when idle.
//!
//! ## Algorithm
//!
//! Based on the Chase-Lev work-stealing deque:
//! - Each worker has a local deque (double-ended queue)
//! - Workers push/pop from their own deque (LIFO for locality)
//! - Idle workers steal from other workers' deques (FIFO for fairness)
//!
//! ## Features
//!
//! - Excellent load balancing under uneven workloads
//! - Good cache locality for recursive task patterns
//! - Minimal contention between workers
//!
//! ## Example
//!
//! ```zig
//! var ws = try WorkStealingScheduler.init(allocator, .{});
//! defer ws.deinit();
//!
//! try ws.spawn(&task);
//! ws.shutdown();
//! ws.wait();
//! ```

const std = @import("std");
const Task = @import("../task/task.zig").Task;
const atomic = @import("../core/atomic.zig");
const scheduler = @import("scheduler.zig");
const WorkStealingDeque = @import("../lockfree/deque.zig").WorkStealingDeque;
const StealResult = @import("../lockfree/deque.zig").StealResult;
const MPMCQueue = @import("../lockfree/queue.zig").MPMCQueue;
const Allocator = std.mem.Allocator;

const Config = scheduler.Config;
const State = scheduler.State;
const SpawnError = scheduler.SpawnError;
const Scheduler = scheduler.Scheduler;

/// Work-stealing scheduler.
pub const WorkStealingScheduler = struct {
    const Self = @This();

    /// Per-worker data.
    const WorkerData = struct {
        /// Local work-stealing deque.
        deque: WorkStealingDeque(*Task),

        /// Worker thread handle.
        thread: std.Thread,

        /// Worker ID.
        id: usize,

        fn init(alloc: Allocator, id: usize) !WorkerData {
            return .{
                .deque = try WorkStealingDeque(*Task).init(alloc),
                .thread = undefined,
                .id = id,
            };
        }

        fn deinit(self: *WorkerData) void {
            self.deque.deinit();
        }
    };

    /// Configuration.
    config: Config,

    /// Per-worker data.
    workers: []WorkerData,

    /// Global injection queue for external submissions.
    global_queue: MPMCQueue(*Task),

    /// Current state.
    state: atomic.Atomic(State),

    /// Number of active workers.
    active_workers: atomic.Atomic(usize),

    /// Total pending task count (approximate).
    pending_count: atomic.Atomic(usize),

    /// Parked workers count.
    parked_workers: atomic.Atomic(usize),

    /// Condition for parking.
    park_cond: std.Thread.Condition,

    /// Mutex for parking.
    park_mutex: std.Thread.Mutex,

    /// Random state for stealing.
    rng: std.Random.DefaultPrng,

    /// Allocator.
    allocator: Allocator,

    /// Initialize a new work-stealing scheduler.
    pub fn init(alloc: Allocator, config: Config) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        const thread_count = config.getThreadCount();

        // Initialize worker data
        const workers = try alloc.alloc(WorkerData, thread_count);
        errdefer alloc.free(workers);

        for (workers, 0..) |*w, i| {
            w.* = try WorkerData.init(alloc, i);
        }

        self.* = Self{
            .config = config,
            .workers = workers,
            .global_queue = try MPMCQueue(*Task).init(alloc, 4096),
            .state = atomic.Atomic(State).init(if (config.start_paused) .initializing else .running),
            .active_workers = atomic.Atomic(usize).init(0),
            .pending_count = atomic.Atomic(usize).init(0),
            .parked_workers = atomic.Atomic(usize).init(0),
            .park_cond = .{},
            .park_mutex = .{},
            .rng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp())),
            .allocator = alloc,
        };

        // Start worker threads
        if (!config.start_paused) {
            try self.startWorkers();
        }

        return self;
    }

    /// Deinitialize the scheduler.
    pub fn deinit(self: *Self) void {
        // Ensure shutdown and wait for workers
        const state = self.state.load();
        if (state == .running or state == .shutting_down) {
            if (state == .running) {
                self.shutdown();
            }
            self.waitInternal();
        }

        for (self.workers) |*w| {
            w.deinit();
        }
        self.allocator.free(self.workers);
        self.global_queue.deinit();
        self.allocator.destroy(self);
    }

    /// Start worker threads.
    fn startWorkers(self: *Self) !void {
        for (self.workers) |*worker| {
            const spawn_config = std.Thread.SpawnConfig{
                .stack_size = if (self.config.stack_size > 0) self.config.stack_size else std.Thread.SpawnConfig.default_stack_size,
            };
            worker.thread = try std.Thread.spawn(spawn_config, workerLoop, .{ self, worker.id });
        }
    }

    /// Worker thread main loop.
    fn workerLoop(self: *Self, worker_id: usize) void {
        _ = self.active_workers.fetchAdd(1);
        defer _ = self.active_workers.fetchSub(1);

        var spin_count: usize = 0;
        const max_spins: usize = 32;

        while (true) {
            // Check for shutdown
            const state = self.state.load();
            if (state == .stopped) break;
            if (state == .shutting_down and self.pending_count.load() == 0) break;

            // Try to get work
            if (self.findWork(worker_id)) |task| {
                _ = self.pending_count.fetchSub(1);
                task.run();
                spin_count = 0;
            } else {
                // No work found
                spin_count += 1;

                if (spin_count < max_spins) {
                    // Spin a bit
                    std.atomic.spinLoopHint();
                } else {
                    // Park the worker
                    self.parkWorker();
                    spin_count = 0;
                }
            }
        }
    }

    /// Find work for a worker.
    fn findWork(self: *Self, worker_id: usize) ?*Task {
        const worker = &self.workers[worker_id];

        // 1. Try local deque first (LIFO)
        if (worker.deque.pop()) |task| {
            return task;
        }

        // 2. Try global queue
        if (self.global_queue.pop()) |task| {
            return task;
        }

        // 3. Try stealing from other workers
        return self.stealFromOthers(worker_id);
    }

    /// Steal work from other workers.
    fn stealFromOthers(self: *Self, worker_id: usize) ?*Task {
        const worker_count = self.workers.len;
        if (worker_count <= 1) return null;

        // Random starting point for fairness
        const start = self.rng.random().int(usize) % worker_count;

        var i: usize = 0;
        while (i < worker_count) : (i += 1) {
            const victim_id = (start + i) % worker_count;
            if (victim_id == worker_id) continue;

            const victim = &self.workers[victim_id];
            switch (victim.deque.steal()) {
                .success => |task| return task,
                .empty => continue,
                .abort => {
                    // Retry this victim
                    if (i > 0) i -= 1;
                    continue;
                },
            }
        }

        return null;
    }

    /// Park a worker (wait for work).
    fn parkWorker(self: *Self) void {
        _ = self.parked_workers.fetchAdd(1);
        defer _ = self.parked_workers.fetchSub(1);

        self.park_mutex.lock();
        defer self.park_mutex.unlock();

        // Double-check state
        const state = self.state.load();
        if (state == .stopped) return;
        if (state == .shutting_down and self.pending_count.load() == 0) return;

        // Check if there's work before parking
        if (self.pending_count.load() > 0) return;

        // Wait with timeout
        self.park_cond.timedWait(&self.park_mutex, 1_000_000) catch {};
    }

    /// Unpark workers.
    fn unparkWorkers(self: *Self, count: usize) void {
        if (count == 0) return;

        if (count == 1) {
            self.park_cond.signal();
        } else {
            self.park_cond.broadcast();
        }
    }

    /// Spawn a task to the global queue.
    pub fn spawn(self: *Self, task: *Task) SpawnError!void {
        const state = self.state.load();
        if (state == .shutting_down or state == .stopped) {
            return SpawnError.ShuttingDown;
        }

        if (!self.global_queue.push(task)) {
            return SpawnError.QueueFull;
        }

        _ = self.pending_count.fetchAdd(1);

        // Unpark a worker if any are parked
        if (self.parked_workers.load() > 0) {
            self.unparkWorkers(1);
        }
    }

    /// Spawn a batch of tasks.
    pub fn spawnBatch(self: *Self, first: *Task, last: *Task, count: usize) SpawnError!void {
        _ = last;
        const state = self.state.load();
        if (state == .shutting_down or state == .stopped) {
            return SpawnError.ShuttingDown;
        }

        // Push each task
        var task: ?*Task = first;
        var pushed: usize = 0;
        while (task) |t| {
            if (!self.global_queue.push(t)) {
                _ = self.pending_count.fetchSub(pushed);
                return SpawnError.QueueFull;
            }
            pushed += 1;
            task = t.next;
        }

        _ = self.pending_count.fetchAdd(count);

        // Unpark workers
        const parked = self.parked_workers.load();
        if (parked > 0) {
            self.unparkWorkers(@min(count, parked));
        }
    }

    /// Spawn to a specific worker's local queue.
    /// Useful for worker-local task spawning.
    pub fn spawnLocal(self: *Self, worker_id: usize, task: *Task) SpawnError!void {
        const state = self.state.load();
        if (state == .shutting_down or state == .stopped) {
            return SpawnError.ShuttingDown;
        }

        if (worker_id >= self.workers.len) {
            return self.spawn(task);
        }

        try self.workers[worker_id].deque.push(task);
        _ = self.pending_count.fetchAdd(1);
    }

    /// Request graceful shutdown.
    pub fn shutdown(self: *Self) void {
        self.state.store(.shutting_down);
        self.park_cond.broadcast();
    }

    /// Force immediate shutdown.
    pub fn shutdownNow(self: *Self) void {
        self.state.store(.stopped);
        self.park_cond.broadcast();
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

test "WorkStealingScheduler basic" {
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

        fn run(t: *Task) void {
            const self: *@This() = @fieldParentPtr("task", t);
            _ = self.counter.fetchAdd(1);
        }
    };

    var ws = try WorkStealingScheduler.init(std.testing.allocator, .{ .thread_count = 2 });
    defer ws.deinit();

    // Create and spawn tasks
    var tasks: [10]TestTask = undefined;
    for (&tasks) |*t| {
        t.* = TestTask.init(&completed);
        try ws.spawn(&t.task);
    }

    // Shutdown and wait
    ws.shutdown();
    ws.wait();

    try std.testing.expectEqual(@as(usize, 10), completed.load());
}

test "WorkStealingScheduler state transitions" {
    var ws = try WorkStealingScheduler.init(std.testing.allocator, .{ .thread_count = 2 });

    try std.testing.expectEqual(State.running, ws.getState());
    try std.testing.expectEqual(@as(usize, 2), ws.getWorkerCount());

    ws.shutdown();
    try std.testing.expectEqual(State.shutting_down, ws.getState());

    ws.wait();
    try std.testing.expectEqual(State.stopped, ws.getState());

    ws.deinit();
}
