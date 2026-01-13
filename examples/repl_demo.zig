const std = @import("std");
const phosphor = @import("phosphor");
const tui = phosphor.tui;

// Import widgets
const repl_mod = @import("repl");
const Repl = repl_mod.Repl;
const logview_mod = @import("logview");
const LogView = logview_mod.LogView;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize terminal
    try tui.init();
    defer tui.deinit();

    // Set cursor to dim color
    tui.setCursorColor("#666666");

    try tui.clearScreen();
    try tui.showCursor(true);

    // Get terminal size (mutable for resize handling)
    var size = tui.getSize();
    const header_height: u16 = 3;
    const log_start: u16 = header_height;
    const min_log_lines: u16 = 3; // Always show at least 3 log lines
    const max_input_rows: u16 = 10; // Cap input growth
    var current_input_rows: u16 = 1; // Track how many rows input is using

    // Create LogView for output
    var log = LogView.init(allocator, 1000); // Keep up to 1000 lines
    defer log.deinit();

    // Create REPL for input
    var repl = try Repl.init(allocator, .{
        .prompt = "phosphor> ",
    });
    defer repl.deinit();

    // Print header
    try printHeader(size);

    // Add welcome message to log
    try log.append("Welcome to Phosphor REPL Demo!");
    try log.append("Commands: help, clear, history, exit");
    try log.append("Ctrl+O inserts newline for multiline input");
    try log.append("");

    // Helper to calculate layout
    const calcLayout = struct {
        fn calc(rows: u16, hdr: u16, min_log: u16, input_rows: u16) struct { log_end: u16, input_start: u16 } {
            const available = if (rows > hdr + 1) rows - hdr - 1 else 1;
            const input_space = @min(input_rows, available -| min_log);
            const input_start = rows -| input_space;
            const log_end = if (input_start > hdr + 1) input_start - 2 else hdr;
            return .{ .log_end = log_end, .input_start = input_start };
        }
    }.calc;

    // Initial layout
    var layout = calcLayout(size.rows, header_height, min_log_lines, current_input_rows);

    // Initial render
    try renderLog(&log, log_start, layout.log_end, size.cols);
    current_input_rows = try renderInput(&repl, layout.input_start, max_input_rows, size.cols, allocator);
    try tui.flush();

    // Main loop
    var prev_input_rows: u16 = current_input_rows;

    while (true) {
        // Check for terminal resize
        if (tui.checkResize()) |new_size| {
            size = new_size;
            layout = calcLayout(size.rows, header_height, min_log_lines, current_input_rows);

            // Redraw everything with new layout
            try tui.clearScreen();
            try printHeader(size);
            try renderLog(&log, log_start, layout.log_end, size.cols);
            current_input_rows = try renderInput(&repl, layout.input_start, max_input_rows, size.cols, allocator);
            try tui.flush();
        }

        // Read and parse key (with timeout for resize checking)
        const maybe_key = try readKey();
        if (maybe_key == null) {
            continue; // Timeout - loop back to check for resize
        }
        const key = maybe_key.?;

        // Handle key
        const action = try repl.handleKey(key);

        switch (action) {
            .submit => {
                if (try repl.submit()) |text| {
                    defer allocator.free(text);

                    // Echo command to log (handle multiline)
                    var lines_iter = std.mem.splitScalar(u8, text, '\n');
                    var first = true;
                    while (lines_iter.next()) |line| {
                        if (first) {
                            try log.print("{s}{s}", .{ repl.getPrompt(), line });
                            first = false;
                        } else {
                            try log.print("... {s}", .{line});
                        }
                    }

                    // Handle commands
                    if (std.mem.eql(u8, text, "clear")) {
                        log.clear();
                        try log.append("Screen cleared.");
                    } else if (std.mem.eql(u8, text, "help")) {
                        try log.append("Commands: help, clear, history, exit");
                    } else if (std.mem.eql(u8, text, "history")) {
                        try log.print("History has {} entries", .{repl.history.count()});
                    } else if (std.mem.eql(u8, text, "exit")) {
                        break;
                    } else if (text.len > 0) {
                        try log.print("Unknown command: '{s}'. Type 'help' for commands.", .{text});
                    }

                    // Reset to single line and redraw everything
                    current_input_rows = 1;
                    prev_input_rows = 1;
                    layout = calcLayout(size.rows, header_height, min_log_lines, current_input_rows);
                    try clearToBottom(log_start, size.rows);
                    try renderLog(&log, log_start, layout.log_end, size.cols);
                }
            },
            .cancel => {
                repl.cancel();
                current_input_rows = 1;
                prev_input_rows = 1;
                layout = calcLayout(size.rows, header_height, min_log_lines, current_input_rows);
                try clearToBottom(log_start, size.rows);
                try renderLog(&log, log_start, layout.log_end, size.cols);
            },
            .eof => {
                break;
            },
            .clear_screen => {
                log.clear();
                try tui.clearScreen();
                try printHeader(size);
                layout = calcLayout(size.rows, header_height, min_log_lines, current_input_rows);
                try renderLog(&log, log_start, layout.log_end, size.cols);
            },
            .redraw, .none => {},
        }

        // Calculate new layout based on input size
        const new_input_rows = try renderInput(&repl, layout.input_start, max_input_rows, size.cols, allocator);

        // If input size changed, we need to recalculate layout and redraw
        if (new_input_rows != prev_input_rows) {
            current_input_rows = new_input_rows;
            const new_layout = calcLayout(size.rows, header_height, min_log_lines, current_input_rows);

            // Only redraw if layout actually changed
            if (new_layout.input_start != layout.input_start) {
                layout = new_layout;
                // Clear from log area down and redraw
                try clearToBottom(log_start, size.rows);
                try renderLog(&log, log_start, layout.log_end, size.cols);
                current_input_rows = try renderInput(&repl, layout.input_start, max_input_rows, size.cols, allocator);
            }
            prev_input_rows = current_input_rows;
        }

        try tui.flush();
    }

    // Cleanup - move cursor below content, don't clear screen
    try tui.moveTo(0, size.rows);
    try tui.printText("\n");
    try tui.flush();
}

