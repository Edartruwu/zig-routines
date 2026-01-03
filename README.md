# zig-routines

**Concurrency primitives for Zig, built on native OS threads.**

A library providing composable building blocks for concurrent programming: channels, futures, supervision trees, lock-free data structures, and platform-optimized I/O. All primitives use explicit memory management with zero hidden allocations.

---

## What This Library Is

zig-routines is a **multi-paradigm concurrency primitives library**. It provides:

1. **Synchronization primitives** — Mutexes, semaphores, barriers, wait groups
2. **Communication channels** — Bounded/unbounded queues for thread-safe message passing
3. **Lock-free data structures** — MPMC queues, work-stealing deques, SPSC ring buffers
4. **Supervision patterns** — OTP-inspired restart strategies for fault tolerance
5. **Structured concurrency** — Scopes and task groups with automatic cleanup
6. **Platform-optimized I/O** — io_uring (Linux), kqueue (macOS), epoll fallback

### Threading Model

**All concurrency in zig-routines is built on native OS threads** (`std.Thread`). This means:

- Each actor spawns a dedicated OS thread
- Channels synchronize between OS threads using mutexes and condition variables
- The work-stealing scheduler distributes tasks across a fixed thread pool

This is fundamentally different from Erlang/BEAM, which runs millions of lightweight processes on a small number of OS threads with preemptive scheduling. zig-routines is better suited for:

- **CPU-bound parallelism** — Distribute computation across cores
- **Structured coordination** — Synchronize a bounded number of concurrent tasks
- **Low-level control** — When you need explicit memory management and zero runtime overhead

It is **not** designed for:

- Running millions of concurrent connections (use an async runtime like io_uring directly)
- Distributed systems (single-machine only)
- Hot code reloading

---

## Quick Comparison

| Aspect                | zig-routines         | Erlang/BEAM               | Go               | Tokio (Rust) |
| --------------------- | -------------------- | ------------------------- | ---------------- | ------------ |
| **Execution unit**    | OS thread            | Lightweight process       | Goroutine (M:N)  | Task (M:N)   |
| **Concurrency scale** | ~100s of threads     | Millions of processes     | ~100K goroutines | ~100K tasks  |
| **Memory model**      | Explicit allocators  | GC per process            | GC               | Ownership    |
| **Scheduler**         | Work-stealing        | Preemptive, fair          | Preemptive       | Cooperative  |
| **Distribution**      | None                 | Built-in                  | None             | None         |
| **Use case**          | CPU-bound, low-level | I/O-bound, fault-tolerant | General          | Async I/O    |

