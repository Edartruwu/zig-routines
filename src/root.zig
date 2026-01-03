//! zig-routines: A world-class concurrency library for Zig.
//!
//! This library provides primitives to build ANY concurrency model:
//! - CSP-style channels (Go)
//! - Futures and promises (JavaScript/Rust)
//! - Structured concurrency (Swift/Python Trio)
//! - Actor model (Erlang/OTP)
//! - Work-stealing parallelism (Rayon)
//!
//! ## Design Principles
//!
//! - **Explicit memory management** via allocators
//! - **Zero-cost abstractions** through comptime generics
//! - **Composable primitives** that work together
//! - **Cross-platform** with optimized backends (io_uring, kqueue)
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
//!     // Create tasks
//!     var task = zr.Task.init(myCallback);
//!
//!     // Use synchronization primitives
//!     var wg = zr.sync.WaitGroup.init();
//!     wg.add(1);
//!     defer wg.done();
//!
//!     // Use cancellation contexts
//!     var ctx = zr.Context.init();
//!     task = zr.Task.initWithContext(myCallback, &ctx);
//! }
//! ```

const std = @import("std");

// ============================================================================
// Core Module
// ============================================================================

/// Extended atomic operations for lock-free programming.
pub const atomic = @import("core/atomic.zig");

/// Cache-line alignment utilities for preventing false sharing.
pub const cache_line = @import("core/cache_line.zig");

/// Intrusive data structures for zero-allocation queuing.
pub const intrusive = @import("core/intrusive.zig");

// ============================================================================
// Task Module
// ============================================================================

/// Task - the fundamental unit of concurrent execution.
pub const Task = @import("task/task.zig").Task;

/// Task batch for bulk operations.
pub const TaskBatch = @import("task/task.zig").TaskBatch;

/// Task priority levels.
pub const Priority = @import("task/task.zig").Priority;

/// Task state.
pub const TaskState = @import("task/task.zig").State;

/// Task closure helper.
pub const TaskClosure = @import("task/task.zig").TaskClosure;

/// Cancellation context for cooperative task cancellation.
pub const Context = @import("task/context.zig").Context;

/// Cancellation reason enum.
pub const CancelReason = @import("task/context.zig").CancelReason;

/// Simple cancellation token.
pub const CancelToken = @import("task/context.zig").CancelToken;

/// Fluent context builder.
pub const ContextBuilder = @import("task/context.zig").ContextBuilder;

// ============================================================================
// Synchronization Primitives
// ============================================================================

/// Synchronization primitives namespace.
pub const sync = struct {
    /// WaitGroup for coordinating multiple concurrent tasks.
    pub const WaitGroup = @import("sync/wait_group.zig").WaitGroup;

    /// Latch - single-use countdown synchronization barrier.
    pub const Latch = @import("sync/wait_group.zig").Latch;

    /// Barrier - reusable synchronization point for fixed number of threads.
    pub const Barrier = @import("sync/wait_group.zig").Barrier;

    /// Once - ensures a function is executed exactly once.
    pub const Once = @import("sync/wait_group.zig").Once;

    /// Mutex - async-aware mutual exclusion lock.
    pub const Mutex = @import("sync/mutex.zig").Mutex;

    /// Recursive mutex (reentrant).
    pub const RecursiveMutex = @import("sync/mutex.zig").RecursiveMutex;

    /// Spin mutex for very short critical sections.
    pub const SpinMutex = @import("sync/mutex.zig").SpinMutex;

    /// Ticket mutex for strict FIFO ordering.
    pub const TicketMutex = @import("sync/mutex.zig").TicketMutex;

    /// Mutex guard for RAII locking.
    pub const MutexGuard = @import("sync/mutex.zig").MutexGuard;

    /// Read-write lock with writer priority.
    pub const RwLock = @import("sync/rwlock.zig").RwLock;

    /// Fair read-write lock with FIFO ordering.
    pub const FairRwLock = @import("sync/rwlock.zig").FairRwLock;

    /// Read guard for RAII shared locking.
    pub const ReadGuard = @import("sync/rwlock.zig").ReadGuard;

    /// Write guard for RAII exclusive locking.
    pub const WriteGuard = @import("sync/rwlock.zig").WriteGuard;

    /// Counting semaphore.
    pub const Semaphore = @import("sync/semaphore.zig").Semaphore;

    /// Binary semaphore.
    pub const BinarySemaphore = @import("sync/semaphore.zig").BinarySemaphore;

    /// Weighted semaphore for varying costs.
    pub const WeightedSemaphore = @import("sync/semaphore.zig").WeightedSemaphore;

    /// Resource pool semaphore.
    pub const PoolSemaphore = @import("sync/semaphore.zig").PoolSemaphore;
};