fn printHeader(size: tui.Size) !void {
    try tui.moveTo(0, 0);
    try tui.printText("Phosphor REPL Demo");
    try tui.drawSizeIndicator(size); // Size in top-right
    try tui.moveTo(0, 1);
    try tui.printText("Ctrl+O: newline | Ctrl+C: cancel | Ctrl+D: exit");
    try tui.moveTo(0, 2);
    try tui.printText("────────────────────────────────────────────────────────────────");
}

fn renderLog(log: *const LogView, start_row: u16, end_row: u16, width: u16) !void {
    const view_height = end_row - start_row + 1;
    const visible = log.getVisibleLines(view_height);

    // Calculate where to start rendering (align to bottom)
    const empty_rows = view_height - visible.len;

    // Clear empty rows at top
    for (0..empty_rows) |i| {
        const row = start_row + @as(u16, @intCast(i));
        try tui.moveTo(0, row);
        try tui.printText("\x1b[K"); // Clear line
    }

    // Render visible lines
    for (visible, 0..) |line, i| {
        const row = start_row + @as(u16, @intCast(empty_rows + i));
        try tui.moveTo(0, row);
        try tui.printText("\x1b[K"); // Clear line

        // Truncate if too wide
        const display_len = @min(line.text.len, width);
        try tui.printText(line.text[0..display_len]);
    }
}

