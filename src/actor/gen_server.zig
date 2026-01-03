//! GenServer behavior for request-response actors.
//!
//! GenServer provides a standardized way to implement servers that handle
//! both synchronous calls (request-response) and asynchronous casts.
//! Inspired by Erlang/OTP's gen_server behavior.
//!
//! ## Callbacks
//!
//! - `init`: Initialize server state
//! - `handleCall`: Handle synchronous requests
//! - `handleCast`: Handle asynchronous messages
//! - `handleInfo`: Handle other messages
//! - `terminate`: Cleanup before shutdown
//!
//! ## Example
//!
//! ```zig
//! const CounterServer = GenServer(
//!     u32,        // Call request type
//!     u32,        // Call response type
//!     void,       // Cast type
//!     u32,        // State type
//!     struct {
//!         pub fn init() u32 {
//!             return 0;
//!         }
//!
//!         pub fn handleCall(state: *u32, request: u32) u32 {
//!             state.* += request;
//!             return state.*;
//!         }
//!     },
//! );
//!
//! var server = try CounterServer.start(allocator);
//! const result = try server.call(5);
//! ```

const std = @import("std");
const atomic = @import("../core/atomic.zig");
const Mailbox = @import("mailbox.zig").Mailbox;
const Allocator = std.mem.Allocator;

/// GenServer reply directive.
pub fn Reply(comptime T: type) type {
    return struct {
        value: T,
        new_state_action: StateAction = .keep,

        pub fn reply(value: T) @This() {
            return .{ .value = value };
        }

        pub fn replyAndStop(value: T) @This() {
            return .{ .value = value, .new_state_action = .stop };
        }
    };
}

/// State action after handling a message.
pub const StateAction = enum {
    keep,
    stop,
    hibernate,
};

/// Cast result.
pub const CastResult = struct {
    action: StateAction = .keep,

    pub fn noreply() CastResult {
        return .{};
    }

    pub fn stop() CastResult {
        return .{ .action = .stop };
    }
};

/// GenServer state.
pub const GenServerState = enum(u8) {
    starting = 0,
    running = 1,
    hibernating = 2,
    stopping = 3,
    stopped = 4,
};

/// GenServer implementation.
pub fn GenServer(
    comptime CallRequest: type,
    comptime CallResponse: type,
    comptime CastMessage: type,
    comptime State: type,
    comptime Callbacks: type,
) type {
    return struct {
        const Self = @This();

        /// Message types.
        const Message = union(enum) {
            call: CallEnvelope,
            cast: CastMessage,
            stop: void,
        };

        const CallEnvelope = struct {
            request: CallRequest,
            reply_to: *?CallResponse,
            done: *std.Thread.ResetEvent,
        };

        /// Server state.
        state: State,

        /// Lifecycle state.
        lifecycle: atomic.Atomic(GenServerState),

        /// Message mailbox.
        mailbox: *Mailbox(Message),

        /// Processing thread.
        thread: ?std.Thread,

        /// Allocator.
        allocator: Allocator,

        /// Start the server.
        pub fn start(allocator: Allocator) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.mailbox = try Mailbox(Message).init(allocator, .{});
            errdefer self.mailbox.deinit();

            // Initialize state
            if (@hasDecl(Callbacks, "init")) {
                self.state = Callbacks.init();
            } else {
                self.state = undefined;
            }

            self.lifecycle = atomic.Atomic(GenServerState).init(.starting);
            self.allocator = allocator;

            // Start processing thread
            self.thread = try std.Thread.spawn(.{}, processLoop, .{self});

            return self;
        }

        /// Start with initial state.
        pub fn startWithState(allocator: Allocator, initial_state: State) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.mailbox = try Mailbox(Message).init(allocator, .{});
            errdefer self.mailbox.deinit();

            self.state = initial_state;
            self.lifecycle = atomic.Atomic(GenServerState).init(.starting);
            self.allocator = allocator;

            self.thread = try std.Thread.spawn(.{}, processLoop, .{self});

            return self;
        }

        /// Stop the server.
        pub fn stop(self: *Self) void {
            self.lifecycle.store(.stopping);
            self.mailbox.send(.stop) catch {};
            self.mailbox.close();

            if (self.thread) |t| {
                t.join();
            }

            // Call terminate callback
            if (@hasDecl(Callbacks, "terminate")) {
                Callbacks.terminate(&self.state);
            }

            self.mailbox.deinit();
            self.allocator.destroy(self);
        }

        /// Synchronous call - waits for response.
        pub fn call(self: *Self, request: CallRequest) !CallResponse {
            return self.callTimeout(request, 5_000_000_000); // 5s default timeout
        }

        /// Synchronous call with timeout.
        pub fn callTimeout(self: *Self, request: CallRequest, timeout_ns: u64) !CallResponse {
            if (self.lifecycle.load() != .running) {
                return error.ServerNotRunning;
            }

            var response: ?CallResponse = null;
            var done: std.Thread.ResetEvent = .{};

            try self.mailbox.send(.{
                .call = .{
                    .request = request,
                    .reply_to = &response,
                    .done = &done,
                },
            });

            // Wait for response with timeout
            done.timedWait(timeout_ns) catch {
                return error.Timeout;
            };

            return response orelse error.NoResponse;
        }

        /// Asynchronous cast - fire and forget.
        pub fn cast(self: *Self, message: CastMessage) !void {
            if (self.lifecycle.load() != .running) {
                return error.ServerNotRunning;
            }

            try self.mailbox.send(.{ .cast = message });
        }

        /// Check if server is running.
        pub fn isRunning(self: *const Self) bool {
            return self.lifecycle.load() == .running;
        }

        /// Get current state.
        pub fn getState(self: *const Self) GenServerState {
            return self.lifecycle.load();
        }

        /// Processing loop.
        fn processLoop(self: *Self) void {
            self.lifecycle.store(.running);

            while (self.lifecycle.load() == .running or
                self.lifecycle.load() == .hibernating)
            {
                if (self.mailbox.receive()) |msg| {
                    const action = self.handleMessage(msg);

                    switch (action) {
                        .keep => {},
                        .stop => {
                            self.lifecycle.store(.stopping);
                            break;
                        },
                        .hibernate => {
                            self.lifecycle.store(.hibernating);
                        },
                    }
                } else {
                    // No messages, sleep briefly
                    if (self.lifecycle.load() == .hibernating) {
                        std.Thread.sleep(10_000_000); // 10ms when hibernating
                    } else {
                        std.Thread.sleep(100_000); // 100us normally
                    }
                }
            }

            self.lifecycle.store(.stopped);
        }

        fn handleMessage(self: *Self, msg: Message) StateAction {
            switch (msg) {
                .call => |envelope| {
                    if (@hasDecl(Callbacks, "handleCall")) {
                        const reply_result = Callbacks.handleCall(&self.state, envelope.request);

                        if (@TypeOf(reply_result) == Reply(CallResponse)) {
                            envelope.reply_to.* = reply_result.value;
                            envelope.done.set();
                            return reply_result.new_state_action;
                        } else {
                            envelope.reply_to.* = reply_result;
                            envelope.done.set();
                        }
                    } else {
                        envelope.done.set();
                    }
                    return .keep;
                },
                .cast => |cast_msg| {
                    if (@hasDecl(Callbacks, "handleCast")) {
                        const result = Callbacks.handleCast(&self.state, cast_msg);
                        return result.action;
                    }
                    return .keep;
                },
                .stop => {
                    return .stop;
                },
            }
        }
    };
}