// ============================================================================
// Lock-Free Data Structures
// ============================================================================

/// Lock-free data structures namespace.
pub const lockfree = struct {
    /// SPSC (Single-Producer Single-Consumer) bounded queue.
    pub const SPSCQueue = @import("lockfree/spsc.zig").SPSCQueue;

    /// Unbounded SPSC queue using linked chunks.
    pub const UnboundedSPSCQueue = @import("lockfree/spsc.zig").UnboundedSPSCQueue;

    /// MPSC (Multi-Producer Single-Consumer) queue.
    pub const MPSCQueue = @import("lockfree/mpsc.zig").MPSCQueue;

    /// Intrusive MPSC queue (zero allocation).
    pub const IntrusiveMPSCQueue = @import("lockfree/mpsc.zig").IntrusiveMPSCQueue;

    /// Bounded MPSC queue using ring buffer.
    pub const BoundedMPSCQueue = @import("lockfree/mpsc.zig").BoundedMPSCQueue;

    /// MPMC (Multi-Producer Multi-Consumer) bounded queue.
    pub const MPMCQueue = @import("lockfree/queue.zig").MPMCQueue;

    /// Chase-Lev work-stealing deque.
    pub const WorkStealingDeque = @import("lockfree/deque.zig").WorkStealingDeque;

    /// Stealer handle for work-stealing deques.
    pub const Stealer = @import("lockfree/deque.zig").Stealer;

    /// Result type for steal operations.
    pub const StealResult = @import("lockfree/deque.zig").StealResult;

    /// Treiber stack (lock-free LIFO).
    pub const TreiberStack = @import("lockfree/stack.zig").TreiberStack;

    /// Intrusive Treiber stack.
    pub const IntrusiveTreiberStack = @import("lockfree/stack.zig").IntrusiveTreiberStack;

    /// Tagged Treiber stack with ABA prevention.
    pub const TaggedTreiberStack = @import("lockfree/stack.zig").TaggedTreiberStack;

    /// Elimination-backoff stack for high contention.
    pub const EliminationStack = @import("lockfree/stack.zig").EliminationStack;
};

// ============================================================================
// Scheduler Module
// ============================================================================

/// Scheduler types and utilities.
pub const scheduler = struct {
    /// Scheduler interface.
    pub const Scheduler = @import("scheduler/scheduler.zig").Scheduler;

    /// Scheduler configuration.
    pub const Config = @import("scheduler/scheduler.zig").Config;

    /// Scheduler state.
    pub const State = @import("scheduler/scheduler.zig").State;

    /// Spawn error type.
    pub const SpawnError = @import("scheduler/scheduler.zig").SpawnError;

    /// Worker context.
    pub const WorkerContext = @import("scheduler/scheduler.zig").WorkerContext;

    /// Thread pool scheduler.
    pub const ThreadPool = @import("scheduler/thread_pool.zig").ThreadPool;

    /// Work-stealing scheduler.
    pub const WorkStealingScheduler = @import("scheduler/work_stealing.zig").WorkStealingScheduler;
};

/// Thread pool scheduler (convenience re-export).
pub const ThreadPool = scheduler.ThreadPool;

/// Work-stealing scheduler (convenience re-export).
pub const WorkStealingScheduler = scheduler.WorkStealingScheduler;

// ============================================================================
// Timer Module
// ============================================================================

/// Timer utilities.
pub const timer = struct {
    /// Timer wheel for efficient timeout management.
    pub const TimerWheel = @import("timer/timer.zig").TimerWheel;

    /// Timer configuration.
    pub const TimerConfig = @import("timer/timer.zig").TimerConfig;

    /// Timer entry.
    pub const TimerEntry = @import("timer/timer.zig").TimerEntry;

    /// Timer handle.
    pub const TimerHandle = @import("timer/timer.zig").TimerHandle;

    /// Timer state.
    pub const TimerState = @import("timer/timer.zig").TimerState;

    /// Delay for specified nanoseconds.
    pub const delay = @import("timer/timer.zig").delay;

    /// Delay for specified milliseconds.
    pub const delayMs = @import("timer/timer.zig").delayMs;

    /// Delay for specified seconds.
    pub const delayS = @import("timer/timer.zig").delayS;
};

