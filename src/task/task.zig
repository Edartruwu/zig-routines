//! Core Task type - the fundamental unit of concurrent execution.
//!
//! A Task represents a lightweight unit of work, similar to a goroutine in Go.
//! Tasks can be scheduled on different executors (thread pools, work-stealing
//! schedulers, etc.) and support cancellation through Context.
//!
//! ## Design Philosophy
//!
//! Tasks are designed for zero-allocation queuing through intrusive nodes:
//!
//! ```zig
//! const MyWork = struct {
//!     data: []const u8,
//!     result: ?u64 = null,
//!     task: Task,
//!
//!     pub fn init(data: []const u8) MyWork {
//!         return .{
//!             .data = data,
//!             .task = Task.init(execute),
//!         };
//!     }
//!
//!     fn execute(task: *Task) void {
//!         const self: *MyWork = @fieldParentPtr("task", task);
//!         self.result = doWork(self.data);
//!     }
//! };
//! ```

const std = @import("std");
const intrusive = @import("../core/intrusive.zig");
const atomic = @import("../core/atomic.zig");
const Context = @import("context.zig").Context;

/// Task execution callback signature.
pub const Callback = *const fn (*Task) void;

/// Task priority levels for priority-aware schedulers.
pub const Priority = enum(u8) {
    /// Background work, lowest priority
    low = 0,
    /// Default priority for most tasks
    normal = 1,
    /// Important tasks that should run soon
    high = 2,
    /// Critical tasks, highest priority
    critical = 3,

    pub fn compare(a: Priority, b: Priority) std.math.Order {
        return std.math.order(@intFromEnum(a), @intFromEnum(b));
    }
};

/// Task state machine.
pub const State = enum(u8) {
    /// Task is ready to be scheduled
    ready,
    /// Task is currently executing
    running,
    /// Task completed successfully
    completed,
    /// Task was cancelled
    cancelled,
    /// Task execution failed
    failed,
};

/// A lightweight unit of concurrent execution.
///
/// Tasks are the fundamental building block for all concurrency patterns
/// in zig-routines. They can be scheduled on executors, cancelled through
/// contexts, and composed with other primitives.
pub const Task = struct {
    const Self = @This();

    /// Intrusive node for queue embedding (zero-allocation scheduling)
    node: intrusive.Node = .{},

    /// Function to execute when task runs
    callback: Callback,

    /// Optional cancellation context
    context: ?*Context = null,

    /// Task priority for scheduling
    priority: Priority = .normal,

    /// Current state (atomic for thread-safe access)
    state: atomic.Atomic(State),

    /// User-provided callback for completion notification
    on_complete: ?*const fn (*Self) void = null,

    /// Create a new task with the given callback.
    pub fn init(callback: Callback) Self {
        return .{
            .callback = callback,
            .state = atomic.Atomic(State).init(.ready),
        };
    }

    /// Create a task with cancellation context.
    pub fn initWithContext(callback: Callback, ctx: *Context) Self {
        return .{
            .callback = callback,
            .context = ctx,
            .state = atomic.Atomic(State).init(.ready),
        };
    }

    /// Create a task with priority.
    pub fn initWithPriority(callback: Callback, priority: Priority) Self {
        return .{
            .callback = callback,
            .priority = priority,
            .state = atomic.Atomic(State).init(.ready),
        };
    }

    /// Execute the task.
    ///
    /// This transitions the task from `ready` to `running`, executes the
    /// callback, then transitions to `completed` (or `cancelled`/`failed`).
    pub fn run(self: *Self) void {
        // Check for cancellation before starting
        if (self.isCancelled()) {
            self.state.store(.cancelled);
            if (self.on_complete) |handler| {
                handler(self);
            }
            return;
        }

        // Transition to running
        const old_state = self.state.compareAndSwapStrong(.ready, .running);
        if (old_state != null) {
            // Task not in ready state, don't run
            return;
        }

        // Execute the callback
        self.callback(self);

        // Transition to completed (unless already cancelled/failed)
        _ = self.state.compareAndSwap(.running, .completed);

        // Notify completion handler
        if (self.on_complete) |handler| {
            handler(self);
        }
    }

    /// Check if task has been cancelled.
    ///
    /// Tasks can be cancelled through their context. Check this periodically
    /// in long-running task callbacks to enable cooperative cancellation.
    pub fn isCancelled(self: *const Self) bool {
        if (self.context) |ctx| {
            return ctx.isCancelled();
        }
        return self.state.load() == .cancelled;
    }

    /// Mark the task as cancelled.
    pub fn cancel(self: *Self) void {
        // Try to transition from ready to cancelled
        _ = self.state.compareAndSwap(.ready, .cancelled);
    }

    /// Mark the task as failed.
    pub fn fail(self: *Self) void {
        _ = self.state.compareAndSwap(.running, .failed);
    }

    /// Get current task state.
    pub fn getState(self: *const Self) State {
        return self.state.load();
    }

    /// Check if task is in a terminal state.
    pub fn isDone(self: *const Self) bool {
        const state = self.state.load();
        return state == .completed or state == .cancelled or state == .failed;
    }

    /// Check if task completed successfully.
    pub fn isCompleted(self: *const Self) bool {
        return self.state.load() == .completed;
    }

    /// Reset task for reuse (use with caution).
    ///
    /// Only call this when you're certain the task is not queued anywhere.
    pub fn reset(self: *Self) void {
        std.debug.assert(self.isDone());
        std.debug.assert(!self.node.isLinked());

        self.state.store(.ready);
        self.node.reset();
    }

    /// Set completion callback.
    pub fn setOnComplete(self: *Self, handler: *const fn (*Self) void) void {
        self.on_complete = handler;
    }

    /// Yield execution hint for cooperative multitasking.
    /// Call this in compute-heavy loops to allow other tasks to run.
    pub fn yield() void {
        std.atomic.spinLoopHint();
    }

    /// Check if running on current thread should continue.
    /// Returns false if cancellation requested.
    pub fn shouldContinue(self: *const Self) bool {
        return !self.isCancelled();
    }
};

