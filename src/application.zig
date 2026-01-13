const std = @import("std");
const Allocator = std.mem.Allocator;
const backend_mod = @import("backend.zig");
const Backend = backend_mod.Backend;
const Event = backend_mod.Event;
const Key = backend_mod.Key;
const Size = backend_mod.Size;
const ThermiteBackend = backend_mod.ThermiteBackend;
const DrawCommand = @import("render_commands.zig").DrawCommand;
const layout = @import("layout.zig");
const LayoutNode = layout.LayoutNode;
const Rect = layout.Rect;
const renderTree = layout.renderTree;

/// Subscription types - what events a widget/app wants
pub const Sub = union(enum) {
    keyboard, // Want key events
    focus, // Want focus_gained/focus_lost
    tick_ms: u32, // Want tick events at interval
    paste, // Want paste_start/paste_end
    resize, // Want resize events
};

/// Elm-style application
///
/// Usage:
/// ```
/// const MyApp = Application(Model, Msg){
///     .init = myInit,
///     .update = myUpdate,
///     .view = myView,
///     .subscriptions = mySubs,
/// };
///
/// pub fn main() !void {
///     try MyApp.run(allocator);
/// }
/// ```
pub fn Application(comptime Model: type, comptime Msg: type) type {
    return struct {
        const Self = @This();

        /// Initialize the model
        init: *const fn (allocator: Allocator, size: Size) anyerror!Model,

        /// Update model based on message, return command
        update: *const fn (model: *Model, msg: Msg) anyerror!Cmd,

        /// Render model to layout tree
        view: *const fn (model: *const Model, allocator: Allocator) anyerror!LayoutNode,

        /// Declare what events the app wants (can delegate to widgets)
        subscriptions: *const fn (model: *const Model) []const Sub,

        /// Optional: cleanup
        deinit: ?*const fn (model: *Model) void = null,

        /// Commands that can be returned from update
        pub const Cmd = union(enum) {
            none,
            quit,
            batch: []const Cmd,
            // Future: custom effects
        };

        /// Run the application
        pub fn run(self: Self, allocator: Allocator) !void {
            // Initialize backend
            var thermite = try ThermiteBackend.init(allocator);
            defer thermite.deinit();
            const be = thermite.backend();

            // Initialize model
            var model = try self.init(allocator, be.getSize());
            defer if (self.deinit) |deinitFn| deinitFn(&model);

            // Initial render
            try self.render(&model, be, allocator);

            // Event loop
            var running = true;
            while (running) {
                const maybe_event = try be.readEvent();
                if (maybe_event == null) continue;
                const event = maybe_event.?;

                // Handle resize at backend level
                if (event == .resize) {
                    try thermite.resize(.{ .cols = event.resize.cols, .rows = event.resize.rows });
                }

                // Check if this event matches any subscription
                const subs = self.subscriptions(&model);
                if (eventMatchesSubs(event, subs)) {
                    // Convert to message and send to update
                    if (eventToMsg(Msg, event)) |msg| {
                        const cmd = try self.update(&model, msg);
                        running = !self.processCmd(cmd);
                    }
                }

                // Re-render
                if (running) {
                    try self.render(&model, be, allocator);
                }
            }
        }

        /// Process a command, returns true if should quit
        fn processCmd(self: Self, cmd: Cmd) bool {
            return switch (cmd) {
                .none => false,
                .quit => true,
                .batch => |cmds| {
                    for (cmds) |c| {
                        if (self.processCmd(c)) return true;
                    }
                    return false;
                },
            };
        }

        /// Render the current model state
        fn render(self: Self, model: *const Model, be: Backend, allocator: Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const frame_alloc = arena.allocator();

            const root = try self.view(model, frame_alloc);
            const size = be.getSize();
            const bounds = Rect{ .x = 0, .y = 0, .w = size.cols, .h = size.rows };

            var commands: std.ArrayListUnmanaged(DrawCommand) = .{};
            try commands.append(frame_alloc, .clear_screen);

            const tree_commands = try renderTree(&root, bounds, frame_alloc);
            try commands.appendSlice(frame_alloc, tree_commands);

            try commands.append(frame_alloc, .{ .show_cursor = .{ .visible = true } });
            try commands.append(frame_alloc, .flush);

            be.execute(commands.items);
        }
    };
}

/// Check if an event matches any subscription
fn eventMatchesSubs(event: Event, subs: []const Sub) bool {
    for (subs) |sub| {
        const matches = switch (sub) {
            .keyboard => event == .key,
            .paste => event == .paste_start or event == .paste_end,
            .resize => event == .resize,
            .tick_ms => event == .tick,
            .focus => false, // TODO
        };
        if (matches) return true;
    }
    return false;
}

/// Convert event to message type
/// App's Msg type should have fields matching event types
fn eventToMsg(comptime Msg: type, event: Event) ?Msg {
    return switch (event) {
        .key => |k| if (@hasField(Msg, "key")) @unionInit(Msg, "key", k) else null,
        .resize => |s| if (@hasField(Msg, "resize")) @unionInit(Msg, "resize", s) else null,
        .paste_start => if (@hasField(Msg, "paste_start")) .paste_start else null,
        .paste_end => if (@hasField(Msg, "paste_end")) .paste_end else null,
        .tick => if (@hasField(Msg, "tick")) .tick else null,
        .none => null,
    };
}

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

test "eventMatchesSubs" {
    const subs = &[_]Sub{ .keyboard, .resize };

    try std.testing.expect(eventMatchesSubs(.{ .key = .enter }, subs));
    try std.testing.expect(eventMatchesSubs(.{ .resize = .{ .cols = 80, .rows = 24 } }, subs));
    try std.testing.expect(!eventMatchesSubs(.paste_start, subs));
}
