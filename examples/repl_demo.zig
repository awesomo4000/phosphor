const std = @import("std");
const phosphor = @import("phosphor");

const Backend = phosphor.Backend;
const ThermiteBackend = phosphor.ThermiteBackend;
const Event = phosphor.Event;
const Key = phosphor.Key;
const DrawCommand = phosphor.DrawCommand;
const Size = phosphor.Size;
const LayoutNode = phosphor.LayoutNode;
const Rect = phosphor.Rect;
const Text = phosphor.Text;
const Sizing = phosphor.Sizing;
const renderTree = phosphor.renderTree;
const Sub = phosphor.Sub;

const repl_mod = @import("repl");
const Repl = repl_mod.Repl;
const logview_mod = @import("logview");
const LogView = logview_mod.LogView;

// ─────────────────────────────────────────────────────────────
// Model - all application state in one place
// ─────────────────────────────────────────────────────────────

const Model = struct {
    log: LogView,
    repl: Repl,
    size: Size,
    running: bool,
    allocator: std.mem.Allocator,

    // Layout structure (vbox):
    //   Row 0: Title bar - hbox [title: grow] [size: fit]
    //   Row 1: Separator - fixed h=1, grows to width
    //   Remaining: vbox [log: grow] [repl: fit to content]
    const header_height: u16 = 2; // title + separator
    const min_log_lines: u16 = 3;
    const max_input_rows: u16 = 10;

    pub fn init(allocator: std.mem.Allocator, size: Size) !Model {
        var log = LogView.init(allocator, 1000);
        errdefer log.deinit();

        var repl = try Repl.init(allocator, .{ .prompt = "phosphor> " });
        errdefer repl.deinit();

        // Welcome messages (help moved here from header)
        try log.append("Welcome to Phosphor REPL Demo!");
        try log.append("Commands: help, clear, history, exit");
        try log.append("Keys: Ctrl+O newline | Ctrl+C cancel | Ctrl+D exit");
        try log.append("");

        return .{
            .log = log,
            .repl = repl,
            .size = size,
            .running = true,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Model) void {
        self.repl.deinit();
        self.log.deinit();
    }
};

// ─────────────────────────────────────────────────────────────
// Msg - all possible events/messages
// ─────────────────────────────────────────────────────────────

const Msg = union(enum) {
    key: Key,
    resize: Size,
    paste_start,
    paste_end,
    tick,
    none,
};

fn eventToMsg(event: Event) Msg {
    return switch (event) {
        .key => |k| .{ .key = k },
        .resize => |s| .{ .resize = s },
        .paste_start => .paste_start,
        .paste_end => .paste_end,
        .tick => .tick,
        .none => .none,
    };
}

/// Check if a message matches any of the given subscriptions
fn isSubscribed(subs: []const Sub, msg: Msg) bool {
    for (subs) |sub| {
        const matches = switch (sub) {
            .keyboard => msg == .key,
            .paste => msg == .paste_start or msg == .paste_end,
            .resize => msg == .resize,
            .tick_ms => msg == .tick,
            .focus => false, // TODO: focus_gained/focus_lost messages
        };
        if (matches) return true;
    }
    return false;
}

// ─────────────────────────────────────────────────────────────
// Update - state transitions (as pure as possible)
// ─────────────────────────────────────────────────────────────

/// App-level update - receives high-level messages from widgets
/// (This is what the app author writes)
fn update(model: *Model, msg: Msg) !void {
    switch (msg) {
        .resize => |new_size| {
            model.size = new_size;
        },
        .tick, .none => {},
        // App doesn't handle key/paste directly - those go to widgets via runtime
        else => {},
    }
}

/// Route events to widgets based on subscriptions, collect messages
/// (This is runtime code - would live in Runtime struct)
fn routeToWidgets(model: *Model, msg: Msg) !?Repl.ReplMsg {
    // Check repl widget's subscriptions
    const repl_subs = model.repl.subscriptions();
    if (isSubscribed(repl_subs, msg)) {
        // Convert app Msg to widget Event
        const widget_event: ?Repl.Event = switch (msg) {
            .key => |k| .{ .key = k },
            .paste_start => .paste_start,
            .paste_end => .paste_end,
            else => null,
        };

        if (widget_event) |event| {
            // Widget processes event, returns message for app
            return try model.repl.update(event);
        }
    }
    return null;
}

/// Handle messages from the Repl widget
/// (This is app code - what the app author writes)
fn handleReplMsg(model: *Model, repl_msg: Repl.ReplMsg) !void {
    switch (repl_msg) {
        .submitted => |text| {
            // Echo to log and handle command
            // Note: text is a slice into widget's buffer, valid until next update
            try echoToLog(&model.log, text, model.repl.getPrompt());
            try handleCommand(model, text);
            // Finalize submission (clears buffer, adds to history)
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
        .text_changed => {
            // Could do validation, autocomplete lookup, etc.
        },
    }
}

fn handleCommand(model: *Model, text: []const u8) !void {
    // Trim whitespace for command matching
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
        // Show first line only in error message for cleaner output
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
// View - pure function producing DrawCommands
// ─────────────────────────────────────────────────────────────

const ViewResult = struct {
    commands: []DrawCommand,
    cursor: struct { x: u16, y: u16 },
    // Owned allocations that DrawCommands reference - freed in deinit
    text_allocs: [][]const u8,

    pub fn deinit(self: *ViewResult, allocator: std.mem.Allocator) void {
        for (self.text_allocs) |text| {
            allocator.free(text);
        }
        allocator.free(self.text_allocs);
        allocator.free(self.commands);
    }
};

// Legacy imperative view - kept for reference, use view() instead
fn viewLegacy(model: *const Model, allocator: std.mem.Allocator) !ViewResult {
    const bounds = calcBounds(model);

    var commands: std.ArrayListUnmanaged(DrawCommand) = .{};
    errdefer commands.deinit(allocator);

    var text_allocs: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (text_allocs.items) |t| allocator.free(t);
        text_allocs.deinit(allocator);
    }

    // Clear back buffer before rendering - essential for differential rendering
    // Without this, old content persists in cells we don't explicitly write to
    try commands.append(allocator, .clear_screen);

    // Render all components - Thermite diffs against previous frame
    try appendHeader(&commands, &text_allocs, model.size, allocator);
    try appendLog(&commands, &model.log, bounds.log_start, bounds.log_end, model.size.cols, allocator);

    // Input area
    const input_result = try appendInput(&commands, &text_allocs, &model.repl, bounds.input_start, model.size.cols, allocator);

    // Final cursor position, show cursor, and present
    try commands.append(allocator, .{ .move_cursor = .{ .x = input_result.cursor_x, .y = input_result.cursor_y } });
    try commands.append(allocator, .{ .show_cursor = .{ .visible = true } });
    try commands.append(allocator, .flush);

    return .{
        .commands = try commands.toOwnedSlice(allocator),
        .cursor = .{ .x = input_result.cursor_x, .y = input_result.cursor_y },
        .text_allocs = try text_allocs.toOwnedSlice(allocator),
    };
}

const Bounds = struct {
    log_start: u16,
    log_end: u16,
    input_start: u16,
};

fn calcBounds(model: *const Model) Bounds {
    const input_rows = calcInputRows(model);
    const available = if (model.size.rows > Model.header_height + 1)
        model.size.rows - Model.header_height - 1
    else
        1;
    const input_space = @min(input_rows, available -| Model.min_log_lines);
    const input_start = model.size.rows -| input_space;
    const log_end = if (input_start > Model.header_height + 1)
        input_start - 2
    else
        Model.header_height;

    return .{
        .log_start = Model.header_height,
        .log_end = log_end,
        .input_start = input_start,
    };
}

fn calcInputRows(model: *const Model) u16 {
    // Calculate how many rows the input will need based on content
    const text = model.repl.buffer.getTextSlice() orelse return 1;
    const width = model.size.cols;
    const prompt_len = model.repl.getPrompt().len;
    const content_width = if (width > prompt_len) width - @as(u16, @intCast(prompt_len)) else 1;

    if (text.len == 0) return 1;

    // Count newlines and wrapped lines
    var rows: u16 = 1;
    var col: usize = 0;
    for (text) |c| {
        if (c == '\n') {
            rows += 1;
            col = 0;
        } else {
            col += 1;
            if (col >= content_width) {
                rows += 1;
                col = 0;
            }
        }
    }

    return @min(rows, Model.max_input_rows);
}

fn appendHeader(
    commands: *std.ArrayListUnmanaged(DrawCommand),
    text_allocs: *std.ArrayListUnmanaged([]const u8),
    size: Size,
    allocator: std.mem.Allocator,
) !void {
    // ═══════════════════════════════════════════════════════════════
    // Row 0: Title bar - hbox [title: grow] [size: fit]
    // ═══════════════════════════════════════════════════════════════
    const title = "Phosphor REPL Demo";
    const size_text = try std.fmt.allocPrint(allocator, "{d}x{d}", .{ size.cols, size.rows });
    try text_allocs.append(allocator, size_text);

    // Layout: size_indicator gets its preferred width, title grows to fill rest
    const size_width: u16 = @intCast(size_text.len);
    const title_x: u16 = 0;
    const size_x: u16 = size.cols -| size_width;

    // Render title (grows to fill space before size indicator)
    try commands.append(allocator, .{ .move_cursor = .{ .x = title_x, .y = 0 } });
    try commands.append(allocator, .clear_line);
    const display_title = title[0..@min(title.len, size_x)];
    try commands.append(allocator, .{ .draw_text = .{ .text = display_title } });

    // Render size indicator (fits to content, right-aligned)
    try commands.append(allocator, .{ .move_cursor = .{ .x = size_x, .y = 0 } });
    try commands.append(allocator, .{ .draw_text = .{ .text = size_text } });

    // ═══════════════════════════════════════════════════════════════
    // Row 1: Separator - grows to terminal width
    // ═══════════════════════════════════════════════════════════════
    const separator = try allocator.alloc(u8, size.cols * 3); // UTF-8: ─ is 3 bytes
    try text_allocs.append(allocator, separator);

    var sep_idx: usize = 0;
    for (0..size.cols) |_| {
        separator[sep_idx] = 0xe2; // ─ UTF-8: E2 94 80
        separator[sep_idx + 1] = 0x94;
        separator[sep_idx + 2] = 0x80;
        sep_idx += 3;
    }

    try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = 1 } });
    try commands.append(allocator, .{ .draw_text = .{ .text = separator[0..sep_idx] } });
}

