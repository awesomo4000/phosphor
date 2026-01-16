/// Effect Demo - Demonstrates the new Lustre-style Effect architecture
///
/// This demo shows:
/// - Effect(Msg) for declarative side effects
/// - Repl.handleKeyEffect() returning Effects
/// - Effect.dispatch for message passing
/// - Effect.after for cursor positioning
///
const std = @import("std");
const app = @import("app");
const phosphor = @import("phosphor");

// Re-exports
const Effect = app.Effect;
const Size = app.Size;
const Ui = app.Ui;
const Node = app.Node;
const LayoutNode = app.LayoutNode;
const Key = app.Key;

// Widgets
const Repl = @import("repl").Repl;

// ─────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────

const Model = struct {
    repl: Repl,
    output_lines: std.ArrayList([]const u8),
    size: Size,
    allocator: std.mem.Allocator,

    const welcome_text =
        \\Effect Demo - Type commands and press Enter
        \\Commands: echo <text>, quit
        \\
    ;

    pub fn create(allocator: std.mem.Allocator) !Model {
        var output: std.ArrayList([]const u8) = .{};
        // Static strings don't need freeing
        var iter = std.mem.splitScalar(u8, welcome_text, '\n');
        while (iter.next()) |line| {
            try output.append(allocator, line);
        }

        return .{
            .repl = try Repl.init(allocator, .{ .prompt = "effect> " }),
            .output_lines = output,
            .size = .{ .w = 80, .h = 24 },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Model) void {
        self.repl.deinit();
        // Free dynamically allocated strings (skip static welcome lines)
        // Check pointer location, not content
        const static_start: usize = @intFromPtr(welcome_text.ptr);
        const static_end: usize = static_start + welcome_text.len;
        for (self.output_lines.items) |line| {
            const line_ptr: usize = @intFromPtr(line.ptr);
            const is_static = line_ptr >= static_start and line_ptr < static_end;
            if (!is_static and line.len > 0) {
                self.allocator.free(line);
            }
        }
        self.output_lines.deinit(self.allocator);
    }
};

pub fn init(allocator: std.mem.Allocator) Model {
    return Model.create(allocator) catch @panic("init failed");
}

// ─────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────

const Msg = union(enum) {
    key: Key,
    resize: Size,

    // From Repl widget (via Effect.dispatch)
    got_submit: []const u8,
    got_cancel,
    got_eof,
};

// Repl message configuration - maps Repl events to our Msg type
const repl_config = Repl.MsgConfig(Msg){
    .on_submit = struct {
        fn f(text: []const u8) Msg {
            return .{ .got_submit = text };
        }
    }.f,
    .on_cancel = .got_cancel,
    .on_eof = .got_eof,
};

// ─────────────────────────────────────────────────────────────
// Update - returns Effect(Msg)
// ─────────────────────────────────────────────────────────────

pub fn update(model: *Model, msg: Msg, _: std.mem.Allocator) app.Cmd {
    // For now, we still return Cmd for compatibility
    // The Effect flow is demonstrated within key handling

    switch (msg) {
        .resize => |new_size| {
            model.size = new_size;
        },
        .key => |key| {
            // Use the new Effect-based API
            const effect = model.repl.handleKeyEffect(key, Msg, repl_config) catch return .none;

            // Process the effect manually for now (until runtime is updated)
            return processEffectToCmd(effect, model);
        },
        .got_submit => |text| {
            return handleCommand(model, text);
        },
        .got_cancel => {
            const cancel_line = model.allocator.dupe(u8, "^C") catch return .none;
            model.output_lines.append(model.allocator, cancel_line) catch {};
        },
        .got_eof => {
            return .quit;
        },
    }

    return .none;
}

/// Temporary: Convert Effect to Cmd until runtime is updated
fn processEffectToCmd(effect: Effect(Msg), model: *Model) app.Cmd {
    switch (effect) {
        .none => return .none,
        .quit => return .quit,
        .dispatch => |msg| {
            // Recursively handle dispatched message
            return update(model, msg, model.allocator);
        },
        .after => {
            // After-paint effects are ignored for now
            // (cursor positioning handled by view's layoutWithCursor)
            return .none;
        },
        .batch => |effects| {
            for (effects) |e| {
                const result = processEffectToCmd(e, model);
                if (result == .quit) return .quit;
            }
            return .none;
        },
    }
}

fn handleCommand(model: *Model, text: []const u8) app.Cmd {
    const trimmed = std.mem.trim(u8, text, " \t\n\r");

    // Echo the command
    const prompt_line = std.fmt.allocPrint(model.allocator, "effect> {s}", .{trimmed}) catch return .none;
    model.output_lines.append(model.allocator, prompt_line) catch {};

    if (std.mem.startsWith(u8, trimmed, "echo ")) {
        const echo_text = trimmed[5..];
        const echo_line = std.fmt.allocPrint(model.allocator, "  {s}", .{echo_text}) catch return .none;
        model.output_lines.append(model.allocator, echo_line) catch {};
    } else if (std.mem.eql(u8, trimmed, "quit")) {
        return .quit;
    } else if (trimmed.len > 0) {
        const err_line = std.fmt.allocPrint(model.allocator, "Unknown: {s}", .{trimmed}) catch return .none;
        model.output_lines.append(model.allocator, err_line) catch {};
    }
    return .none;
}

// ─────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────

pub fn view(model: *Model, ui: *Ui) *Node {
    const cols: u16 = @intCast(model.size.w);
    const rows: u16 = @intCast(model.size.h);

    // Build output lines as layout nodes
    const max_output_lines = rows -| 3; // Leave room for header + repl
    const start_idx = if (model.output_lines.items.len > max_output_lines)
        model.output_lines.items.len - max_output_lines
    else
        0;
    const visible_lines = model.output_lines.items[start_idx..];

    // Create children array: header + spacer + output lines + repl
    var children = ui.ally.alloc(LayoutNode, visible_lines.len + 3) catch @panic("OOM");

    // Header
    children[0] = ui.ltext("Effect Demo (Effect-based architecture)");

    // Separator
    children[1] = ui.separator(cols);

    // Output lines
    for (visible_lines, 0..) |line, i| {
        children[i + 2] = ui.ltext(line);
    }

    // Render Repl through layout system - this enables Effect.after.set_cursor
    // The layout system will track the Repl's position via widget_positions,
    // allowing the runtime to resolve cursor coordinates automatically.
    children[children.len - 1] = ui.widget(&model.repl);

    // Build layout tree
    const root = ui.ally.create(LayoutNode) catch @panic("OOM");
    root.* = ui.vbox(children);

    // For now, still use layoutWithCursor for explicit cursor position.
    // When the runtime fully supports Effect.after.set_cursor, we can
    // use plain ui.layout(root) and let the runtime resolve cursor from
    // widget_positions + Effect.setCursor(&model.repl, local_x, local_y).
    const cursor_x = model.repl.getCursorPosition().x;
    const repl_row: u16 = 2 + @as(u16, @intCast(visible_lines.len));

    return ui.layoutWithCursor(root, cursor_x, repl_row);
}

// ─────────────────────────────────────────────────────────────
// Subscriptions
// ─────────────────────────────────────────────────────────────

pub fn subs(_: *Model) app.Subs {
    return .{
        .keyboard = true,
    };
}

// ─────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    try app.App(@This()).run(gpa.allocator(), .{
        .backend = .thermite,
        .target_fps = 30,
    });
}
