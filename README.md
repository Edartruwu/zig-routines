# zig-routines

**A world-class concurrency library for Zig.**

Build any concurrency model: Go-style channels, Erlang-style actors, Rust-style futures, or Swift-style structured concurrency — all with Zig's explicit memory management and zero hidden allocations.

---

## Features

| Category                   | What You Get                                                         |
| -------------------------- | -------------------------------------------------------------------- |
| **Channels**               | Bounded, unbounded, broadcast, oneshot, select multiplexing          |
| **Futures**                | Promises with `all`, `race`, `any`, `allSettled` combinators         |
| **Actors**                 | Mailboxes, supervision trees, GenServer (OTP-style)                  |
| **Structured Concurrency** | Scopes, task groups, cancellation tokens                             |
| **Lock-free**              | MPMC queues, work-stealing deques, SPSC ring buffers, Treiber stacks |
| **Schedulers**             | Thread pools, work-stealing schedulers                               |
| **Async I/O**              | io_uring (Linux), kqueue (macOS), epoll fallback                     |
| **Synchronization**        | Mutex, RwLock, Semaphore, Barrier, WaitGroup, Latch                  |

---

## Quick Start

### Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_routines = .{
        .url = "https://github.com/Edartruwu/zig-routines/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const zig_routines = b.dependency("zig_routines", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zig_routines", zig_routines.module("zig_routines"));
```

### Basic Usage

```zig
const std = @import("std");
const zr = @import("zig_routines");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a bounded channel
    var ch = try zr.channel.BoundedChannel(u32).init(allocator, 10);
    defer ch.deinit();

    // Send and receive
    try ch.send(42);
    const value = try ch.recv();
    std.debug.print("Received: {}\n", .{value});
}
```

---

## Concurrency Models

### Channels (CSP)

Go-style channels for safe communication between threads.

```zig
const zr = @import("zig_routines");

// Bounded channel (blocks when full)
var ch = try zr.channel.BoundedChannel(u32).init(allocator, 100);
defer ch.deinit();

// Producer
try ch.send(1);
try ch.send(2);
try ch.send(3);

// Consumer
while (true) {
    const msg = ch.tryRecv() catch break;
    std.debug.print("Got: {}\n", .{msg});
}

// Close when done
ch.close();
```

**Unbounded channels** for when you don't want backpressure:

```zig
var ch = try zr.channel.UnboundedChannel(Event).init(allocator);
defer ch.deinit();

try ch.send(.{ .type = .click, .x = 100, .y = 200 });
```

**Oneshot channels** for single-value transfer (like promises):

```zig
const pair = try zr.channel.OneshotChannel(Result).init(allocator);
defer pair.sender.deinit();
defer pair.receiver.deinit();

// Producer sends exactly once
try pair.sender.send(.{ .status = .ok, .data = payload });

// Consumer receives exactly once
const result = try pair.receiver.recv();
```

---

### Actors

Erlang-style actors with message passing and supervision.

```zig
const zr = @import("zig_routines");

// Define an actor with message type, state type, and handler
const CounterActor = zr.actor.Actor(
    u32,    // Message type
    u32,    // State type
    struct {
        pub fn handle(state: *u32, msg: u32) void {
            state.* += msg;
        }

        pub fn onStart(state: *u32) void {
            std.debug.print("Counter started at {}\n", .{state.*});
        }

        pub fn onStop(state: *u32) void {
            std.debug.print("Final count: {}\n", .{state.*});
        }
    },
);

// Spawn the actor
var actor = try CounterActor.spawn(allocator, 0);
defer actor.stop();

// Send messages
try actor.send(5);
try actor.send(10);
```

**GenServer** for request-response patterns:

```zig
const CounterServer = zr.actor.GenServer(
    i32,    // Request type (increment amount)
    i32,    // Response type (new total)
    void,   // Cast message type (unused)
    i32,    // State type
    struct {
        pub fn init() i32 {
            return 0;
        }

        pub fn handleCall(state: *i32, request: i32) i32 {
            state.* += request;
            return state.*;
        }
    },
);

var server = try CounterServer.start(allocator);
defer server.stop();

// Synchronous calls with responses
const result1 = try server.call(5);   // Returns 5
const result2 = try server.call(10);  // Returns 15
```

**Supervision trees** for fault tolerance:

```zig
var sup = try zr.actor.Supervisor.init(allocator, .{
    .strategy = .one_for_one,  // Restart only failed child
    .max_restarts = 3,
    .max_seconds = 5,
});
defer sup.deinit();

try sup.startChild(.{
    .id = "worker1",
    .start_fn = workerStart,
    .restart = .permanent,
});
```

Supervision strategies:

- **`one_for_one`**: Restart only the failed child
- **`one_for_all`**: Restart all children if one fails
- **`rest_for_one`**: Restart failed child and all children started after it

---

### Futures & Promises

JavaScript-style async values with combinators.

```zig
const zr = @import("zig_routines");