fn appendLog(
    commands: *std.ArrayListUnmanaged(DrawCommand),
    log: *const LogView,
    start_row: u16,
    end_row: u16,
    width: u16,
    allocator: std.mem.Allocator,
) !void {
    const view_height = end_row - start_row + 1;
    const visible = log.getVisibleLines(view_height);
    const empty_rows = view_height - visible.len;

    // Clear empty rows
    for (0..empty_rows) |i| {
        const row = start_row + @as(u16, @intCast(i));
        try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = row } });
        try commands.append(allocator, .clear_line);
    }

    // Render visible lines
    for (visible, 0..) |line, i| {
        const row = start_row + @as(u16, @intCast(empty_rows + i));
        try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = row } });
        try commands.append(allocator, .clear_line);
        const display_len = @min(line.text.len, width);
        try commands.append(allocator, .{ .draw_text = .{ .text = line.text[0..display_len] } });
    }
}

const InputResult = struct {
    cursor_x: u16,
    cursor_y: u16,
};

fn appendInput(
    commands: *std.ArrayListUnmanaged(DrawCommand),
    text_allocs: *std.ArrayListUnmanaged([]const u8),
    repl: *const Repl,
    start_line: u16,
    width: u16,
    allocator: std.mem.Allocator,
) !InputResult {
    const text = try repl.buffer.getText(allocator);
    try text_allocs.append(allocator, text); // Transfer ownership to caller

    const prompt = repl.getPrompt();
    const prompt_len: u16 = @intCast(prompt.len);
    const wrap_indent = "    ";
    const wrap_indent_len: u16 = 4;
    const newline_cont = "... ";
    const newline_cont_len: u16 = 4;

    var rows_used: u16 = 0;
    var text_idx: usize = 0;
    var cursor_x: u16 = prompt_len;
    var cursor_y: u16 = start_line;
    const cursor_pos = repl.getCursor();
    var is_first_row = true;
    var after_newline = false;

    while (text_idx <= text.len and rows_used < Model.max_input_rows) {
        const row = start_line + rows_used;
        try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = row } });
        try commands.append(allocator, .clear_line);

        const prefix = if (is_first_row) prompt else if (after_newline) newline_cont else wrap_indent;
        const prefix_len: u16 = if (is_first_row) prompt_len else if (after_newline) newline_cont_len else wrap_indent_len;
        try commands.append(allocator, .{ .draw_text = .{ .text = prefix } });

        const content_width: usize = if (width > prefix_len) width - prefix_len else 1;

        var row_end = text_idx;
        var chars_on_row: usize = 0;
        while (row_end < text.len and chars_on_row < content_width) {
            if (text[row_end] == '\n') break;
            row_end += 1;
            chars_on_row += 1;
        }

        if (row_end > text_idx) {
            try commands.append(allocator, .{ .draw_text = .{ .text = text[text_idx..row_end] } });
        }

        // Track cursor
        if (cursor_pos >= text_idx and cursor_pos <= row_end) {
            cursor_y = row;
            cursor_x = prefix_len + @as(u16, @intCast(cursor_pos - text_idx));
        }

        is_first_row = false;
        after_newline = false;

        if (row_end < text.len and text[row_end] == '\n') {
            text_idx = row_end + 1;
            after_newline = true;
            if (cursor_pos == row_end) {
                cursor_y = row;
                cursor_x = prefix_len + @as(u16, @intCast(chars_on_row));
            }
        } else if (row_end < text.len) {
            text_idx = row_end;
        } else {
            text_idx = text.len + 1;
        }

        rows_used += 1;
    }

    // Empty input
    if (rows_used == 0) {
        try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = start_line } });
        try commands.append(allocator, .clear_line);
        try commands.append(allocator, .{ .draw_text = .{ .text = prompt } });
        cursor_x = prompt_len;
        cursor_y = start_line;
    }

    return .{ .cursor_x = cursor_x, .cursor_y = cursor_y };
}

