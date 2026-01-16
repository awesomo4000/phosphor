const std = @import("std");
const app = @import("app");
const phosphor = @import("phosphor");

const Cmd = app.Cmd;
const Size = app.Size;
const Ui = app.Ui;
const Node = app.Node;

// Phosphor layout types (re-exported through app)
const LayoutNode = app.LayoutNode;
const Rect = app.Rect;
const renderTree = app.renderTree;

// Widgets
const repl_mod = @import("repl");
const Repl = repl_mod.Repl;
const logview_mod = @import("logview");
const LogView = logview_mod.LogView;
const keytester_mod = @import("keytester");
const KeyTester = keytester_mod.KeyTester;

// ─────────────────────────────────────────────────────────────
// Model - all application state in one place
// ─────────────────────────────────────────────────────────────

const Model = struct {
    log: LogView,
    repl: Repl,
    keytester: KeyTester,
    size: Size,
    running: bool,
    allocator: std.mem.Allocator,

    // Layout structure
    const header_height: u16 = 2; // title + separator
    const footer_height: u16 = 1; // keytester
    const min_log_lines: u16 = 3;
    const max_input_rows: u16 = 10;

    pub fn create(allocator: std.mem.Allocator) Model {
        var log = LogView.init(allocator, 1000);

        const repl = Repl.init(allocator, .{ .prompt = "phosphor> " }) catch {
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
            .size = .{ .w = 80, .h = 24 }, // Will be updated on first resize
            .running = true,
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
    key: app.Key,
    resize: Size,
    tick: f32,

    // Repl widget events (mapped from Repl.ReplMsg)
    got_submit: []const u8,
    got_cancel,
    got_eof,
    got_clear_screen,
};

// Message mappers using wrap() - declarative child-to-parent message translation
const repl_msg_map = struct {
    const submitted = app.wrap(Msg, .got_submit);
    const cancelled = app.wrapVoid(Msg, .got_cancel);
    const eof = app.wrapVoid(Msg, .got_eof);
    const clear_screen = app.wrapVoid(Msg, .got_clear_screen);

    /// Map a ReplMsg to our Msg type
    fn map(repl_msg: Repl.ReplMsg) ?Msg {
        return switch (repl_msg) {
            .submitted => |text| submitted(text),
            .cancelled => cancelled(),
            .eof => eof(),
            .clear_screen => clear_screen(),
            .text_changed => null, // Ignore text changes
        };
    }
};

// ─────────────────────────────────────────────────────────────
// Update - state transitions
// ─────────────────────────────────────────────────────────────

pub fn update(model: *Model, msg: Msg, allocator: std.mem.Allocator) Cmd {
    switch (msg) {
        // System events
        .resize => |new_size| {
            model.size = new_size;
        },
        .key => |key| {
            // Record key to keytester for debugging
            model.keytester.recordKey(key);

            // Route key directly to repl widget (app.Key and phosphor.Key are same type)
            if (model.repl.update(.{ .key = key }) catch null) |repl_msg| {
                if (repl_msg_map.map(repl_msg)) |mapped| {
                    // Recursively handle the mapped message
                    return update(model, mapped, allocator);
                }
            }
        },
        .tick => {},

        // Repl widget events (mapped from ReplMsg via wrap())
        .got_submit => |text| {
            echoToLog(&model.log, text, model.repl.getPrompt()) catch {};
            handleCommand(model, text) catch {};
            model.repl.finalizeSubmit() catch {};
        },
        .got_cancel => {
            model.repl.cancel();
        },
        .got_eof => {
            model.running = false;
        },
        .got_clear_screen => {
            model.log.clear();
        },
    }

    if (!model.running) {
        return .quit;
    }
    return .none;
}

fn handleCommand(model: *Model, text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \t\n\r");

    if (std.mem.eql(u8, trimmed, "clear")) {
        model.log.clear();
        try model.log.append("Screen cleared.");
    } else if (std.mem.eql(u8, trimmed, "help")) {
        try model.log.append("Commands: help, clear, history, exit");
    } else if (std.mem.eql(u8, trimmed, "history")) {
        try model.log.print("History has {} entries", .{model.repl.history.count()});
    } else if (std.mem.eql(u8, trimmed, "exit")) {
        model.running = false;
    } else if (trimmed.len > 0) {
        var first_line = trimmed;
        if (std.mem.indexOfScalar(u8, trimmed, '\n')) |idx| {
            first_line = trimmed[0..idx];
        }
        const suffix: []const u8 = if (first_line.len < trimmed.len) "..." else "";
        try model.log.print("Unknown command: '{s}{s}'. Type 'help' for commands.", .{ first_line, suffix });
    }
}

fn echoToLog(log: *LogView, text: []const u8, prompt: []const u8) !void {
    var lines_iter = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines_iter.next()) |line| {
        if (first) {
            try log.print("{s}{s}", .{ prompt, line });
            first = false;
        } else {
            try log.print("... {s}", .{line});
        }
    }
}

// ─────────────────────────────────────────────────────────────
// View - build layout tree
// ─────────────────────────────────────────────────────────────

pub fn view(model: *Model, ui: *Ui) *Node {
    const alloc = ui.ally;

    // Get terminal size in cells
    const cols: u16 = @intCast(model.size.w);
    const rows: u16 = @intCast(model.size.h);

    // Build repl view first to get its height (still uses legacy pattern for cursor)
    var repl_view = model.repl.viewTree(cols, alloc) catch {
        return ui.text("Error building repl view");
    };

    // Build size indicator text
    const size_text = std.fmt.allocPrint(alloc, "{d}x{d}", .{ cols, rows }) catch "??x??";

    // Build separator
    const separator = alloc.alloc(u8, cols * 3) catch {
        return ui.text("Error allocating separator");
    };
    var sep_idx: usize = 0;
    for (0..cols) |_| {
        separator[sep_idx] = 0xe2;
        separator[sep_idx + 1] = 0x94;
        separator[sep_idx + 2] = 0x80;
        sep_idx += 3;
    }

    const title_text = "Phosphor REPL Demo";

    // Header row: title + spacer + size indicator
    const header_children = alloc.alloc(LayoutNode, 3) catch {
        return ui.text("Error allocating header");
    };
    header_children[0] = LayoutNode.text(title_text);
    header_children[1] = phosphor.Spacer.node();
    header_children[2] = LayoutNode.text(size_text);

    var header_row = LayoutNode.hbox(header_children);
    header_row.sizing.h = .{ .fixed = 1 };

    // Separator row
    var sep_row = LayoutNode.text(separator[0..sep_idx]);
    sep_row.sizing.h = .{ .fixed = 1 };

    // Log section - uses localWidget, gets its height from layout system!
    // No manual height calculation needed.
    var log_node = LayoutNode.localWidget(model.log.localWidget());
    log_node.sizing.h = .{ .grow = .{} };

    // REPL input (still uses legacy pattern for cursor position tracking)
    var repl_node = repl_view.build();
    repl_node.sizing.h = .{ .fixed = repl_view.getHeight() };

    // KeyTester footer - uses localWidget via viewTree
    var keytester_view = model.keytester.viewTree(alloc) catch {
        return ui.text("Error building keytester view");
    };
    const keytester_node = keytester_view.build();

    // Root vbox
    const root_children = alloc.alloc(LayoutNode, 5) catch {
        return ui.text("Error allocating root");
    };
    root_children[0] = header_row;
    root_children[1] = sep_row;
    root_children[2] = log_node;
    root_children[3] = repl_node;
    root_children[4] = keytester_node;

    const root_ptr = alloc.create(LayoutNode) catch {
        return ui.text("Error allocating root node");
    };
    root_ptr.* = LayoutNode.vbox(root_children);

    // Calculate cursor position (repl is above keytester which takes 1 row)
    const cursor_x = repl_view.getCursorX();
    const repl_start_y = rows - repl_view.getHeight() - Model.footer_height;
    const cursor_y = repl_start_y + repl_view.getCursorRow();

    return ui.layoutWithCursor(root_ptr, cursor_x, cursor_y);
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