// Create a promise/future pair
const pair = try zr.future.Promise(u32).create(allocator);
const promise = pair.promise;
var future = pair.future;
defer future.deinit();
defer promise.deinit();

// Resolve from producer
promise.resolve(42);

// Poll from consumer
if (future.poll()) |value| {
    std.debug.print("Got: {}\n", .{value});
}
```

**Combinators** for composing futures:

```zig
// Wait for all futures to complete
const results = try zr.future.combinators.all(T, allocator, &futures);

// Wait for first to complete
const winner = try zr.future.combinators.race(T, allocator, &futures);

// Wait for first successful result
const first_ok = try zr.future.combinators.any(T, allocator, &futures);

// Get all results (including failures)
const settled = try zr.future.combinators.allSettled(T, allocator, &futures);
```

---

### Structured Concurrency

Swift/Python Trio-style scopes for automatic cleanup.

```zig
const zr = @import("zig_routines");

var scope = try zr.structured.Scope.init(allocator, .{});
defer scope.deinit();

// Spawn tasks in the scope
try scope.spawn(fetchDataA, .{url_a});
try scope.spawn(fetchDataB, .{url_b});

// Wait for all tasks to complete
try scope.wait();
// All tasks guaranteed to be done here
```

**Task groups** for fork-join parallelism:

```zig
var group = try zr.structured.TaskGroup.init(allocator);
defer group.deinit();

// Fork
try group.spawn(processChunk, .{chunk1});
try group.spawn(processChunk, .{chunk2});
try group.spawn(processChunk, .{chunk3});

// Join
group.wait();
```

**Cancellation tokens** for cooperative cancellation:

```zig
var token = try zr.structured.CancelToken.init(allocator);
defer token.deinit();

// Pass to tasks
try scope.spawn(longRunningTask, .{token});

// Cancel from anywhere
token.cancel();

// Tasks check cancellation
if (token.isCancelled()) {
    return error.Cancelled;
}
```

---

### Lock-free Data Structures

High-performance concurrent collections.

```zig
const zr = @import("zig_routines");

// Multi-producer multi-consumer queue
var queue = try zr.lockfree.MPMCQueue(*Task).init(allocator, 1024);
defer queue.deinit();

try queue.push(&task);
if (queue.pop()) |t| {
    t.execute();
}

// Work-stealing deque (for schedulers)
var deque = try zr.lockfree.WorkStealingDeque(*Task).init(allocator, 256);
defer deque.deinit();

deque.push(&task);           // Owner pushes
const stolen = deque.steal(); // Thieves steal

// SPSC ring buffer (single-producer single-consumer)
var ring = try zr.lockfree.SPSCQueue(Event).init(allocator, 4096);
defer ring.deinit();
```

---

### Thread Pool & Schedulers

```zig
const zr = @import("zig_routines");

// Simple thread pool
var pool = try zr.scheduler.ThreadPool.init(allocator, .{
    .thread_count = 8,
});
defer pool.deinit();

try pool.spawn(&task);
pool.waitIdle();

// Work-stealing scheduler (better load balancing)
var scheduler = try zr.scheduler.WorkStealingScheduler.init(allocator, .{
    .thread_count = 0,  // Auto-detect CPU count
});
defer scheduler.deinit();
```

---

### Synchronization Primitives

```zig
const zr = @import("zig_routines");

// WaitGroup for coordinating goroutines
var wg = zr.sync.WaitGroup.init();
wg.add(3);

// In workers:
defer wg.done();

// Wait for all:
wg.wait();

// Mutex with guard
var mutex = zr.sync.Mutex.init();
{
    var guard = mutex.guard();
    defer guard.release();
    // Critical section
}

// Read-write lock
var rwlock = zr.sync.RwLock.init();
{
    var read = rwlock.readGuard();
    defer read.release();
    // Multiple readers allowed
}

// Semaphore
var sem = try zr.sync.Semaphore.init(allocator, 10);
defer sem.deinit();
try sem.acquire();
defer sem.release();

