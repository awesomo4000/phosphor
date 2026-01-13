const std = @import("std");
const backend = @import("backend.zig");
const render_commands = @import("render_commands.zig");

pub const Backend = backend.Backend;
pub const Event = backend.Event;
pub const Key = backend.Key;
pub const Size = backend.Size;
pub const DrawCommand = render_commands.DrawCommand;

/// Generic widget interface for the Runtime
/// Widgets implement update() and view() to participate in the event loop
pub fn Widget(comptime State: type, comptime Msg: type) type {
    return struct {
        /// Parse an event into a message for this widget
        parse: *const fn (event: Event) ?Msg,

        /// Update state based on a message (returns false to quit)
        update: *const fn (state: *State, msg: Msg) bool,

        /// Generate draw commands from current state
        view: *const fn (state: *const State, allocator: std.mem.Allocator) anyerror![]DrawCommand,
    };
}

/// Runtime for executing Phosphor applications with Backend abstraction
pub fn Runtime(comptime State: type, comptime Msg: type) type {
    return struct {
        const Self = @This();

        backend_impl: Backend,
        state: State,
        widget: Widget(State, Msg),
        allocator: std.mem.Allocator,
        running: bool = true,

        pub fn init(
            allocator: std.mem.Allocator,
            backend_impl: Backend,
            initial_state: State,
            widget: Widget(State, Msg),
        ) Self {
            return .{
                .allocator = allocator,
                .backend_impl = backend_impl,
                .state = initial_state,
                .widget = widget,
            };
        }

        /// Run the event loop
        pub fn run(self: *Self) !void {
            // Initial render
            try self.render();

            while (self.running) {
                // Read event from backend
                const event_opt = try self.backend_impl.readEvent();

                if (event_opt) |event| {
                    // Parse event to widget message
                    if (self.widget.parse(event)) |msg| {
                        // Update state
                        if (!self.widget.update(&self.state, msg)) {
                            self.running = false;
                            break;
                        }

                        // Re-render
                        try self.render();
                    }
                }
            }
        }

        /// Single step for testing - process one event
        pub fn step(self: *Self) !bool {
            const event_opt = try self.backend_impl.readEvent();

            if (event_opt) |event| {
                if (self.widget.parse(event)) |msg| {
                    if (!self.widget.update(&self.state, msg)) {
                        self.running = false;
                        return false;
                    }
                    try self.render();
                }
            }

            return self.running;
        }

        /// Render current state
        fn render(self: *Self) !void {
            // Get draw commands from widget
            const commands = try self.widget.view(&self.state, self.allocator);
            defer self.allocator.free(commands);

            // Execute commands via backend
            self.backend_impl.execute(commands);
        }

        /// Get current terminal size
        pub fn getSize(self: *const Self) Size {
            return self.backend_impl.getSize();
        }
    };
}

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

test "Runtime basic operation" {
    const TestState = struct {
        counter: i32 = 0,
    };

    const TestMsg = enum {
        increment,
        quit,
    };

    const test_widget = Widget(TestState, TestMsg){
        .parse = struct {
            fn parse(event: Event) ?TestMsg {
                if (event == .key) {
                    if (event.key == .enter) return .increment;
                    if (event.key == .ctrl_d) return .quit;
                }
                return null;
            }
        }.parse,

        .update = struct {
            fn update(state: *TestState, msg: TestMsg) bool {
                switch (msg) {
                    .increment => state.counter += 1,
                    .quit => return false,
                }
                return true;
            }
        }.update,

        .view = struct {
            fn view(state: *const TestState, allocator: std.mem.Allocator) ![]DrawCommand {
                var commands: std.ArrayListUnmanaged(DrawCommand) = .{};

                try commands.append(allocator, .clear_screen);
                try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = 0 } });

                // Format counter into a buffer that lives long enough
                var buf: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "Count: {d}", .{state.counter}) catch "Count: ?";
                _ = text;

                try commands.append(allocator, .{ .draw_text = .{ .text = "Counter" } });
                try commands.append(allocator, .flush);

                return commands.toOwnedSlice(allocator);
            }
        }.view,
    };

    var mem_backend = try backend.MemoryBackend.init(std.testing.allocator, 40, 10);
    defer mem_backend.deinit();

    // Inject test events
    try mem_backend.injectEvent(.{ .key = .enter });
    try mem_backend.injectEvent(.{ .key = .enter });
    try mem_backend.injectEvent(.{ .key = .ctrl_d });

    var runtime = Runtime(TestState, TestMsg).init(
        std.testing.allocator,
        mem_backend.backend(),
        .{},
        test_widget,
    );

    // Step through events
    _ = try runtime.step(); // enter -> increment
    try std.testing.expectEqual(@as(i32, 1), runtime.state.counter);

    _ = try runtime.step(); // enter -> increment
    try std.testing.expectEqual(@as(i32, 2), runtime.state.counter);

    const continued = try runtime.step(); // ctrl_d -> quit
    try std.testing.expect(!continued);
}
