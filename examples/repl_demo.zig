const std = @import("std");
const phosphor = @import("phosphor");

// Backend and Layout
const Backend = phosphor.Backend;
const TerminalBackend = phosphor.TerminalBackend;
const Event = phosphor.Event;
const DrawCommand = phosphor.DrawCommand;
const Rect = phosphor.Rect;
const LayoutNode = phosphor.LayoutNode;
const layout = phosphor.layout;

// Widgets
const repl_mod = @import("repl");
const Repl = repl_mod.Repl;
const logview_mod = @import("logview");
const LogView = logview_mod.LogView;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize terminal backend
    var term_backend = try TerminalBackend.init(allocator);
    defer term_backend.deinit();
    const backend = term_backend.backend();

    // Enable cursor, bracketed paste, set cursor color
    backend.execute(&.{
        .clear_screen,
        .{ .show_cursor = .{ .visible = true } },
    });

    // Get initial size
    var size = backend.getSize();

    // Create widgets
    var log = LogView.init(allocator, 1000);
    defer log.deinit();

    var repl = try Repl.init(allocator, .{
        .prompt = "phosphor> ",
    });
    defer repl.deinit();

    // Welcome messages
    try log.append("Welcome to Phosphor REPL Demo!");
    try log.append("Commands: help, clear, history, exit");
    try log.append("Ctrl+O inserts newline for multiline input");
    try log.append("");

    // Layout configuration
    const header_height: u16 = 3;
    const min_log_lines: u16 = 3;
    const max_input_rows: u16 = 10;
    var current_input_rows: u16 = 1;

    // Initial render
    try fullRender(backend, &log, &repl, size, header_height, min_log_lines, max_input_rows, &current_input_rows, allocator);

    // Main event loop
    var running = true;
    while (running) {
        const maybe_event = try backend.readEvent();
        if (maybe_event == null) continue;

        const event = maybe_event.?;

        switch (event) {
            .resize => |new_size| {
                size = .{ .cols = new_size.cols, .rows = new_size.rows };
                try fullRender(backend, &log, &repl, size, header_height, min_log_lines, max_input_rows, &current_input_rows, allocator);
            },
            .paste_start => {
                repl.pasteStart();
            },
            .paste_end => {
                repl.pasteEnd();
            },
            .key => |key| {
                // Convert backend.Key to Repl.Key
                const repl_key = convertKey(key);

                // Handle the key
                const action = try repl.handleKey(repl_key);

                switch (action) {
                    .submit => {
                        if (try repl.submit()) |text| {
                            defer allocator.free(text);

                            // Echo command to log
                            try echoToLog(&log, text, repl.getPrompt());

                            // Handle commands
                            if (std.mem.eql(u8, text, "clear")) {
                                log.clear();
                                try log.append("Screen cleared.");
                            } else if (std.mem.eql(u8, text, "help")) {
                                try log.append("Commands: help, clear, history, exit");
                            } else if (std.mem.eql(u8, text, "history")) {
                                try log.print("History has {} entries", .{repl.history.count()});
                            } else if (std.mem.eql(u8, text, "exit")) {
                                running = false;
                            } else if (text.len > 0) {
                                try log.print("Unknown command: '{s}'. Type 'help' for commands.", .{text});
                            }

                            current_input_rows = 1;
                            try fullRender(backend, &log, &repl, size, header_height, min_log_lines, max_input_rows, &current_input_rows, allocator);
                        }
                    },
                    .cancel => {
                        repl.cancel();
                        current_input_rows = 1;
                        try fullRender(backend, &log, &repl, size, header_height, min_log_lines, max_input_rows, &current_input_rows, allocator);
                    },
                    .eof => {
                        running = false;
                    },
                    .clear_screen => {
                        log.clear();
                        try fullRender(backend, &log, &repl, size, header_height, min_log_lines, max_input_rows, &current_input_rows, allocator);
                    },
                    .redraw, .none => {
                        // Just redraw input area
                        const bounds = calcBounds(size, header_height, min_log_lines, current_input_rows);
                        current_input_rows = try renderInput(backend, &repl, bounds.input_start, max_input_rows, size.cols, allocator);

                        // If input grew, need full redraw
                        if (current_input_rows != bounds.expected_input) {
                            try fullRender(backend, &log, &repl, size, header_height, min_log_lines, max_input_rows, &current_input_rows, allocator);
                        }
                    },
                }
            },
            else => {},
        }
    }

    // Cleanup
    backend.execute(&.{
        .{ .move_cursor = .{ .x = 0, .y = size.rows - 1 } },
        .{ .draw_text = .{ .text = "\n" } },
        .flush,
    });
}