/// Timer wheel (convenience re-export).
pub const TimerWheel = timer.TimerWheel;

// ============================================================================
// Channel Module (CSP)
// ============================================================================

/// Channel types and utilities for CSP-style communication.
pub const channel = struct {
    /// Generic channel interface.
    pub const Channel = @import("channel/channel.zig").Channel;

    /// Channel state.
    pub const ChannelState = @import("channel/channel.zig").ChannelState;

    /// Send error type.
    pub const SendError = @import("channel/channel.zig").SendError;

    /// Receive error type.
    pub const RecvError = @import("channel/channel.zig").RecvError;

    /// Sender half of a channel.
    pub const Sender = @import("channel/channel.zig").Sender;

    /// Receiver half of a channel.
    pub const Receiver = @import("channel/channel.zig").Receiver;

    /// Bounded (buffered) channel.
    pub const BoundedChannel = @import("channel/bounded.zig").BoundedChannel;

    /// Unbounded channel.
    pub const UnboundedChannel = @import("channel/unbounded.zig").UnboundedChannel;

    /// Select statement for multiplexing.
    pub const Select = @import("channel/select.zig").Select;

    /// Select case.
    pub const SelectCase = @import("channel/select.zig").SelectCase;

    /// Select result.
    pub const SelectResult = @import("channel/select.zig").SelectResult;

    /// One-shot channel.
    pub const OneshotChannel = @import("channel/oneshot.zig").OneshotChannel;

    /// Create a oneshot channel pair.
    pub const oneshot = @import("channel/oneshot.zig").oneshot;
};

/// Generic channel interface (convenience re-export).
pub const Channel = channel.Channel;

/// Bounded channel (convenience re-export).
pub const BoundedChannel = channel.BoundedChannel;

/// Unbounded channel (convenience re-export).
pub const UnboundedChannel = channel.UnboundedChannel;

/// One-shot channel (convenience re-export).
pub const OneshotChannel = channel.OneshotChannel;

// ============================================================================
// Future Module
// ============================================================================

/// Future and promise types for async computation.
pub const future = struct {
    /// Future - a value that will be available later.
    pub const Future = @import("future/future.zig").Future;

    /// Future state.
    pub const FutureState = @import("future/future.zig").FutureState;

    /// Future error type.
    pub const FutureError = @import("future/future.zig").FutureError;

    /// Promise - writable side of a Future.
    pub const Promise = @import("future/promise.zig").Promise;

    /// Settled result type.
    pub const SettledResult = @import("future/promise.zig").SettledResult;

    /// Create a promise/future pair.
    pub const promise = @import("future/promise.zig").promise;

    /// Create an already-resolved future.
    pub const resolved = @import("future/promise.zig").resolved;

    /// Combinators for futures.
    pub const combinators = struct {
        /// Wait for all futures to complete.
        pub const all = @import("future/combinators.zig").all;

        /// Wait for all futures, returning results even for failures.
        pub const allSettled = @import("future/combinators.zig").allSettled;

        /// Return the first future to complete.
        pub const race = @import("future/combinators.zig").race;

        /// Return the first successful future.
        pub const any = @import("future/combinators.zig").any;

        /// Race with timeout.
        pub const raceTimeout = @import("future/combinators.zig").raceTimeout;

        /// Settled result type for combinators.
        pub const SettledResult = @import("future/combinators.zig").SettledResult;
    };
};

/// Future type (convenience re-export).
pub const Future = future.Future;

/// Promise type (convenience re-export).
pub const Promise = future.Promise;

// ============================================================================
// Structured Concurrency Module
// ============================================================================

/// Structured concurrency primitives.
pub const structured = struct {
    /// Scope (nursery pattern) for structured concurrency.
    pub const Scope = @import("structured/scope.zig").Scope;

    /// Scope state.
    pub const ScopeState = @import("structured/scope.zig").ScopeState;

    /// Scope error type.
    pub const ScopeError = @import("structured/scope.zig").ScopeError;

    /// Task group for fork-join patterns.
    pub const TaskGroup = @import("structured/group.zig").TaskGroup;

    /// Fork-join helper.
    pub const ForkJoin = @import("structured/group.zig").ForkJoin;

    /// Cancel token.
    pub const CancelToken = @import("structured/cancel.zig").CancelToken;

    /// Cancel token state.
    pub const TokenState = @import("structured/cancel.zig").TokenState;

    /// Cancel error.
    pub const CancelError = @import("structured/cancel.zig").CancelError;

    /// Cancel token source (can create child tokens).
    pub const CancelTokenSource = @import("structured/cancel.zig").CancelTokenSource;

    /// Linked cancel token (cancelled when any parent is cancelled).
    pub const LinkedCancelToken = @import("structured/cancel.zig").LinkedCancelToken;
};

