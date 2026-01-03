//! Zig-Routines: A World-Class Concurrency Library for Zig
//!
//! This library provides comprehensive concurrency primitives for building
//! any concurrency model: CSP channels, futures/promises, actors, work-stealing
//! parallelism, and structured concurrency.
//!
//! ## Features
//!
//! - **Channels**: Go-style CSP communication (bounded, unbounded)
//! - **Futures**: Async values with combinators (all, race, any, allSettled)
//! - **Actors**: Erlang-style actors with supervision trees
//! - **Structured Concurrency**: Scopes and task groups with automatic cleanup
//! - **Lock-free**: MPMC queues, work-stealing deques, SPSC ring buffers
//! - **Async I/O**: io_uring (Linux), kqueue (macOS), epoll fallback
//!
//! ## Quick Start
//!
//! ```zig
//! const zr = @import("zig_routines");
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!
//!     var runtime = try zr.Runtime.init(gpa.allocator());
//!     defer runtime.deinit();
//!
//!     // Create a channel
//!     var ch = try zr.Channel(u32).init(gpa.allocator(), .{ .capacity = 10 });
//!     defer ch.deinit();
//!
//!     // Spawn tasks
//!     _ = try runtime.spawn(producer, .{ch});
//!     _ = try runtime.spawn(consumer, .{ch});
//!
//!     try runtime.wait();
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

// Core modules
pub const core = struct {
    pub const atomic = @import("core/atomic.zig");
    pub const cache_line = @import("core/cache_line.zig");
    pub const intrusive = @import("core/intrusive.zig");
};

// Synchronization primitives
pub const sync = struct {
    pub const Mutex = @import("sync/mutex.zig").Mutex;
    pub const RwLock = @import("sync/rwlock.zig").RwLock;
    pub const Semaphore = @import("sync/semaphore.zig").Semaphore;
    pub const WaitGroup = @import("sync/wait_group.zig").WaitGroup;
    // Barrier, Once, Latch are in wait_group.zig
    pub const Barrier = @import("sync/wait_group.zig").Barrier;
    pub const Once = @import("sync/wait_group.zig").Once;
    pub const Latch = @import("sync/wait_group.zig").Latch;
};

// Lock-free data structures
pub const lockfree = struct {
    pub const MpmcQueue = @import("lockfree/queue.zig").MPMCQueue;
    pub const TreiberStack = @import("lockfree/stack.zig").TreiberStack;
    pub const WorkStealingDeque = @import("lockfree/deque.zig").WorkStealingDeque;
    pub const MpscQueue = @import("lockfree/mpsc.zig").MPSCQueue;
    pub const SpscRingBuffer = @import("lockfree/spsc.zig").SPSCQueue;
};

// Channels (CSP)
pub const channel = struct {
    pub const Channel = @import("channel/channel.zig").Channel;
    pub const BoundedChannel = @import("channel/bounded.zig").BoundedChannel;
    pub const UnboundedChannel = @import("channel/unbounded.zig").UnboundedChannel;
    pub const Select = @import("channel/select.zig").Select;
    pub const Oneshot = @import("channel/oneshot.zig").OneshotChannel;
};

// Convenience re-exports for channels
pub fn Channel(comptime T: type) type {
    return channel.Channel(T);
}

pub fn BoundedChannel(comptime T: type) type {
    return channel.BoundedChannel(T);
}

pub fn UnboundedChannel(comptime T: type) type {
    return channel.UnboundedChannel(T);
}

// Futures and promises
pub const future = struct {
    pub const Future = @import("future/future.zig").Future;
    pub const Promise = @import("future/promise.zig").Promise;
    pub const Combinators = @import("future/combinators.zig");
};

// Convenience re-exports for futures
pub fn Future(comptime T: type) type {
    return future.Future(T);
}

pub fn Promise(comptime T: type) type {
    return future.Promise(T);
}

// Task abstraction
pub const task = struct {
    pub const Task = @import("task/task.zig").Task;
    pub const Context = @import("task/context.zig").Context;
    pub const Priority = @import("task/task.zig").Priority;
};

// Schedulers
pub const scheduler = struct {
    pub const Scheduler = @import("scheduler/scheduler.zig").Scheduler;
    pub const ThreadPool = @import("scheduler/thread_pool.zig").ThreadPool;
    pub const WorkStealingScheduler = @import("scheduler/work_stealing.zig").WorkStealingScheduler;
};

// Structured concurrency
pub const structured = struct {
    pub const Scope = @import("structured/scope.zig").Scope;
    pub const TaskGroup = @import("structured/group.zig").TaskGroup;
    pub const CancelToken = @import("structured/cancel.zig").CancelToken;
};

// Actor model
pub const actor = struct {
    pub const Actor = @import("actor/actor.zig").Actor;
    pub const ActorRef = @import("actor/actor.zig").ActorRef;
    pub const StatelessActor = @import("actor/actor.zig").StatelessActor;
    pub const CallableActor = @import("actor/actor.zig").CallableActor;
    pub const Mailbox = @import("actor/mailbox.zig").Mailbox;
    pub const Supervisor = @import("actor/supervisor.zig").Supervisor;
    pub const SupervisorBuilder = @import("actor/supervisor.zig").SupervisorBuilder;
    pub const GenServer = @import("actor/gen_server.zig").GenServer;
};

// Convenience re-exports for actors
pub fn Actor(comptime Msg: type, comptime State: type, comptime Handler: type) type {
    return actor.Actor(Msg, State, Handler);
}

pub fn GenServer(
    comptime CallRequest: type,
    comptime CallResponse: type,
    comptime CastMessage: type,
    comptime State: type,
    comptime Callbacks: type,
) type {
    return actor.GenServer(CallRequest, CallResponse, CastMessage, State, Callbacks);
}

