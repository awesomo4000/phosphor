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

// Re-exports
const Effect = app.Effect;
const Size = app.Size;
const Ui = app.Ui;
const Node = app.Node;
const LayoutNode = app.LayoutNode;
const Key = app.Key;

// Widgets
const Repl = @import("repl").Repl;
const LogView = @import("logview").LogView;

// ─────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────

const Model = struct {
    repl: Repl,
    log: LogView,
    size: Size,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator) !Model {
        var log = LogView.init(allocator, 1000);
        log.append("Effect Demo - Type commands and press Enter") catch {};
        log.append("Commands: echo <text>, quit") catch {};
        log.append("") catch {};

        return .{
            .repl = try Repl.init(allocator, .{ .prompt = "effect> " }),
            .log = log,
            .size = .{ .w = 80, .h = 24 },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Model) void {
        self.repl.deinit();
        self.log.deinit();
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
            model.log.append("^C") catch {};
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
    model.log.print("effect> {s}", .{trimmed}) catch {};

    if (std.mem.startsWith(u8, trimmed, "echo ")) {
        const echo_text = trimmed[5..];
        model.log.print("  {s}", .{echo_text}) catch {};
    } else if (std.mem.eql(u8, trimmed, "quit")) {
        return .quit;
    } else if (trimmed.len > 0) {
        model.log.print("Unknown: {s}", .{trimmed}) catch {};
    }
    return .none;
}

// ─────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────

pub fn view(model: *Model, ui: *Ui) *Node {
    // Build the layout tree - widgets get their size from the layout system
    const root = ui.ally.create(LayoutNode) catch @panic("OOM");
    root.* = ui.vbox(.{
        ui.ltext("Effect Demo (Effect-based architecture)"),
        ui.separator(),
        ui.widgetGrow(&model.log),   // LogView grows to fill
        ui.widget(&model.repl),       // Repl uses preferred height
    });

    return ui.layout(root);
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