/// Calculate layout bounds using the layout system concepts
fn calcBounds(size: phosphor.Size, header_height: u16, min_log: u16, input_rows: u16) struct {
    log_start: u16,
    log_end: u16,
    input_start: u16,
    expected_input: u16,
} {
    const available = if (size.rows > header_height + 1) size.rows - header_height - 1 else 1;
    const input_space = @min(input_rows, available -| min_log);
    const input_start = size.rows -| input_space;
    const log_end = if (input_start > header_height + 1) input_start - 2 else header_height;

    return .{
        .log_start = header_height,
        .log_end = log_end,
        .input_start = input_start,
        .expected_input = input_space,
    };
}

/// Full screen render using DrawCommands
fn fullRender(
    backend: Backend,
    log: *const LogView,
    repl: *Repl,
    size: phosphor.Size,
    header_height: u16,
    min_log: u16,
    max_input: u16,
    current_input_rows: *u16,
    allocator: std.mem.Allocator,
) !void {
    const bounds = calcBounds(size, header_height, min_log, current_input_rows.*);

    // Build commands
    var commands: std.ArrayListUnmanaged(DrawCommand) = .{};
    defer commands.deinit(allocator);

    // Clear screen
    try commands.append(allocator, .clear_screen);

    // Header
    try appendHeaderCommands(&commands, allocator);

    // Log area
    try appendLogCommands(&commands, log, bounds.log_start, bounds.log_end, size.cols, allocator);

    // Execute batch
    backend.execute(commands.items);

    // Size indicator (rendered separately due to formatted text lifetime)
    renderSizeIndicator(backend, size);

    // Input area (returns row count)
    current_input_rows.* = try renderInput(backend, repl, bounds.input_start, max_input, size.cols, allocator);
}

/// Render size indicator separately (formatted text needs stable memory)
fn renderSizeIndicator(backend: Backend, size: phosphor.Size) void {
    var buf: [16]u8 = undefined;
    const size_text = std.fmt.bufPrint(&buf, "{d}x{d}", .{ size.cols, size.rows }) catch "??x??";
    const x = size.cols -| @as(u16, @intCast(size_text.len));

    // Execute immediately while buf is still valid
    backend.execute(&.{
        .{ .move_cursor = .{ .x = x, .y = 0 } },
        .{ .draw_text = .{ .text = size_text } },
    });
}

/// Generate header DrawCommands
fn appendHeaderCommands(
    commands: *std.ArrayListUnmanaged(DrawCommand),
    allocator: std.mem.Allocator,
) !void {
    // Title
    try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = 0 } });
    try commands.append(allocator, .{ .draw_text = .{ .text = "Phosphor REPL Demo" } });

    // Help line
    try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = 1 } });
    try commands.append(allocator, .{ .draw_text = .{ .text = "Ctrl+O: newline | Ctrl+C: cancel | Ctrl+D: exit" } });

    // Separator
    try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = 2 } });
    try commands.append(allocator, .{ .draw_text = .{ .text = "────────────────────────────────────────────────────────────────" } });
}