// Barrier
var barrier = try zr.sync.Barrier.init(allocator, num_threads);
defer barrier.deinit();
try barrier.wait();
```

---

## Architecture

```
src/
├── root.zig              # Public API
├── routines.zig          # Runtime
├── core/                 # Foundation
│   ├── atomic.zig        # Extended atomics
│   ├── cache_line.zig    # Cache alignment
│   └── intrusive.zig     # Intrusive data structures
├── sync/                 # Synchronization
│   ├── mutex.zig
│   ├── rwlock.zig
│   ├── semaphore.zig
│   └── wait_group.zig
├── lockfree/             # Lock-free structures
│   ├── queue.zig         # MPMC queue
│   ├── deque.zig         # Work-stealing deque
│   ├── mpsc.zig          # MPSC queue
│   ├── spsc.zig          # SPSC ring buffer
│   └── stack.zig         # Treiber stack
├── channel/              # CSP channels
│   ├── bounded.zig
│   ├── unbounded.zig
│   ├── oneshot.zig
│   └── select.zig
├── future/               # Futures
│   ├── future.zig
│   ├── promise.zig
│   └── combinators.zig
├── actor/                # Actor model
│   ├── actor.zig
│   ├── mailbox.zig
│   ├── supervisor.zig
│   └── gen_server.zig
├── structured/           # Structured concurrency
│   ├── scope.zig
│   ├── group.zig
│   └── cancel.zig
├── scheduler/            # Schedulers
│   ├── thread_pool.zig
│   └── work_stealing.zig
├── io/                   # Async I/O
│   ├── io.zig
│   ├── uring.zig
│   ├── epoll.zig
│   ├── kqueue.zig
│   └── threaded.zig
└── timer/                # Timers
    └── timer.zig
```

---

## Design Principles

### Explicit Memory Management

Every allocation requires an allocator. No hidden allocations, no global state.

```zig
// You control the allocator
var ch = try BoundedChannel(T).init(my_allocator, capacity);
defer ch.deinit();
```

### Zero-Cost Abstractions

Comptime generics eliminate runtime overhead. The channel type is determined at compile time.

```zig
// No boxing, no vtables, no runtime type info
const IntChannel = zr.channel.BoundedChannel(i32);
const StringChannel = zr.channel.BoundedChannel([]const u8);
```

### Composable Primitives

Build complex patterns from simple pieces:

```zig
// Combine channels + actors + structured concurrency
var scope = try Scope.init(allocator, .{});
defer scope.deinit();

try scope.spawn(producer, .{channel});
try scope.spawn(actor.ref(), .{});
try scope.wait();
```

### Platform-Optimized I/O

Automatically uses the best available backend:

| Platform | Primary  | Fallback |
| -------- | -------- | -------- |
| Linux    | io_uring | epoll    |
| macOS    | kqueue   | threaded |
| Other    | threaded | —        |

---

## Examples

Run the included examples:

```bash
# Show library info
zig build run

# Channel example
zig build basic_channel

# Actor example
zig build actor_example

# GenServer example
zig build genserver_example

# Futures example
zig build futures_example
```

---

## Testing

```bash
# Run all tests
zig build test

# Run with verbose output
zig build test --summary all
```

The library includes 188 tests covering all modules.

---

## Performance Considerations

### Lock-free Structures

- **MPMC Queue**: Based on Vyukov's bounded queue. O(1) push/pop.
- **Work-stealing Deque**: Chase-Lev algorithm. O(1) push/pop, lock-free steal.
- **SPSC Ring**: Wait-free for single producer/consumer pairs.

### Cache Optimization

- Cache-line padding prevents false sharing
- Contiguous memory layouts for cache locality
- Intrusive data structures avoid pointer chasing

### Memory Ordering

- Acquire/Release semantics where possible
- SeqCst only when necessary for correctness
- Explicit ordering in all atomic operations

---

## Comparison

| Feature                | zig-routines | Go  | Tokio (Rust) | Erlang/OTP         |
| ---------------------- | ------------ | --- | ------------ | ------------------ |
| Channels               | ✅           | ✅  | ✅           | ✅ (via processes) |
| Futures                | ✅           | ❌  | ✅           | ❌                 |
| Actors                 | ✅           | ❌  | ✅ (Actix)   | ✅                 |
| Supervision            | ✅           | ❌  | ❌           | ✅                 |
| GenServer              | ✅           | ❌  | ❌           | ✅                 |
| Structured Concurrency | ✅           | ❌  | ✅           | ❌                 |
| Work-stealing          | ✅           | ✅  | ✅           | ✅                 |
| Explicit Allocators    | ✅           | ❌  | ❌           | ❌                 |
| io_uring               | ✅           | ❌  | ✅           | ❌                 |
| No Runtime             | ✅           | ❌  | ❌           | ❌                 |

---

## Requirements

- **Zig**: 0.15.x or later
- **Platforms**: Linux (x86_64, aarch64), macOS (aarch64, x86_64)

---

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass (`zig build test`)
5. Submit a pull request

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

## Acknowledgments

Inspired by:

- Go's goroutines and channels
- Erlang/OTP's actor model and supervision
- Rust's futures and Tokio
- Swift's structured concurrency
- Python Trio's nurseries
- Java's ForkJoinPool

---

<p align="center">
  <strong>Build concurrent systems with confidence.</strong>
</p>