/// Scope (convenience re-export).
pub const Scope = structured.Scope;

/// TaskGroup (convenience re-export).
pub const TaskGroup = structured.TaskGroup;

// ============================================================================
// I/O Module
// ============================================================================

/// Async I/O types and backends.
pub const io_module = struct {
    /// Unified I/O interface.
    pub const Io = @import("io/io.zig").Io;

    /// I/O operation types.
    pub const OpType = @import("io/io.zig").OpType;

    /// I/O operation result.
    pub const Result = @import("io/io.zig").Result;

    /// I/O submission.
    pub const Submission = @import("io/io.zig").Submission;

    /// I/O configuration.
    pub const Config = @import("io/io.zig").Config;

    /// Backend type.
    pub const Backend = @import("io/io.zig").Backend;

    /// Completion callback type.
    pub const CompletionCallback = @import("io/io.zig").CompletionCallback;

    /// Completion ring buffer.
    pub const CompletionRing = @import("io/io.zig").CompletionRing;

    /// Pending operation tracker.
    pub const PendingOp = @import("io/io.zig").PendingOp;

    /// Linux io_uring backend.
    pub const IoUring = @import("io/uring.zig").IoUring;

    /// Linux epoll backend.
    pub const Epoll = @import("io/epoll.zig").Epoll;

    /// macOS/BSD kqueue backend.
    pub const Kqueue = @import("io/kqueue.zig").Kqueue;

    /// Thread-pool fallback backend.
    pub const ThreadedIo = @import("io/threaded.zig").ThreadedIo;
};

/// Async I/O interface (convenience re-export).
pub const Io = io_module.Io;

// ============================================================================
// Actor Module
// ============================================================================

/// Actor model types.
pub const actor = struct {
    /// Actor mailbox.
    pub const Mailbox = @import("actor/mailbox.zig").Mailbox;

    /// Mailbox configuration.
    pub const MailboxConfig = @import("actor/mailbox.zig").MailboxConfig;

    /// Mailbox state.
    pub const MailboxState = @import("actor/mailbox.zig").MailboxState;

    /// Send error.
    pub const SendError = @import("actor/mailbox.zig").SendError;

    /// Receive error.
    pub const ReceiveError = @import("actor/mailbox.zig").ReceiveError;

    /// System message.
    pub const SystemMessage = @import("actor/mailbox.zig").SystemMessage;

    /// Termination reason.
    pub const TerminationReason = @import("actor/mailbox.zig").TerminationReason;

    /// Generic actor.
    pub const Actor = @import("actor/actor.zig").Actor;

    /// Actor state.
    pub const ActorState = @import("actor/actor.zig").ActorState;

    /// Actor configuration.
    pub const ActorConfig = @import("actor/actor.zig").ActorConfig;

    /// Actor reference.
    pub const ActorRef = @import("actor/actor.zig").ActorRef;

    /// Stateless actor.
    pub const StatelessActor = @import("actor/actor.zig").StatelessActor;

    /// Callable actor (request-response).
    pub const CallableActor = @import("actor/actor.zig").CallableActor;

    /// Supervisor.
    pub const Supervisor = @import("actor/supervisor.zig").Supervisor;

    /// Supervisor configuration.
    pub const SupervisorConfig = @import("actor/supervisor.zig").SupervisorConfig;

    /// Supervisor state.
    pub const SupervisorState = @import("actor/supervisor.zig").SupervisorState;

    /// Supervision strategy.
    pub const Strategy = @import("actor/supervisor.zig").Strategy;

    /// Child restart type.
    pub const RestartType = @import("actor/supervisor.zig").RestartType;

    /// Child specification.
    pub const ChildSpec = @import("actor/supervisor.zig").ChildSpec;

    /// Supervisor builder.
    pub const SupervisorBuilder = @import("actor/supervisor.zig").SupervisorBuilder;

    /// GenServer behavior.
    pub const GenServer = @import("actor/gen_server.zig").GenServer;

    /// GenServer state.
    pub const GenServerState = @import("actor/gen_server.zig").GenServerState;

    /// Reply type for GenServer.
    pub const Reply = @import("actor/gen_server.zig").Reply;

    /// Cast result.
    pub const CastResult = @import("actor/gen_server.zig").CastResult;

    /// State action.
    pub const StateAction = @import("actor/gen_server.zig").StateAction;

    /// Counter server example.
    pub const CounterServer = @import("actor/gen_server.zig").CounterServer;

    /// Key-value server example.
    pub const KVServer = @import("actor/gen_server.zig").KVServer;
};

