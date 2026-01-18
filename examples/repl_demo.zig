const std = @import("std");
const app = @import("app");

const Cmd = app.Cmd;
const Effect = app.Effect;
const Size = app.Size;
const Ui = app.Ui;
const Node = app.Node;
const Key = app.Key;
const LayoutNode = app.LayoutNode;

// Widgets
const Repl = @import("repl").Repl;
const LogView = @import("logview").LogView;
const KeyTester = @import("keytester").KeyTester;

// ─────────────────────────────────────────────────────────────
// Model - all application state in one place
// ─────────────────────────────────────────────────────────────

const Model = struct {
    log: LogView,
    repl: Repl,
    keytester: KeyTester,
    size: Size,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator) Model {
        var log = LogView.init(allocator, 1000);

        const repl = Repl.init(allocator, .{ .prompt = "p> " }) catch {
            log.deinit();
            @panic("Failed to init Repl");
        };

        const keytester = KeyTester.init(allocator);

        // Welcome messages
        log.append("Welcome to Phosphor REPL Demo!") catch {};
        log.append("Commands: help, clear, history, exit") catch {};
        log.append("Keys: Ctrl+O newline | Ctrl+C cancel | Ctrl+D exit") catch {};
        log.append("") catch {};

        return .{
            .log = log,
            .repl = repl,
            .keytester = keytester,
            .size = .{ .w = 80, .h = 24 },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.keytester.deinit();
        self.repl.deinit();
        self.log.deinit();
    }
};

// ─────────────────────────────────────────────────────────────
// Module-level init (required by App framework)
// ─────────────────────────────────────────────────────────────

pub fn init(allocator: std.mem.Allocator) Model {
    return Model.create(allocator);
}

// ─────────────────────────────────────────────────────────────
// Msg - all possible events/messages
// ─────────────────────────────────────────────────────────────

const Msg = union(enum) {
    // System events
    key: Key,
    resize: Size,
    tick: f32,

    // Repl widget events (via Effect.dispatch)
    got_submit: []const u8,
    got_cancel,
    got_eof,
    got_clear_screen,
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
    .on_clear_screen = .got_clear_screen,
};

// ─────────────────────────────────────────────────────────────
// Update - state transitions
// ─────────────────────────────────────────────────────────────

pub fn update(model: *Model, msg: Msg, allocator: std.mem.Allocator) Cmd {
    _ = allocator;

    switch (msg) {
        .resize => |new_size| {
            model.size = new_size;
        },
        .key => |key| {
            // Record key to keytester for debugging
            model.keytester.recordKey(key);

            // Use Effect-based API
            const effect = model.repl.handleKeyEffect(key, Msg, repl_config) catch return .none;
            return processEffectToCmd(effect, model);
        },
        .tick => {},

        // Repl widget events (via Effect.dispatch)
        .got_submit => |text| {
            // Ignore empty/whitespace-only input
            const trimmed = std.mem.trim(u8, text, " \t\n\r");
            if (trimmed.len == 0) return .none;

            echoToLog(&model.log, text) catch {};
            return handleCommand(model, text);
        },
        .got_cancel => {
            // ^C cancels current input (buffer already cleared by Repl widget)
            // Silent cancel - no output to log
        },
        .got_eof => {
            return .quit;
        },
        .got_clear_screen => {
            model.log.clear();
        },
    }

    return .none;
}

/// Convert Effect to Cmd (bridge until runtime fully supports Effect)
fn processEffectToCmd(effect: Effect(Msg), model: *Model) Cmd {
    switch (effect) {
        .none => return .none,
        .quit => return .quit,
        .dispatch => |msg| {
            return update(model, msg, model.allocator);
        },
        .after => return .none, // Cursor handled by view
        .batch => |effects| {
            for (effects) |e| {
                const result = processEffectToCmd(e, model);
                if (result == .quit) return .quit;
            }
            return .none;
        },
    }
}

fn handleCommand(model: *Model, text: []const u8) Cmd {
    const trimmed = std.mem.trim(u8, text, " \t\n\r");

    if (std.mem.eql(u8, trimmed, "clear")) {
        model.log.clear();
        model.log.append("Screen cleared.") catch {};
    } else if (std.mem.eql(u8, trimmed, "help")) {
        model.log.append("Commands: help, clear, echo <text>, history, exit") catch {};
    } else if (std.mem.startsWith(u8, trimmed, "echo ")) {
        const echo_text = trimmed[5..];
        model.log.print("{s}", .{echo_text}) catch {};
    } else if (std.mem.eql(u8, trimmed, "history")) {
        model.log.print("History has {} entries", .{model.repl.history.count()}) catch {};
    } else if (std.mem.eql(u8, trimmed, "exit")) {
        return .quit;
    } else if (trimmed.len > 0) {
        var first_line = trimmed;
        if (std.mem.indexOfScalar(u8, trimmed, '\n')) |idx| {
            first_line = trimmed[0..idx];
        }
        const suffix: []const u8 = if (first_line.len < trimmed.len) "..." else "";
        model.log.print("Unknown command: '{s}{s}'. Type 'help' for commands.", .{ first_line, suffix }) catch {};
    }
    return .none;
}

fn echoToLog(log: *LogView, text: []const u8) !void {
    var lines_iter = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines_iter.next()) |line| {
        if (first) {
            try log.print(" > {s}", .{line});
            first = false;
        } else {
            try log.print("   {s}", .{line});
        }
    }
}

// ─────────────────────────────────────────────────────────────
// View - build layout tree
// ─────────────────────────────────────────────────────────────

pub fn view(model: *Model, ui: *Ui) *Node {
    // Size indicator (for display only - layout system handles actual sizing)
    const size_text = std.fmt.allocPrint(ui.ally, "{d}x{d}", .{ model.size.w, model.size.h }) catch "??x??";

    // Header row: title on left, size on right (size has priority if space is limited)
    const header = ui.justified("Phosphor REPL Demo", size_text);

    // Build the layout tree - widgets get their size from the layout system
    const root = ui.ally.create(LayoutNode) catch @panic("OOM");
    root.* = ui.vbox(.{
        header,
        ui.separator(), // Header separator
        ui.widgetGrow(&model.log), // LogView - grows to fill
        ui.separator(), // Separator above repl
        ui.widget(&model.repl), // Repl - uses preferred height
        ui.separator(), // Separator below repl
        ui.ltext(""), // Blank line
        ui.widgetFixed(&model.keytester, 1), // KeyTester - 1 row
    });

    // Cursor position handled by Repl widget via Effect system
    // For now, use a simple approximation (will be fixed with full Effect integration)
    return ui.layout(root);
}

// ─────────────────────────────────────────────────────────────
// Subscriptions
// ─────────────────────────────────────────────────────────────

pub fn subs(_: *Model) app.Subs {
    return .{
        .keyboard = true,
        .animation_frame = false, // No animation needed
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
        .target_fps = 30, // REPL doesn't need high fps
    });
}
