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

    // Layout config (could be in a separate Config struct)
    const header_height: u16 = 3;
    const min_log_lines: u16 = 3;
    const max_input_rows: u16 = 10;

    pub fn init(allocator: std.mem.Allocator, size: Size) !Model {
        var log = LogView.init(allocator, 1000);
        errdefer log.deinit();

        var repl = try Repl.init(allocator, .{ .prompt = "phosphor> " });
        errdefer repl.deinit();

        // Welcome messages
        try log.append("Welcome to Phosphor REPL Demo!");
        try log.append("Commands: help, clear, history, exit");
        try log.append("Ctrl+O inserts newline for multiline input");
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

// ─────────────────────────────────────────────────────────────
// Update - state transitions (as pure as possible)
// ─────────────────────────────────────────────────────────────

fn update(model: *Model, msg: Msg) !void {
    switch (msg) {
        .resize => |new_size| {
            model.size = new_size;
        },
        .paste_start => {
            model.repl.pasteStart();
        },
        .paste_end => {
            model.repl.pasteEnd();
        },
        .key => |key| {
            const action = try model.repl.handleKey(key);
            try handleAction(model, action);
        },
        .tick, .none => {},
    }
}

fn handleAction(model: *Model, action: Repl.Action) !void {
    switch (action) {
        .submit => {
            if (try model.repl.submit()) |text| {
                defer model.allocator.free(text);
                try echoToLog(&model.log, text, model.repl.getPrompt());
                try handleCommand(model, text);
            }
        },
        .cancel => {
            model.repl.cancel();
        },
        .eof => {
            model.running = false;
        },
        .clear_screen => {
            model.log.clear();
        },
        .redraw, .none => {},
    }
}

fn handleCommand(model: *Model, text: []const u8) !void {
    if (std.mem.eql(u8, text, "clear")) {
        model.log.clear();
        try model.log.append("Screen cleared.");
    } else if (std.mem.eql(u8, text, "help")) {
        try model.log.append("Commands: help, clear, history, exit");
    } else if (std.mem.eql(u8, text, "history")) {
        try model.log.print("History has {} entries", .{model.repl.history.count()});
    } else if (std.mem.eql(u8, text, "exit")) {
        model.running = false;
    } else if (text.len > 0) {
        try model.log.print("Unknown command: '{s}'. Type 'help' for commands.", .{text});
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

fn view(model: *const Model, allocator: std.mem.Allocator) !ViewResult {
    const bounds = calcBounds(model);

    var commands: std.ArrayListUnmanaged(DrawCommand) = .{};
    errdefer commands.deinit(allocator);

    var text_allocs: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (text_allocs.items) |t| allocator.free(t);
        text_allocs.deinit(allocator);
    }

    // Always render everything - Thermite's differential rendering
    // will only output what actually changed
    try appendHeader(&commands, &text_allocs, model.size, allocator);
    try appendLog(&commands, &model.log, bounds.log_start, bounds.log_end, model.size.cols, allocator);

    // Input area
    const input_result = try appendInput(&commands, &text_allocs, &model.repl, bounds.input_start, model.size.cols, allocator);

    // Final cursor position and present
    try commands.append(allocator, .{ .move_cursor = .{ .x = input_result.cursor_x, .y = input_result.cursor_y } });
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
    // Title row layout: hbox [title: grow] [size: fit]
    // This is equivalent to: LayoutNode.hbox(&.{
    //     .leafSized(title, .{ .w = .grow }),
    //     .leafSized(size_indicator, .{ .w = .fit }),
    // })
    const title = "Phosphor REPL Demo";
    const size_text = try std.fmt.allocPrint(allocator, "{d}x{d}", .{ size.cols, size.rows });
    try text_allocs.append(allocator, size_text);

    // Layout calculation:
    // - size_indicator gets its preferred width (text length)
    // - title grows to fill remaining space
    const size_indicator_width: u16 = @intCast(size_text.len);
    const title_width = size.cols -| size_indicator_width;
    const size_indicator_x = title_width;

    // Render title in bounds [0, title_width)
    try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = 0 } });
    const display_title = title[0..@min(title.len, title_width)];
    try commands.append(allocator, .{ .draw_text = .{ .text = display_title } });

    // Render size indicator in bounds [size_indicator_x, cols)
    try commands.append(allocator, .{ .move_cursor = .{ .x = size_indicator_x, .y = 0 } });
    try commands.append(allocator, .{ .draw_text = .{ .text = size_text } });

    // Help line
    try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = 1 } });
    try commands.append(allocator, .{ .draw_text = .{ .text = "Ctrl+O: newline | Ctrl+C: cancel | Ctrl+D: exit" } });

    // Separator
    try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = 2 } });
    try commands.append(allocator, .{ .draw_text = .{ .text = "────────────────────────────────────────────────────────────────" } });
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
// Main - wire it all together
// ─────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Thermite backend (double-buffered, differential rendering)
    var thermite_backend = try ThermiteBackend.init(allocator);
    defer thermite_backend.deinit();
    const backend = thermite_backend.backend();

    // Initialize model
    var model = try Model.init(allocator, backend.getSize());
    defer model.deinit();

    // Initial render
    {
        var result = try view(&model, allocator);
        defer result.deinit(allocator);
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
        try update(&model, msg);

        // Re-render full view, Thermite only outputs changed cells
        var result = try view(&model, allocator);
        defer result.deinit(allocator);
        backend.execute(result.commands);
    }
}
