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

// Re-export Key from phosphor for widget compatibility
const Key = phosphor.Key;

// ─────────────────────────────────────────────────────────────
// Model - all application state in one place
// ─────────────────────────────────────────────────────────────

const Model = struct {
    log: LogView,
    repl: Repl,
    size: Size,
    running: bool,
    allocator: std.mem.Allocator,

    // Layout structure
    const header_height: u16 = 2; // title + separator
    const min_log_lines: u16 = 3;
    const max_input_rows: u16 = 10;

    pub fn create(allocator: std.mem.Allocator) Model {
        var log = LogView.init(allocator, 1000);

        const repl = Repl.init(allocator, .{ .prompt = "phosphor> " }) catch {
            log.deinit();
            @panic("Failed to init Repl");
        };

        // Welcome messages
        log.append("Welcome to Phosphor REPL Demo!") catch {};
        log.append("Commands: help, clear, history, exit") catch {};
        log.append("Keys: Ctrl+O newline | Ctrl+C cancel | Ctrl+D exit") catch {};
        log.append("") catch {};

        return .{
            .log = log,
            .repl = repl,
            .size = .{ .w = 80, .h = 24 }, // Will be updated on first resize
            .running = true,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        _ = allocator;
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
    key: u8,
    resize: Size,
    tick: f32,
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
        .key => |key_byte| {
            // Convert key byte to phosphor Key and route to repl widget
            const key = keyByteToKey(key_byte);
            const widget_event = Repl.Event{ .key = key };

            if (model.repl.update(widget_event) catch null) |repl_msg| {
                handleReplMsg(model, repl_msg) catch {};
            }
        },
        .tick => {},
    }

    if (!model.running) {
        return .quit;
    }
    return .none;
}

fn keyByteToKey(byte: u8) Key {
    return switch (byte) {
        1 => .ctrl_a,
        3 => .ctrl_c,
        4 => .ctrl_d,
        5 => .ctrl_e,
        11 => .ctrl_k,
        12 => .ctrl_l,
        15 => .ctrl_o,
        21 => .ctrl_u,
        23 => .ctrl_w,
        9 => .tab,
        10, 13 => .enter,
        27 => .escape,
        127 => .backspace,
        else => if (byte >= 32 and byte < 127) .{ .char = byte } else .unknown,
    };
}

fn handleReplMsg(model: *Model, repl_msg: Repl.ReplMsg) !void {
    switch (repl_msg) {
        .submitted => |text| {
            try echoToLog(&model.log, text, model.repl.getPrompt());
            try handleCommand(model, text);
            try model.repl.finalizeSubmit();
        },
        .cancelled => {
            model.repl.cancel();
        },
        .eof => {
            model.running = false;
        },
        .clear_screen => {
            model.log.clear();
        },
        .text_changed => {},
    }
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

    // Build repl view first to get its height
    var repl_view = model.repl.viewTree(cols, alloc) catch {
        return ui.text("Error building repl view");
    };
    const repl_height = repl_view.getHeight();

    // Calculate available height for log
    const log_available_height = rows -| Model.header_height -| repl_height;

    // Build log view
    var log_view = model.log.viewTree(cols, log_available_height, alloc) catch {
        return ui.text("Error building log view");
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

    // Log section
    var log_node = log_view.build();
    log_node.sizing.h = .{ .grow = .{} };

    // REPL input
    var repl_node = repl_view.build();
    repl_node.sizing.h = .{ .fixed = repl_view.getHeight() };

    // Root vbox
    const root_children = alloc.alloc(LayoutNode, 4) catch {
        return ui.text("Error allocating root");
    };
    root_children[0] = header_row;
    root_children[1] = sep_row;
    root_children[2] = log_node;
    root_children[3] = repl_node;

    const root_ptr = alloc.create(LayoutNode) catch {
        return ui.text("Error allocating root node");
    };
    root_ptr.* = LayoutNode.vbox(root_children);

    // Calculate cursor position
    const cursor_x = repl_view.getCursorX();
    const repl_start_y = rows - repl_view.getHeight();
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