/// Batch of tasks for bulk scheduling.
pub const TaskBatch = struct {
    const Self = @This();

    list: intrusive.List = .{},

    pub fn init() Self {
        return .{};
    }

    /// Add a task to the batch.
    pub fn push(self: *Self, task: *Task) void {
        self.list.pushBack(&task.node);
    }

    /// Pop a task from the batch.
    pub fn pop(self: *Self) ?*Task {
        if (self.list.popFront()) |node| {
            return @fieldParentPtr("node", node);
        }
        return null;
    }

    /// Check if batch is empty.
    pub fn isEmpty(self: *const Self) bool {
        return self.list.isEmpty();
    }

    /// Get number of tasks in batch.
    pub fn length(self: *const Self) usize {
        return self.list.length();
    }

    /// Merge another batch into this one.
    pub fn merge(self: *Self, other: *Self) void {
        self.list.append(&other.list);
    }

    /// Iterator over tasks in the batch.
    pub fn iterator(self: *const Self) Iterator {
        return .{ .inner = self.list.iterator() };
    }

    pub const Iterator = struct {
        inner: intrusive.List.Iterator,

        pub fn next(self: *Iterator) ?*Task {
            if (self.inner.next()) |node| {
                return @fieldParentPtr("node", node);
            }
            return null;
        }
    };
};