// ─────────────────────────────────────────────────────────────
// Declarative View (new approach)
// ─────────────────────────────────────────────────────────────

const DeclarativeViewResult = struct {
    commands: []DrawCommand,
    cursor_x: u16,
    cursor_y: u16,
    // Allocations to free
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *DeclarativeViewResult) void {
        self.arena.deinit();
    }
};

fn view(model: *const Model, backing_allocator: std.mem.Allocator) !DeclarativeViewResult {
    // Use arena for frame allocations - everything freed together at end
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    // Build repl view first to get its height
    var repl_view = try model.repl.viewTree(model.size.cols, alloc);
    const repl_height = repl_view.getHeight();

    // Calculate available height for log (screen - header - separator - repl)
    const log_available_height = model.size.rows -| Model.header_height -| repl_height;

    // Build log view with height constraint
    var log_view = try model.log.viewTree(model.size.cols, log_available_height, alloc);

    // Build size indicator text
    const size_text = try std.fmt.allocPrint(alloc, "{d}x{d}", .{ model.size.cols, model.size.rows });

    // Build separator
    const separator = try alloc.alloc(u8, model.size.cols * 3);
    var sep_idx: usize = 0;
    for (0..model.size.cols) |_| {
        separator[sep_idx] = 0xe2;
        separator[sep_idx + 1] = 0x94;
        separator[sep_idx + 2] = 0x80;
        sep_idx += 3;
    }

    // Build the layout tree:
    // vbox [
    //   hbox [ title: grow | size: fit ]    -- row 0
    //   separator                            -- row 1
    //   log: grow                            -- rows 2..n-1
    //   repl: fit                            -- bottom
    // ]

    const title_text = "Phosphor REPL Demo";

    // Header row: title + size indicator
    const header_children = try alloc.alloc(LayoutNode, 3);
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

    // REPL input - height based on actual line count
    var repl_node = repl_view.build();
    repl_node.sizing.h = .{ .fixed = repl_view.getHeight() };

    // Root vbox
    const root_children = try alloc.alloc(LayoutNode, 4);
    root_children[0] = header_row;
    root_children[1] = sep_row;
    root_children[2] = log_node;
    root_children[3] = repl_node;

    const root = LayoutNode.vbox(root_children);

    // Render the tree to commands
    const full_bounds = Rect{ .x = 0, .y = 0, .w = model.size.cols, .h = model.size.rows };

    var commands_list: std.ArrayListUnmanaged(DrawCommand) = .{};

    // Add clear_screen at start
    try commands_list.append(alloc, .clear_screen);

    // Render the tree
    const tree_commands = try renderTree(&root, full_bounds, alloc);
    try commands_list.appendSlice(alloc, tree_commands);

    // Calculate cursor position based on multiline layout
    const cursor_x = repl_view.getCursorX();
    // REPL starts at (screen height - repl height), cursor is offset within repl
    const repl_start_y = model.size.rows - repl_view.getHeight();
    const cursor_y = repl_start_y + repl_view.getCursorRow();

    // Add cursor and flush
    try commands_list.append(alloc, .{ .move_cursor = .{ .x = cursor_x, .y = cursor_y } });
    try commands_list.append(alloc, .{ .show_cursor = .{ .visible = true } });
    try commands_list.append(alloc, .flush);

    return .{
        .commands = try commands_list.toOwnedSlice(alloc),
        .cursor_x = cursor_x,
        .cursor_y = cursor_y,
        .arena = arena,
    };
}