/// Render multiline input with soft wrapping. Returns number of display rows used.
fn renderInput(repl: *Repl, start_line: u16, max_lines: u16, width: u16, allocator: std.mem.Allocator) !u16 {
    const text = try repl.buffer.getText(allocator);
    defer allocator.free(text);

    const prompt = repl.getPrompt();
    const prompt_len: u16 = @intCast(prompt.len);
    const wrap_indent = "    "; // Indent for wrapped lines
    const wrap_indent_len: u16 = @intCast(wrap_indent.len);
    const newline_cont = "... "; // Continuation after explicit newline
    const newline_cont_len: u16 = @intCast(newline_cont.len);

    var rows_used: u16 = 0;
    var text_idx: usize = 0;
    var cursor_screen_row: u16 = 0;
    var cursor_screen_col: u16 = 0;
    const cursor_pos = repl.getCursor();
    var is_first_row = true;
    var after_newline = false;

    while (text_idx <= text.len and rows_used < max_lines) {
        const row = start_line + rows_used;
        try tui.moveTo(0, row);
        try tui.printText("\x1b[K"); // Clear line

        // Determine prefix for this row
        const prefix = if (is_first_row) prompt else if (after_newline) newline_cont else wrap_indent;
        const prefix_len_val = if (is_first_row) prompt_len else if (after_newline) newline_cont_len else wrap_indent_len;
        try tui.printText(prefix);

        // How much content fits on this row?
        const content_width: usize = if (width > prefix_len_val) width - prefix_len_val else 1;

        // Find how much text to show on this row
        var row_end = text_idx;
        var chars_on_row: usize = 0;
        while (row_end < text.len and chars_on_row < content_width) {
            if (text[row_end] == '\n') {
                break; // Stop at newline
            }
            row_end += 1;
            chars_on_row += 1;
        }

        // Print the content for this row
        if (row_end > text_idx) {
            try tui.printText(text[text_idx..row_end]);
        }

        // Check if cursor is on this row
        if (cursor_pos >= text_idx and cursor_pos <= row_end) {
            cursor_screen_row = row;
            cursor_screen_col = prefix_len_val + @as(u16, @intCast(cursor_pos - text_idx));
        }

        // Move past what we rendered
        is_first_row = false;
        after_newline = false;

        if (row_end < text.len and text[row_end] == '\n') {
            // Hit a newline - next row starts after it
            text_idx = row_end + 1;
            after_newline = true;
            // Check if cursor is at the newline position
            if (cursor_pos == row_end) {
                cursor_screen_row = row;
                cursor_screen_col = prefix_len_val + @as(u16, @intCast(chars_on_row));
            }
        } else if (row_end < text.len) {
            // Soft wrap - continue on next row
            text_idx = row_end;
        } else {
            // End of text
            text_idx = text.len + 1;
        }

        rows_used += 1;
    }

    // Ensure at least one row for empty input
    if (rows_used == 0) {
        const row = start_line;
        try tui.moveTo(0, row);
        try tui.printText("\x1b[K");
        try tui.printText(prompt);
        cursor_screen_row = row;
        cursor_screen_col = prompt_len;
        rows_used = 1;
    }

    // Position cursor
    try tui.moveTo(cursor_screen_col, cursor_screen_row);

    return rows_used;
}

fn clearLine(line: u16) !void {
    try tui.moveTo(0, line);
    try tui.printText("\x1b[K");
}

fn clearInputArea(start: u16, count: u16) !void {
    for (0..count) |i| {
        try clearLine(start + @as(u16, @intCast(i)));
    }
}

/// Clear from a row to the bottom of the screen
fn clearToBottom(start: u16, screen_height: u16) !void {
    var row = start;
    while (row < screen_height) : (row += 1) {
        try clearLine(row);
    }
}

