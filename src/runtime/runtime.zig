const std = @import("std");
const Allocator = std.mem.Allocator;
const Queue = @import("queue.zig").Queue;
const input_mod = @import("input.zig");
const InputSource = input_mod.InputSource;
const TerminalInput = input_mod.TerminalInput;
pub const Key = input_mod.Key;

/// Read-only context passed to update() - snapshot of world state
pub const Context = struct {
    /// Timestamp when this update started (milliseconds since epoch)
    time_ms: i64,
    /// Frame number (monotonically increasing)
    frame: u64,
    /// Terminal size in cells
    size: Size,
};

pub const Size = struct {
    w: u32,
    h: u32,
};

/// Runtime configuration
pub const Config = struct {
    /// Target frames per second (0 = unlimited)
    target_fps: u32 = 60,
    /// Run in headless mode (no real terminal) - for testing
    headless: bool = false,
    /// Initial terminal size (used in headless mode)
    initial_size: Size = .{ .w = 80, .h = 24 },
};

/// Time source - can be real or mocked for testing
pub const TimeSource = union(enum) {
    real,
    mocked: struct {
        current_ms: i64 = 0,
    },

    pub fn now(self: *TimeSource) i64 {
        return switch (self.*) {
            .real => std.time.milliTimestamp(),
            .mocked => |m| m.current_ms,
        };
    }

    pub fn advance(self: *TimeSource, ms: i64) void {
        switch (self.*) {
            .real => {}, // Can't advance real time
            .mocked => |*m| m.current_ms += ms,
        }
    }

    pub fn set(self: *TimeSource, ms: i64) void {
        switch (self.*) {
            .real => {}, // Can't set real time
            .mocked => |*m| m.current_ms = ms,
        }
    }
};

/// The runtime - manages queue, threads, and main loop
///
/// Type parameters:
/// - Msg: The application's message type (must have .key: Key field for keyboard input)
pub fn Runtime(comptime Msg: type) type {
    // Check if Msg has a .key field that takes Key
    const has_key_field = @hasField(Msg, "key");

    return struct {
        const Self = @This();

        allocator: Allocator,
        queue: Queue(Msg),
        config: Config,
        time: TimeSource,
        frame: u64 = 0,
        size: Size,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        // Input source (null in headless mode until started)
        input: ?InputSource = null,

        // Thread handle (null in headless mode)
        input_thread: ?std.Thread = null,

        pub fn init(allocator: Allocator, config: Config) Self {
            return .{
                .allocator = allocator,
                .queue = Queue(Msg).init(allocator),
                .config = config,
                .time = if (config.headless) .{ .mocked = .{} } else .real,
                .size = config.initial_size,
            };
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            self.queue.deinit();
            if (self.input) |*inp| {
                inp.deinit();
            }
        }

        /// Get current context snapshot
        pub fn context(self: *Self) Context {
            return .{
                .time_ms = self.time.now(),
                .frame = self.frame,
                .size = self.size,
            };
        }

        /// Push a message to the queue (thread-safe)
        pub fn send(self: *Self, msg: Msg) void {
            self.queue.push(msg);
        }

        /// Push multiple messages (useful for test injection)
        pub fn sendAll(self: *Self, msgs: []const Msg) void {
            self.queue.pushSlice(msgs);
        }

        /// Drain all pending messages
        pub fn drainMessages(self: *Self, out: []Msg) []Msg {
            return self.queue.drain(out);
        }

        /// Check if there are pending messages
        pub fn hasPendingMessages(self: *Self) bool {
            return !self.queue.isEmpty();
        }

        /// Advance time (only works with mocked time)
        pub fn advanceTime(self: *Self, ms: i64) void {
            self.time.advance(ms);
        }

        /// Set time (only works with mocked time)
        pub fn setTime(self: *Self, ms: i64) void {
            self.time.set(ms);
        }

        /// Advance to next frame
        pub fn nextFrame(self: *Self) void {
            self.frame += 1;
        }

        /// Resize terminal
        pub fn resize(self: *Self, new_size: Size) void {
            self.size = new_size;
        }

        /// Check if running
        pub fn isRunning(self: *Self) bool {
            return self.running.load(.acquire);
        }

        /// Stop the runtime
        pub fn stop(self: *Self) void {
            self.running.store(false, .release);

            // Wait for input thread if running
            if (self.input_thread) |thread| {
                thread.join();
                self.input_thread = null;
            }
        }

        /// Start the input thread (call before run loop)
        pub fn start(self: *Self) !void {
            self.running.store(true, .release);

            if (!self.config.headless) {
                // Initialize terminal input
                self.input = .{ .terminal = try TerminalInput.init() };

                // Start input thread
                self.input_thread = try std.Thread.spawn(.{}, inputThreadFn, .{self});
            }
        }

        /// Run the main loop with user-provided functions
        /// This is the core runtime loop: drain → update → view → render
        pub fn run(
            self: *Self,
            model: anytype,
            comptime UpdateFn: fn (*@TypeOf(model.*), Msg, Context) Effect,
            comptime ViewFn: fn (*@TypeOf(model.*)) ViewResult,
        ) !void {
            try self.start();
            defer self.stop();

            var msg_buf: [256]Msg = undefined;

            while (self.isRunning()) {
                const ctx = self.context();

                // Drain and process messages
                const messages = self.drainMessages(&msg_buf);
                for (messages) |msg| {
                    const effect = UpdateFn(model, msg, ctx);
                    try self.processEffect(effect);
                }

                // Render
                const view_result = ViewFn(model);
                _ = view_result; // TODO: actually render

                self.nextFrame();

                // Frame pacing
                if (self.config.target_fps > 0) {
                    const frame_time_ms: i64 = @divFloor(1000, self.config.target_fps);
                    const elapsed = self.time.now() - ctx.time_ms;
                    if (elapsed < frame_time_ms) {
                        std.Thread.sleep(@intCast((frame_time_ms - elapsed) * std.time.ns_per_ms));
                    }
                }
            }
        }

        /// Run a single step of the runtime (for testing)
        /// Returns true if should continue, false if quit
        pub fn step(
            self: *Self,
            model: anytype,
            comptime UpdateFn: fn (*@TypeOf(model.*), Msg, Context) Effect,
        ) !bool {
            const ctx = self.context();

            var msg_buf: [256]Msg = undefined;
            const messages = self.drainMessages(&msg_buf);

            for (messages) |msg| {
                const effect = UpdateFn(model, msg, ctx);
                if (effect == .quit) return false;
                try self.processEffect(effect);
            }

            self.nextFrame();
            return true;
        }

        fn processEffect(self: *Self, effect: Effect) !void {
            switch (effect) {
                .none => {},
                .quit => self.running.store(false, .release),
                .batch => |effects| {
                    for (effects) |e| {
                        try self.processEffect(e);
                    }
                },
                // TODO: handle more effects
            }
        }

        fn inputThreadFn(self: *Self) void {
            while (self.isRunning()) {
                if (self.input) |*inp| {
                    // Poll with short timeout so we can check running flag
                    const poll_result = inp.poll(50) catch .timeout;

                    switch (poll_result) {
                        .ready => {
                            if (inp.readKey()) |key| {
                                // Convert key to message if Msg has .key field
                                if (has_key_field) {
                                    self.send(@unionInit(Msg, "key", key));
                                }
                            }
                        },
                        .resize => {
                            // TODO: get new size and send resize message
                            if (@hasField(Msg, "resize")) {
                                // Would need to query terminal size here
                            }
                        },
                        .timeout => {},
                    }
                } else {
                    // Headless mode - just sleep
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                }
            }
        }
    };
}