/// Generate log area DrawCommands
fn appendLogCommands(
    commands: *std.ArrayListUnmanaged(DrawCommand),
    log: *const LogView,
    start_row: u16,
    end_row: u16,
    width: u16,
    allocator: std.mem.Allocator,
) !void {
    const view_height = end_row - start_row + 1;
    const visible = log.getVisibleLines(view_height);

    // Align to bottom
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

/// Render input area - returns number of rows used
fn renderInput(
    backend: Backend,
    repl: *Repl,
    start_line: u16,
    max_lines: u16,
    width: u16,
    allocator: std.mem.Allocator,
) !u16 {
    const text = try repl.buffer.getText(allocator);
    defer allocator.free(text);

    const prompt = repl.getPrompt();
    const prompt_len: u16 = @intCast(prompt.len);
    const wrap_indent = "    ";
    const wrap_indent_len: u16 = @intCast(wrap_indent.len);
    const newline_cont = "... ";
    const newline_cont_len: u16 = @intCast(newline_cont.len);

    var commands: std.ArrayListUnmanaged(DrawCommand) = .{};
    defer commands.deinit(allocator);

    var rows_used: u16 = 0;
    var text_idx: usize = 0;
    var cursor_screen_row: u16 = 0;
    var cursor_screen_col: u16 = 0;
    const cursor_pos = repl.getCursor();
    var is_first_row = true;
    var after_newline = false;

    while (text_idx <= text.len and rows_used < max_lines) {
        const row = start_line + rows_used;
        try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = row } });
        try commands.append(allocator, .clear_line);

        // Prefix for this row
        const prefix = if (is_first_row) prompt else if (after_newline) newline_cont else wrap_indent;
        const prefix_len_val = if (is_first_row) prompt_len else if (after_newline) newline_cont_len else wrap_indent_len;
        try commands.append(allocator, .{ .draw_text = .{ .text = prefix } });

        const content_width: usize = if (width > prefix_len_val) width - prefix_len_val else 1;

        // Find text for this row
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

        // Track cursor position
        if (cursor_pos >= text_idx and cursor_pos <= row_end) {
            cursor_screen_row = row;
            cursor_screen_col = prefix_len_val + @as(u16, @intCast(cursor_pos - text_idx));
        }

        is_first_row = false;
        after_newline = false;

        if (row_end < text.len and text[row_end] == '\n') {
            text_idx = row_end + 1;
            after_newline = true;
            if (cursor_pos == row_end) {
                cursor_screen_row = row;
                cursor_screen_col = prefix_len_val + @as(u16, @intCast(chars_on_row));
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
        const row = start_line;
        try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = row } });
        try commands.append(allocator, .clear_line);
        try commands.append(allocator, .{ .draw_text = .{ .text = prompt } });
        cursor_screen_row = row;
        cursor_screen_col = prompt_len;
        rows_used = 1;
    }

    // Position cursor and flush
    try commands.append(allocator, .{ .move_cursor = .{ .x = cursor_screen_col, .y = cursor_screen_row } });
    try commands.append(allocator, .flush);

    backend.execute(commands.items);

    return rows_used;
}

/// Echo command to log (handles multiline)
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

/// Convert backend.Key to Repl.Key
fn convertKey(key: phosphor.Key) Repl.Key {
    return switch (key) {
        .char => |c| .{ .char = c },
        .enter => .enter,
        .backspace => .backspace,
        .delete => .delete,
        .tab => .tab,
        .escape => .escape,
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
        .home => .home,
        .end => .end,
        .ctrl_a => .ctrl_a,
        .ctrl_c => .ctrl_c,
        .ctrl_d => .ctrl_d,
        .ctrl_e => .ctrl_e,
        .ctrl_k => .ctrl_k,
        .ctrl_l => .ctrl_l,
        .ctrl_o => .ctrl_o,
        .ctrl_u => .ctrl_u,
        .ctrl_w => .ctrl_w,
        .ctrl_left => .ctrl_left,
        .ctrl_right => .ctrl_right,
        .unknown => .unknown,
    };
}