// ============================================================================
// Re-exports for convenience
// ============================================================================

/// Atomic wrapper with enhanced operations.
pub const Atomic = atomic.Atomic;

/// Atomic pointer with ABA-prevention tag.
pub const AtomicTaggedPtr = atomic.AtomicTaggedPtr;

/// Exponential backoff for spin loops.
pub const Backoff = atomic.Backoff;

/// Atomic flag with test-and-set semantics.
pub const AtomicFlag = atomic.AtomicFlag;

/// Sequence lock for optimistic readers.
pub const SeqLock = atomic.SeqLock;

/// Cache-line padded value.
pub const Padded = cache_line.Padded;

/// Cache-line aligned allocation.
pub const Aligned = cache_line.Aligned;

/// Intrusive linked list node.
pub const Node = intrusive.Node;

/// Intrusive doubly-linked list.
pub const List = intrusive.List;

/// Atomic node for lock-free structures.
pub const AtomicNode = intrusive.AtomicNode;

/// Lock-free MPSC queue.
pub const MPSCQueue = intrusive.MPSCQueue;

// ============================================================================
// Version Information
// ============================================================================

/// Library version.
pub const version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 0,
};

/// Library version string.
pub const version_string = "0.1.0";

// ============================================================================
// Runtime Module (Top-level entry point)
// ============================================================================

/// The main runtime that ties everything together.
pub const routines = @import("routines.zig");

/// Runtime for managing threads, I/O, and scheduling.
pub const Runtime = routines.Runtime;

/// Runtime configuration.
pub const RuntimeConfig = routines.RuntimeConfig;

// ============================================================================
// Tests
// ============================================================================

test {
    // Import all test modules
    // Core
    _ = @import("core/atomic.zig");
    _ = @import("core/cache_line.zig");
    _ = @import("core/intrusive.zig");

    // Task
    _ = @import("task/task.zig");
    _ = @import("task/context.zig");

    // Sync
    _ = @import("sync/wait_group.zig");
    _ = @import("sync/mutex.zig");
    _ = @import("sync/rwlock.zig");
    _ = @import("sync/semaphore.zig");

    // Lock-free
    _ = @import("lockfree/spsc.zig");
    _ = @import("lockfree/mpsc.zig");
    _ = @import("lockfree/deque.zig");
    _ = @import("lockfree/queue.zig");
    _ = @import("lockfree/stack.zig");

    // Scheduler
    _ = @import("scheduler/scheduler.zig");
    _ = @import("scheduler/thread_pool.zig");
    _ = @import("scheduler/work_stealing.zig");

    // Timer
    _ = @import("timer/timer.zig");

    // Channel
    _ = @import("channel/channel.zig");
    _ = @import("channel/bounded.zig");
    _ = @import("channel/unbounded.zig");
    _ = @import("channel/select.zig");
    _ = @import("channel/oneshot.zig");

    // Future
    _ = @import("future/future.zig");
    _ = @import("future/promise.zig");
    _ = @import("future/combinators.zig");

    // Structured Concurrency
    _ = @import("structured/scope.zig");
    _ = @import("structured/group.zig");
    _ = @import("structured/cancel.zig");

    // I/O
    _ = @import("io/io.zig");
    _ = @import("io/uring.zig");
    _ = @import("io/epoll.zig");
    _ = @import("io/kqueue.zig");
    _ = @import("io/threaded.zig");

    // Actor
    _ = @import("actor/mailbox.zig");
    _ = @import("actor/actor.zig");
    _ = @import("actor/supervisor.zig");
    _ = @import("actor/gen_server.zig");

    // Runtime
    _ = @import("routines.zig");
}