/// Effect type - declarative side effects returned from update
pub const Effect = union(enum) {
    none,
    quit,
    batch: []const Effect,
    // TODO: More effects
    // dispatch: Msg,  -- needs to be parameterized
    // get_time: fn(i64) Msg,
    // set_timer: struct { ms: u64, msg: Msg },
};

/// Placeholder for view result
pub const ViewResult = struct {
    // TODO: actual view result type
};

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

test "Runtime: basic initialization" {
    const TestMsg = union(enum) {
        tick,
        key: Key,
    };

    var rt = Runtime(TestMsg).init(std.testing.allocator, .{ .headless = true });
    defer rt.deinit();

    try std.testing.expectEqual(@as(u64, 0), rt.frame);
    try std.testing.expectEqual(@as(u32, 80), rt.size.w);
}

test "Runtime: message injection and drain" {
    const TestMsg = union(enum) {
        tick,
        key: Key,
    };

    var rt = Runtime(TestMsg).init(std.testing.allocator, .{ .headless = true });
    defer rt.deinit();

    rt.send(.tick);
    rt.send(.{ .key = .enter });
    rt.sendAll(&[_]TestMsg{ .{ .key = .tab }, .{ .key = .escape } });

    try std.testing.expectEqual(@as(usize, 4), rt.queue.len());

    var buf: [10]TestMsg = undefined;
    const msgs = rt.drainMessages(&buf);

    try std.testing.expectEqual(@as(usize, 4), msgs.len);
    try std.testing.expectEqual(TestMsg.tick, msgs[0]);
    try std.testing.expectEqual(Key.enter, msgs[1].key);
}

test "Runtime: mocked time" {
    const TestMsg = union(enum) { tick };

    var rt = Runtime(TestMsg).init(std.testing.allocator, .{ .headless = true });
    defer rt.deinit();

    rt.setTime(1000);
    try std.testing.expectEqual(@as(i64, 1000), rt.context().time_ms);

    rt.advanceTime(500);
    try std.testing.expectEqual(@as(i64, 1500), rt.context().time_ms);
}

test "Runtime: step execution" {
    const TestMsg = union(enum) {
        increment,
        quit,
    };

    const Model = struct {
        count: u32 = 0,
    };

    var rt = Runtime(TestMsg).init(std.testing.allocator, .{ .headless = true });
    defer rt.deinit();

    var model = Model{};

    const updateFn = struct {
        fn update(m: *Model, msg: TestMsg, _: Context) Effect {
            switch (msg) {
                .increment => m.count += 1,
                .quit => return .quit,
            }
            return .none;
        }
    }.update;

    // Inject messages
    rt.send(.increment);
    rt.send(.increment);
    rt.send(.increment);

    // Step through them
    const should_continue = try rt.step(&model, updateFn);

    try std.testing.expect(should_continue);
    try std.testing.expectEqual(@as(u32, 3), model.count);
    try std.testing.expectEqual(@as(u64, 1), rt.frame);

    // Test quit
    rt.send(.quit);
    const should_quit = try rt.step(&model, updateFn);
    try std.testing.expect(!should_quit);
}

test "Runtime: context snapshot" {
    const TestMsg = union(enum) { tick };

    var rt = Runtime(TestMsg).init(std.testing.allocator, .{
        .headless = true,
        .initial_size = .{ .w = 120, .h = 40 },
    });
    defer rt.deinit();

    rt.setTime(5000);
    rt.frame = 42;

    const ctx = rt.context();
    try std.testing.expectEqual(@as(i64, 5000), ctx.time_ms);
    try std.testing.expectEqual(@as(u64, 42), ctx.frame);
    try std.testing.expectEqual(@as(u32, 120), ctx.size.w);
    try std.testing.expectEqual(@as(u32, 40), ctx.size.h);
}