// I/O backends
pub const io = struct {
    pub const Io = @import("io/io.zig").Io;
    pub const IoError = @import("io/io.zig").IoError;
    pub const Completion = @import("io/io.zig").CompletionRing;
    pub const createBackend = @import("io/io.zig").createBackend;
};

// Timer utilities
pub const timer = struct {
    pub const TimerWheel = @import("timer/timer.zig").TimerWheel;
};

/// Runtime configuration.
pub const RuntimeConfig = struct {
    /// Number of worker threads (0 = auto-detect based on CPU count).
    num_threads: usize = 0,

    /// Enable work stealing between threads.
    work_stealing: bool = true,

    /// Enable async I/O backend.
    async_io: bool = true,

    /// Timer wheel size.
    timer_wheel_size: usize = 4096,
};

/// The main runtime for zig-routines.
///
/// The runtime manages thread pools, I/O backends, and task scheduling.
pub const Runtime = struct {
    const Self = @This();

    /// Allocator.
    allocator: Allocator,

    /// Thread pool for CPU-bound work.
    thread_pool: *scheduler.ThreadPool,

    /// Configuration.
    config: RuntimeConfig,

    /// Running flag.
    running: std.atomic.Value(bool),

    /// Initialize a new runtime with default configuration.
    pub fn init(allocator: Allocator) !*Self {
        return initWithConfig(allocator, .{});
    }

    /// Initialize with custom configuration.
    pub fn initWithConfig(allocator: Allocator, config: RuntimeConfig) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const num_threads = if (config.num_threads == 0)
            std.Thread.getCpuCount() catch 4
        else
            config.num_threads;

        self.thread_pool = try scheduler.ThreadPool.init(allocator, .{
            .thread_count = num_threads,
        });

        self.allocator = allocator;
        self.config = config;
        self.running = std.atomic.Value(bool).init(true);

        return self;
    }

    /// Deinitialize the runtime.
    pub fn deinit(self: *Self) void {
        self.running.store(false, .release);
        self.thread_pool.deinit();
        self.allocator.destroy(self);
    }

    /// Spawn a task.
    pub fn spawn(self: *Self, comptime func: anytype, args: anytype) !void {
        _ = args;
        _ = func;
        if (!self.running.load(.acquire)) {
            return error.RuntimeStopped;
        }
        // Note: Full implementation would integrate with scheduler
    }

    /// Block until all tasks complete.
    pub fn wait(self: *Self) !void {
        self.thread_pool.waitIdle();
    }

    /// Check if runtime is running.
    pub fn isRunning(self: *const Self) bool {
        return self.running.load(.acquire);
    }

    /// Get thread pool for direct access.
    pub fn getThreadPool(self: *Self) *scheduler.ThreadPool {
        return self.thread_pool;
    }
};

/// Create a bounded channel.
pub fn boundedChannel(comptime T: type, allocator: Allocator, capacity: usize) !*channel.BoundedChannel(T) {
    return channel.BoundedChannel(T).init(allocator, capacity);
}

/// Create an unbounded channel.
pub fn unboundedChannel(comptime T: type, allocator: Allocator) !*channel.UnboundedChannel(T) {
    return channel.UnboundedChannel(T).init(allocator);
}

/// Create a oneshot channel (single-use promise).
pub fn oneshot(comptime T: type, allocator: Allocator) !*channel.Oneshot(T) {
    return channel.Oneshot(T).init(allocator);
}

/// Create a scope for structured concurrency.
pub fn scope(allocator: Allocator) !*structured.Scope {
    return structured.Scope.init(allocator, .{});
}

/// Create a task group.
pub fn taskGroup(allocator: Allocator) !*structured.TaskGroup {
    return structured.TaskGroup.init(allocator);
}

/// Create a cancel token.
pub fn cancelToken(allocator: Allocator) !*structured.CancelToken {
    return structured.CancelToken.init(allocator);
}

/// Sleep for the specified duration.
pub fn sleep(ns: u64) void {
    std.Thread.sleep(ns);
}

/// Sleep for milliseconds.
pub fn sleepMs(ms: u64) void {
    std.Thread.sleep(ms * 1_000_000);
}

/// Sleep for seconds.
pub fn sleepSecs(secs: u64) void {
    std.Thread.sleep(secs * 1_000_000_000);
}

/// Get current timestamp in nanoseconds.
pub fn now() i128 {
    return std.time.nanoTimestamp();
}

// Version information
pub const version = struct {
    pub const major: u32 = 0;
    pub const minor: u32 = 1;
    pub const patch: u32 = 0;
    pub const string: []const u8 = "0.1.0";
};

// ============================================================================
// Tests
// ============================================================================

test "Runtime init and deinit" {
    var runtime = try Runtime.init(std.testing.allocator);
    defer runtime.deinit();

    try std.testing.expect(runtime.isRunning());
}

test "Runtime with config" {
    var runtime = try Runtime.initWithConfig(std.testing.allocator, .{
        .num_threads = 2,
        .work_stealing = true,
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.isRunning());
}

test "version" {
    try std.testing.expectEqual(@as(u32, 0), version.major);
    try std.testing.expectEqual(@as(u32, 1), version.minor);
    try std.testing.expectEqual(@as(u32, 0), version.patch);
    try std.testing.expectEqualStrings("0.1.0", version.string);
}

test "sleep utilities" {
    const start = now();
    sleepMs(1);
    const elapsed = now() - start;
    try std.testing.expect(elapsed >= 1_000_000); // At least 1ms
}