---

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_routines = .{
        .url = "https://github.com/Edartruwu/zig-routines/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in `build.zig`:

```zig
const zig_routines = b.dependency("zig_routines", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zig_routines", zig_routines.module("zig_routines"));
```

---

## Core Primitives

### Channels

Thread-safe FIFO queues for message passing between threads.

```zig
const zr = @import("zig_routines");

// Bounded channel — blocks sender when full
var ch = try zr.channel.BoundedChannel(u32).init(allocator, 100);
defer ch.deinit();

// Producer thread
try ch.send(42);

// Consumer thread
const value = try ch.recv();  // Blocks until message available

ch.close();
```

**Implementation**: Ring buffer protected by mutex, with condition variables for blocking send/recv.

**Variants**:

- `BoundedChannel(T)` — Fixed capacity, backpressure via blocking
- `UnboundedChannel(T)` — Linked list, no backpressure (memory grows)
- `OneshotChannel(T)` — Single value transfer, like a one-shot promise

---

### Futures and Promises

A value that will be available later, with polling or blocking access.

```zig
const pair = try zr.future.Promise(u32).create(allocator);
const promise = pair.promise;
var future = pair.future;
defer future.deinit();
defer promise.deinit();

// Producer resolves
promise.resolve(42);

// Consumer polls or blocks
if (future.poll()) |value| {
    // Ready
}
const value = try future.await();  // Blocking wait
```

**Combinators**:

- `all(futures)` — Wait for all, fail fast on first error
- `race(futures)` — Return first completed
- `any(futures)` — Return first successful
- `allSettled(futures)` — Collect all results regardless of success/failure

---

### Lock-Free Data Structures

For high-contention scenarios where mutex overhead is unacceptable.

```zig
// Multi-producer multi-consumer bounded queue (Vyukov's algorithm)
var queue = try zr.lockfree.MPMCQueue(*Task).init(allocator, 1024);
try queue.push(&task);
if (queue.pop()) |t| t.execute();

// Work-stealing deque (Chase-Lev algorithm)
var deque = try zr.lockfree.WorkStealingDeque(*Task).init(allocator, 256);
deque.push(&task);        // Owner: LIFO push/pop
_ = deque.steal();        // Thieves: FIFO steal

// Single-producer single-consumer ring buffer (wait-free)
var ring = try zr.lockfree.SPSCQueue(Event).init(allocator, 4096);
```

**Implementation details**:

- MPMC uses per-slot sequence numbers with CAS
- Work-stealing deque uses atomic indices with acquire/release ordering
- Cache-line padding prevents false sharing

---

### Synchronization Primitives

Standard concurrency building blocks.

```zig
// WaitGroup — wait for N tasks to complete
var wg = zr.sync.WaitGroup.init();
wg.add(3);
// ... spawn threads that call wg.done()
wg.wait();

// Semaphore — limit concurrent access
var sem = try zr.sync.Semaphore.init(allocator, 10);
try sem.acquire();
defer sem.release();

// Barrier — synchronize N threads at a point
var barrier = try zr.sync.Barrier.init(allocator, num_threads);
try barrier.wait();  // All threads block until everyone arrives
```

---

## Supervision Trees

Restart strategies for managing thread lifecycles, inspired by OTP but adapted for OS threads.

```zig
var sup = try zr.actor.Supervisor.init(allocator, .{
    .strategy = .one_for_one,  // Restart only the failed child
    .max_restarts = 3,         // Max 3 restarts...
    .max_seconds = 5,          // ...within 5 seconds
});
defer sup.deinit();

try sup.startChild(.{
    .id = "worker",
    .start_fn = workerStart,
    .restart = .permanent,     // Always restart
});
```

**Strategies**:

- `one_for_one` — Restart only the failed child
- `one_for_all` — Restart all children if one fails
- `rest_for_one` — Restart failed child and all children started after it

**Important difference from Erlang**: Each child runs in a dedicated OS thread. Supervision provides restart logic, not lightweight process isolation. There's no per-process garbage collection or memory isolation — a crash in one thread can corrupt shared state.

---

## GenServer Pattern

Request-response server running in a dedicated thread.

```zig
const CounterServer = zr.actor.GenServer(
    i32,    // Request type
    i32,    // Response type
    void,   // Cast type (async messages)
    i32,    // State type
    struct {
        pub fn init() i32 { return 0; }

        pub fn handleCall(state: *i32, request: i32) i32 {
            state.* += request;
            return state.*;
        }
    },
);

var server = try CounterServer.start(allocator);
defer server.stop();

const result = try server.call(5);   // Synchronous, returns 5
try server.cast({});                  // Asynchronous, fire-and-forget
```

**Implementation**: Spawns a thread that processes messages from a mailbox. `call` blocks the caller until response; `cast` returns immediately.

---

## Structured Concurrency

Scopes that guarantee all spawned tasks complete before the scope exits.

```zig
var scope = try zr.structured.Scope.init(allocator, .{});
defer scope.deinit();

try scope.spawn(fetchDataA, .{url_a});
try scope.spawn(fetchDataB, .{url_b});

try scope.wait();
// All tasks guaranteed complete here
```

**Cancellation**:

```zig
var token = try zr.structured.CancelToken.init(allocator);

// In task:
if (token.isCancelled()) return error.Cancelled;

// From outside:
token.cancel();
```

---

## Platform-Optimized I/O

Completion-based async I/O with platform-specific backends.

| Platform         | Backend  | Notes                          |
| ---------------- | -------- | ------------------------------ |
| Linux            | io_uring | Kernel 5.1+, zero-copy capable |
| Linux (fallback) | epoll    | Edge-triggered                 |
| macOS/BSD        | kqueue   | Kevent-based                   |
| Other            | Threaded | Thread pool fallback           |

```zig
const io = try zr.io.Io.init(allocator, .{});
defer io.deinit();

try io.submit(.{
    .op = .read,
    .fd = socket_fd,
    .buffer = buffer,
    .callback = onComplete,
});

io.poll();  // Process completions
```

---

## Work-Stealing Scheduler

Distributes tasks across worker threads with automatic load balancing.

```zig
var scheduler = try zr.scheduler.WorkStealingScheduler.init(allocator, .{
    .thread_count = 0,  // 0 = auto-detect CPU count
});
defer scheduler.deinit();

try scheduler.spawn(&task);
```

**Implementation**: Each worker has a Chase-Lev deque. Workers pop from their own deque (LIFO for cache locality) and steal from others (FIFO for fairness) when idle.

---

## Architecture

```
src/
├── core/           # Atomics, cache-line padding, intrusive lists
├── sync/           # Mutex, RwLock, Semaphore, WaitGroup, Barrier
├── lockfree/       # MPMC queue, work-stealing deque, SPSC, Treiber stack
├── channel/        # Bounded, unbounded, oneshot channels
├── future/         # Futures, promises, combinators
├── actor/          # Actor, mailbox, supervisor, GenServer
├── structured/     # Scope, TaskGroup, CancelToken
├── scheduler/      # ThreadPool, WorkStealingScheduler
├── io/             # io_uring, kqueue, epoll, threaded backends
└── timer/          # Timer wheel
```

---

## Design Principles

**Explicit allocators**: Every function takes an `Allocator`. No global state, no hidden allocations.

**Comptime generics**: `Channel(T)` is monomorphized at compile time. No vtables, no boxing, no runtime type info.

**Acquire/Release semantics**: Atomic operations use the weakest sufficient memory ordering. SeqCst only when necessary.

**Cache-aware**: Critical structures use cache-line padding to prevent false sharing:

```zig
enqueue_pos: cache_line.Padded(atomic.Atomic(usize))
dequeue_pos: cache_line.Padded(atomic.Atomic(usize))
```

---

## Testing

```bash
zig build test              # Run all 188+ tests
zig build test --summary all  # Verbose output
```

---

## Examples

```bash
zig build run               # Library info
zig build basic_channel     # Channel demo
zig build actor_example     # Actor lifecycle
zig build genserver_example # Request-response server
zig build futures_example   # Promises and combinators
```

---

## Requirements

- **Zig**: 0.15.x or later
- **Linux**: x86_64, aarch64 (io_uring requires kernel 5.1+)
- **macOS**: aarch64, x86_64

---

## Acknowledgments

Built with techniques from:

- Dmitry Vyukov's bounded MPMC queue
- Chase-Lev work-stealing deque
- Treiber stack
- OTP supervision patterns (adapted for OS threads)
- Swift structured concurrency model

---

## License

MIT License. See [LICENSE](LICENSE) for details.