/// Create a task from a function and its arguments.
/// This is a helper for the common pattern of wrapping closures.
pub fn TaskClosure(comptime Args: type, comptime ResultType: type) type {
    return struct {
        const Self = @This();

        args: Args,
        result: ?ResultType = null,
        task: Task,
        func: *const fn (Args) ResultType,

        pub fn init(func: *const fn (Args) ResultType, args: Args) Self {
            return .{
                .args = args,
                .func = func,
                .task = Task.init(execute),
            };
        }

        fn execute(task: *Task) void {
            const self: *Self = @fieldParentPtr("task", task);
            self.result = self.func(self.args);
        }

        pub fn getTask(self: *Self) *Task {
            return &self.task;
        }

        pub fn getResult(self: *const Self) ?ResultType {
            return self.result;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Task basic execution" {
    const TestTask = struct {
        value: u32 = 0,
        task: Task,

        fn init() @This() {
            return .{
                .task = Task.init(execute),
            };
        }

        fn execute(task: *Task) void {
            const self: *@This() = @fieldParentPtr("task", task);
            self.value = 42;
        }
    };

    var t = TestTask.init();
    try std.testing.expectEqual(State.ready, t.task.getState());

    t.task.run();

    try std.testing.expectEqual(@as(u32, 42), t.value);
    try std.testing.expectEqual(State.completed, t.task.getState());
    try std.testing.expect(t.task.isDone());
    try std.testing.expect(t.task.isCompleted());
}

test "Task cancellation" {
    const TestTask = struct {
        executed: bool = false,
        task: Task,

        fn init() @This() {
            return .{
                .task = Task.init(execute),
            };
        }

        fn execute(task: *Task) void {
            const self: *@This() = @fieldParentPtr("task", task);
            self.executed = true;
        }
    };

    var t = TestTask.init();

    // Cancel before running
    t.task.cancel();
    try std.testing.expectEqual(State.cancelled, t.task.getState());

    // Run should not execute callback
    t.task.run();
    try std.testing.expect(!t.executed);
}

test "Task completion callback" {
    const TestTask = struct {
        value: u32 = 0,
        completed: bool = false,
        task: Task,

        fn init() @This() {
            var self = @This(){
                .task = Task.init(execute),
            };
            self.task.setOnComplete(onComplete);
            return self;
        }

        fn execute(task: *Task) void {
            const self: *@This() = @fieldParentPtr("task", task);
            self.value = 100;
        }

        fn onComplete(task: *Task) void {
            const self: *@This() = @fieldParentPtr("task", task);
            self.completed = true;
        }
    };

    var t = TestTask.init();
    t.task.run();

    try std.testing.expectEqual(@as(u32, 100), t.value);
    try std.testing.expect(t.completed);
}

test "Task priority ordering" {
    try std.testing.expect(Priority.low.compare(.normal) == .lt);
    try std.testing.expect(Priority.normal.compare(.high) == .lt);
    try std.testing.expect(Priority.high.compare(.critical) == .lt);
    try std.testing.expect(Priority.critical.compare(.critical) == .eq);
}

test "TaskBatch operations" {
    const TestTask = struct {
        id: u32,
        task: Task,

        fn init(id: u32) @This() {
            return .{
                .id = id,
                .task = Task.init(struct {
                    fn run(_: *Task) void {}
                }.run),
            };
        }
    };

    var tasks: [5]TestTask = undefined;
    for (&tasks, 0..) |*t, i| {
        t.* = TestTask.init(@intCast(i));
    }

    var batch = TaskBatch.init();
    try std.testing.expect(batch.isEmpty());

    for (&tasks) |*t| {
        batch.push(&t.task);
    }

    try std.testing.expectEqual(@as(usize, 5), batch.length());

    // Pop in FIFO order
    var count: u32 = 0;
    while (batch.pop()) |task| {
        const t: *TestTask = @fieldParentPtr("task", task);
        try std.testing.expectEqual(count, t.id);
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 5), count);
}

test "TaskClosure" {
    const Args = struct { a: i32, b: i32 };

    const add = struct {
        fn f(args: Args) i32 {
            return args.a + args.b;
        }
    }.f;

    var closure = TaskClosure(Args, i32).init(add, .{ .a = 10, .b = 20 });

    try std.testing.expect(closure.result == null);

    closure.task.run();

    try std.testing.expectEqual(@as(i32, 30), closure.result.?);
}

test "Task reset and reuse" {
    const TestTask = struct {
        counter: u32 = 0,
        task: Task,

        fn init() @This() {
            return .{
                .task = Task.init(execute),
            };
        }

        fn execute(task: *Task) void {
            const self: *@This() = @fieldParentPtr("task", task);
            self.counter += 1;
        }
    };

    var t = TestTask.init();

    t.task.run();
    try std.testing.expectEqual(@as(u32, 1), t.counter);
    try std.testing.expect(t.task.isDone());

    t.task.reset();
    try std.testing.expectEqual(State.ready, t.task.getState());

    t.task.run();
    try std.testing.expectEqual(@as(u32, 2), t.counter);
}