/// Read a key with escape sequence handling
/// Returns null if no input within timeout (allows checking for resize)
fn readKey() !?Repl.Key {
    const stdin = std.fs.File.stdin();

    // Poll for input with 100ms timeout (allows resize check)
    var pfd = [_]std.posix.pollfd{.{
        .fd = stdin.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&pfd, 100);
    if (ready == 0) {
        return null; // Timeout - no input, let main loop check for resize
    }

    // Read first byte
    var buf: [1]u8 = undefined;
    _ = try stdin.read(&buf);
    const c = buf[0];

    // Control characters (Ctrl+A = 1, Ctrl+B = 2, etc.)
    if (c < 32) {
        return switch (c) {
            1 => .ctrl_a,      // Ctrl+A
            3 => .ctrl_c,      // Ctrl+C
            4 => .ctrl_d,      // Ctrl+D
            5 => .ctrl_e,      // Ctrl+E
            11 => .ctrl_k,     // Ctrl+K
            12 => .ctrl_l,     // Ctrl+L
            15 => .ctrl_o,     // Ctrl+O (insert newline)
            21 => .ctrl_u,     // Ctrl+U
            23 => .ctrl_w,     // Ctrl+W
            9 => .tab,         // Tab
            10, 13 => .enter,  // Enter (LF or CR)
            27 => blk: {       // Escape - might be start of sequence
                break :blk try readEscapeSequence(stdin);
            },
            else => .unknown,
        };
    }

    // Backspace (127 = DEL on most terminals)
    if (c == 127) {
        return .backspace;
    }

    // Regular printable ASCII
    if (c >= 32 and c < 127) {
        return .{ .char = c };
    }

    // UTF-8 multi-byte sequence
    if (c >= 0x80) {
        return try readUtf8Char(stdin, c);
    }

    return .unknown;
}

/// Read an escape sequence (called after receiving ESC)
fn readEscapeSequence(stdin: std.fs.File) !Repl.Key {
    // Use poll to check if more bytes are available
    // If not, it was just the Escape key
    var pfd = [_]std.posix.pollfd{.{
        .fd = stdin.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    // Short timeout to check for escape sequence
    const ready = try std.posix.poll(&pfd, 50); // 50ms timeout
    if (ready == 0) {
        return .escape; // Just Escape key
    }

    // Read next byte
    var buf: [1]u8 = undefined;
    _ = try stdin.read(&buf);

    if (buf[0] == '[') {
        // CSI sequence - read more bytes
        _ = try stdin.read(&buf);

        return switch (buf[0]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            '1' => blk: {
                // Could be 1;5C (Ctrl+Right) or 13;2u (Shift+Enter in kitty protocol)
                _ = try stdin.read(&buf);
                if (buf[0] == ';') {
                    _ = try stdin.read(&buf); // modifier
                    _ = try stdin.read(&buf); // direction/terminator
                    if (buf[0] == 'C') break :blk .ctrl_right;
                    if (buf[0] == 'D') break :blk .ctrl_left;
                } else if (buf[0] == '3') {
                    // ESC[13;2u = Shift+Enter (kitty keyboard protocol)
                    _ = try stdin.read(&buf);
                    if (buf[0] == ';') {
                        _ = try stdin.read(&buf); // modifier (2 = shift)
                        _ = try stdin.read(&buf); // 'u'
                        if (buf[0] == 'u') break :blk .shift_enter;
                    }
                }
                break :blk .unknown;
            },
            '3' => blk: {
                // Delete key: ESC[3~ or could be start of ESC[3;2u
                _ = try stdin.read(&buf);
                if (buf[0] == '~') break :blk .delete;
                break :blk .unknown;
            },
            else => .unknown,
        };
    }

    if (buf[0] == 'O') {
        // SS3 sequence (some terminals use this)
        _ = try stdin.read(&buf);
        return switch (buf[0]) {
            'H' => .home,
            'F' => .end,
            else => .unknown,
        };
    }

    // Alt+Enter: ESC followed by CR (13) or LF (10)
    if (buf[0] == 13 or buf[0] == 10) {
        return .alt_enter;
    }

    return .unknown;
}

/// Read a UTF-8 multi-byte character
fn readUtf8Char(stdin: std.fs.File, first_byte: u8) !Repl.Key {
    // Determine sequence length from first byte
    const len: usize = if (first_byte & 0xF0 == 0xF0) 4
        else if (first_byte & 0xE0 == 0xE0) 3
        else if (first_byte & 0xC0 == 0xC0) 2
        else return .unknown;

    var utf8_buf: [4]u8 = undefined;
    utf8_buf[0] = first_byte;

    // Read remaining bytes
    const bytes_read = try stdin.read(utf8_buf[1..len]);
    if (bytes_read != len - 1) {
        return .unknown;
    }

    // Decode UTF-8 to codepoint
    const codepoint = std.unicode.utf8Decode(utf8_buf[0..len]) catch return .unknown;
    return .{ .char = codepoint };
}