// ─────────────────────────────────────────────────────────────
// Main - wire it all together
// ─────────────────────────────────────────────────────────────

pub fn main() !void {
    // Enable timing if PHOSPHOR_DEBUG_TIMING=1
    const timer = @import("phosphor").startup_timer;
    if (std.posix.getenv("PHOSPHOR_DEBUG_TIMING")) |val| {
        if (std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true")) {
            timer.enable();
        }
    }
    timer.mark("main() entry");

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    timer.mark("GPA initialized");

    // Initialize Thermite backend (double-buffered, differential rendering)
    var thermite_backend = try ThermiteBackend.init(allocator);
    defer thermite_backend.deinit();
    const backend = thermite_backend.backend();
    timer.mark("ThermiteBackend.init() done");

    // Initialize model
    var model = try Model.init(allocator, backend.getSize());
    defer model.deinit();
    timer.mark("Model.init() done");

    // Initial render
    {
        timer.mark("view() start");
        var result = try view(&model, allocator);
        defer result.deinit();
        timer.mark("view() done");
        backend.execute(result.commands);
        timer.mark("backend.execute() done");
    }

    // Dump timing to log if enabled
    if (timer.isEnabled()) {
        try timer.global_timer.dumpToLog(&model.log);

        // Re-render to show timing in log
        var result = try view(&model, allocator);
        defer result.deinit();
        backend.execute(result.commands);
    }

    // Event loop - Thermite handles diffing, so we always render full view
    while (model.running) {
        const maybe_event = try backend.readEvent();
        if (maybe_event == null) continue;

        // Handle resize at the backend level (reallocate planes)
        if (maybe_event.? == .resize) {
            const new_size = maybe_event.?.resize;
            try thermite_backend.resize(.{ .cols = new_size.cols, .rows = new_size.rows });
        }

        const msg = eventToMsg(maybe_event.?);

        // Runtime: route events to widgets based on subscriptions
        // Widget returns messages for the app
        if (try routeToWidgets(&model, msg)) |repl_msg| {
            // App: handle widget messages
            try handleReplMsg(&model, repl_msg);
        }

        // App: handle app-level messages (resize, etc.)
        try update(&model, msg);

        // Re-render full view using declarative approach
        var result = try view(&model, allocator);
        defer result.deinit();
        backend.execute(result.commands);
    }
}