/// Simple counter server example.
pub const CounterServer = GenServer(
    i32, // Call: increment by value
    i32, // Response: new count
    void, // Cast: unused
    i32, // State: counter
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

/// Key-value store server example.
pub fn KVServer(comptime K: type, comptime V: type) type {
    const Request = union(enum) {
        get: K,
        put: struct { key: K, value: V },
        delete: K,
    };

    const Response = union(enum) {
        value: ?V,
        ok: void,
    };

    return GenServer(
        Request,
        Response,
        void,
        std.AutoHashMap(K, V),
        struct {
            pub fn handleCall(state: *std.AutoHashMap(K, V), request: Request) Response {
                switch (request) {
                    .get => |key| {
                        return .{ .value = state.get(key) };
                    },
                    .put => |kv| {
                        state.put(kv.key, kv.value) catch {};
                        return .{ .ok = {} };
                    },
                    .delete => |key| {
                        _ = state.remove(key);
                        return .{ .ok = {} };
                    },
                }
            }
        },
    );
}

// ============================================================================
// Tests
// ============================================================================

test "GenServer start and stop" {
    var server = try CounterServer.start(std.testing.allocator);
    defer server.stop();

    // Give time for thread to start
    std.Thread.sleep(1_000_000); // 1ms

    try std.testing.expect(server.isRunning());
}

test "GenServer call" {
    var server = try CounterServer.start(std.testing.allocator);
    defer server.stop();

    // Give time to start
    std.Thread.sleep(1_000_000);

    const result = try server.call(5);
    try std.testing.expectEqual(@as(i32, 5), result);

    const result2 = try server.call(10);
    try std.testing.expectEqual(@as(i32, 15), result2);
}

test "GenServer state" {
    var server = try CounterServer.start(std.testing.allocator);
    defer server.stop();

    std.Thread.sleep(1_000_000);
    try std.testing.expectEqual(GenServerState.running, server.getState());
}

test "Reply type" {
    const reply = Reply(u32).reply(42);
    try std.testing.expectEqual(@as(u32, 42), reply.value);
    try std.testing.expectEqual(StateAction.keep, reply.new_state_action);

    const stop_reply = Reply(u32).replyAndStop(99);
    try std.testing.expectEqual(StateAction.stop, stop_reply.new_state_action);
}

test "CastResult" {
    const noreply = CastResult.noreply();
    try std.testing.expectEqual(StateAction.keep, noreply.action);

    const stop_result = CastResult.stop();
    try std.testing.expectEqual(StateAction.stop, stop_result.action);
}
