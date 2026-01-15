const std = @import("std");
const fs = std.fs;
const posix = std.posix;

// Terminal state management
pub const TerminalState = @import("terminal_state.zig").TerminalState;

// ANSI escape codes
pub const ESC = "\x1b";
pub const CSI = ESC ++ "[";

// CGA color constants
pub const Color = struct {
    pub const BLACK = 0;
    pub const BLUE = 1;
    pub const GREEN = 2;
    pub const CYAN = 3;
    pub const RED = 4;
    pub const MAGENTA = 5;
    pub const BROWN = 6;
    pub const LIGHTGRAY = 7;
    pub const DARKGRAY = 8;
    pub const LIGHTBLUE = 9;
    pub const LIGHTGREEN = 10;
    pub const LIGHTCYAN = 11;
    pub const LIGHTRED = 12;
    pub const LIGHTMAGENTA = 13;
    pub const YELLOW = 14;
    pub const WHITE = 15;
};

// Terminal state (managed by TerminalState module)
var terminal_state: ?TerminalState = null;

// Current colors
var current_fg: u8 = Color.WHITE;
var current_bg: u8 = Color.BLACK;

// Resize handling - just a flag, size is always queried fresh via ioctl
var resize_pending: bool = false;

// Output buffer for stdout (used by writer)
threadlocal var stdout_buffer: [4096]u8 = undefined;

// Terminal size
pub const Size = struct {
    rows: u16,
    cols: u16,
};

// SIGWINCH handler - sets flag, actual work done in main loop
fn handleSigwinch(_: c_int) callconv(.c) void {
    resize_pending = true;
}

// Install the resize signal handler
pub fn installResizeHandler() void {
    const builtin = @import("builtin");
    switch (builtin.os.tag) {
        .linux, .macos => {
            var act: posix.Sigaction = .{
                .handler = .{ .handler = handleSigwinch },
                .mask = posix.sigemptyset(),
                .flags = 0, // Don't restart - let SIGWINCH interrupt poll()
            };
            _ = posix.sigaction(posix.SIG.WINCH, &act, null);
        },
        else => {}, // Windows doesn't have SIGWINCH
    }
}

/// Check if a resize is pending (without consuming it)
pub fn resizePending() bool {
    return resize_pending;
}

// Check if resize occurred, returns new size if so
pub fn checkResize() ?Size {
    if (resize_pending) {
        resize_pending = false;
        return getSize(); // Fresh ioctl query - fast syscall, no need to cache
    }
    return null;
}

/// Draw size indicator in top-right corner (e.g., "80x24")
pub fn drawSizeIndicator(size: Size) !void {
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}x{d}", .{ size.cols, size.rows }) catch return;
    const x = if (size.cols > text.len) size.cols - @as(u16, @intCast(text.len)) else 0;
    try moveTo(x, 0);
    try printText(text);
}

// Initialize TUI with optional default background color
pub fn init() !void {
    // Initialize terminal state (saves original termios, installs signal handlers)
    terminal_state = TerminalState.init() catch |err| {
        if (err == error.NotATerminal) {
            std.debug.print("Error: This program requires a TTY terminal to run.\n", .{});
            std.debug.print("Try running it in an actual terminal instead of via a build command.\n", .{});
            return error.NoTTY;
        }
        return err;
    };

    // Set global pointer for signal handler access (must be done after storing)
    TerminalState.global = &terminal_state.?;

    // Enable raw mode via the state manager
    try terminal_state.?.enableRawMode();

    // Install resize handler
    installResizeHandler();
}

// Initialize TUI with specific default colors
pub fn initWithColors(default_fg: u8, default_bg: u8) !void {
    current_fg = default_fg;
    current_bg = default_bg;
    try init();
    try setColor(default_fg, default_bg);
}

// Cleanup TUI
pub fn deinit() void {
    if (terminal_state) |*state| {
        state.deinit();
        terminal_state = null;
    }
}

// Clear screen
pub fn clearScreen() !void {
    var writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &writer.interface;
    try stdout.print("{s}2J{s}H", .{ CSI, CSI });
    try stdout.flush();
}

// Show/hide cursor
pub fn showCursor(visible: bool) !void {
    var writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &writer.interface;
    if (visible) {
        try stdout.print("{s}?25h", .{CSI});
    } else {
        try stdout.print("{s}?25l", .{CSI});
    }
    try stdout.flush();
}

// Set cursor color (OSC 12 sequence)
// Color can be a name ("red", "gray") or hex ("#RRGGBB")
// Note: Not all terminals support this
pub fn setCursorColor(color: []const u8) void {
    if (terminal_state) |*state| {
        state.setCursorColor(color);
    }
}

// Reset cursor color to terminal default
pub fn resetCursorColor() void {
    if (terminal_state) |*state| {
        state.resetCursorColor();
    }
}

// Enable bracketed paste mode (sends ESC[200~ / ESC[201~ around pastes)
pub fn enableBracketedPaste() void {
    if (terminal_state) |*state| {
        state.enableBracketedPaste();
    }
}

// Move cursor to position using x,y coordinates (0-based)
pub fn moveTo(x: u16, y: u16) !void {
    var writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &writer.interface;
    // Terminal uses 1-based indexing and row,col order, so convert
    try stdout.print("{s}{d};{d}H", .{ CSI, y + 1, x + 1 });
    try stdout.flush();
}

// Legacy: Move cursor using row,col (will be deprecated)
pub fn moveCursor(row: u16, col: u16) !void {
    try moveTo(col, row);
}

// CGA to ANSI color mapping table
const kCgaToAnsi = [16]u8{
    30, 34, 32, 36, 31, 35, 33, 37,  // 0-7: black, blue, green, cyan, red, magenta, brown/yellow, white
    90, 94, 92, 96, 91, 95, 93, 97   // 8-15: bright versions
};

// Set foreground and background colors
pub fn setColor(fg: u8, bg: u8) !void {
    var writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &writer.interface;
    const fg_code = kCgaToAnsi[fg & 0x0F];
    const bg_code = kCgaToAnsi[bg & 0x0F] + 10;
    try stdout.print("{s}{d};{d}m", .{ CSI, fg_code, bg_code });
    try stdout.flush();
    current_fg = fg;
    current_bg = bg;
}

// Get current background color
pub fn getCurrentBackground() u8 {
    return current_bg;
}

// Get current foreground color
pub fn getCurrentForeground() u8 {
    return current_fg;
}

// Reset all attributes
pub fn resetAttributes() !void {
    var writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &writer.interface;
    try stdout.print("{s}0m", .{CSI});
    try stdout.flush();
}

// Get terminal size using ioctl (reliable, doesn't interfere with stdin)
pub fn getSize() Size {
    const stdin = std.fs.File.stdin();
    var winsize: std.posix.winsize = undefined;

    // Platform-specific ioctl
    const builtin = @import("builtin");
    switch (builtin.os.tag) {
        .linux => {
            _ = std.os.linux.ioctl(stdin.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&winsize));
        },
        .macos => {
            const TIOCGWINSZ = 0x40087468; // macOS specific value
            _ = std.c.ioctl(stdin.handle, TIOCGWINSZ, @intFromPtr(&winsize));
        },
        else => {
            return .{ .rows = 24, .cols = 80 };
        },
    }

    if (winsize.row > 0 and winsize.col > 0) {
        return .{ .rows = winsize.row, .cols = winsize.col };
    }

    // Fallback to default size
    return .{ .rows = 24, .cols = 80 };
}

// Wait for a single keypress
pub fn readKey() !u8 {
    const stdin = std.fs.File.stdin();
    var buf: [1]u8 = undefined;
    _ = try stdin.read(&buf);
    return buf[0];
}

// Read a key without blocking (returns null if no key available)
pub fn readKeyNonBlocking() !?u8 {
    const stdin = std.fs.File.stdin();
    
    // Use poll to check if data is available
    var pfd = [_]posix.pollfd{.{
        .fd = stdin.handle,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    
    const ready = try posix.poll(&pfd, 0); // 0 timeout = non-blocking
    if (ready == 0) return null;
    
    var buf: [1]u8 = undefined;
    const bytes_read = try stdin.read(&buf);
    if (bytes_read == 0) return null;
    return buf[0];
}

// Print text at current cursor position
pub fn print(comptime fmt: []const u8, args: anytype) !void {
    var writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &writer.interface;
    try stdout.print(fmt, args);
    try stdout.flush();
}

// Print simple text without formatting
pub fn printText(text: []const u8) !void {
    var writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &writer.interface;
    try stdout.writeAll(text);
    try stdout.flush();
}

// Flush output buffer
pub fn flush() !void {
    const stdout = std.fs.File.stdout();
    try stdout.sync();
}

// Box drawing options
pub const BoxOpts = struct {
    style: Style = .square,
    
    pub const Style = enum {
        square,   // Default: sharp corners with single lines
        rounded,  // Rounded corners
        single,   // Single lines (same as square)
        double,   // Double lines
        dotted,   // Dotted/dashed lines
        heavy,    // Heavy/bold lines
    };
};

// Legacy box style enum (for backwards compatibility)
pub const BoxStyle = enum {
    Single,
    Double,
    Rounded,
};

// Draw a box using x,y coordinates (0-based)
pub fn drawRect(x: u16, y: u16, width: u16, height: u16, opts: BoxOpts) !void {
    const BoxChars = struct {
        tl: []const u8,
        tr: []const u8,
        bl: []const u8,
        br: []const u8,
        h: []const u8,
        v: []const u8,
    };
    
    const chars: BoxChars = switch (opts.style) {
        .square, .single => .{ .tl = "┌", .tr = "┐", .bl = "└", .br = "┘", .h = "─", .v = "│" },
        .rounded => .{ .tl = "╭", .tr = "╮", .bl = "╰", .br = "╯", .h = "─", .v = "│" },
        .double => .{ .tl = "╔", .tr = "╗", .bl = "╚", .br = "╝", .h = "═", .v = "║" },
        .dotted => .{ .tl = "┌", .tr = "┐", .bl = "└", .br = "┘", .h = "╌", .v = "╎" },
        .heavy => .{ .tl = "┏", .tr = "┓", .bl = "┗", .br = "┛", .h = "━", .v = "┃" },
    };
    
    // Ensure dimensions are valid
    if (width < 2 or height < 2) return;
    
    // Draw corners
    try moveTo(x, y);
    try printText(chars.tl); // Top-left
    
    try moveTo(x + width - 1, y);
    try printText(chars.tr); // Top-right
    
    try moveTo(x, y + height - 1);
    try printText(chars.bl); // Bottom-left
    
    try moveTo(x + width - 1, y + height - 1);
    try printText(chars.br); // Bottom-right
    
    // Draw horizontal borders (excluding corners)
    if (width > 2) {
        for (1..width - 1) |i| {
            try moveTo(x + @as(u16, @intCast(i)), y);
            try printText(chars.h);
            try moveTo(x + @as(u16, @intCast(i)), y + height - 1);
            try printText(chars.h);
        }
    }
    
    // Draw vertical borders (excluding corners)
    if (height > 2) {
        for (1..height - 1) |i| {
            try moveTo(x, y + @as(u16, @intCast(i)));
            try printText(chars.v);
            try moveTo(x + width - 1, y + @as(u16, @intCast(i)));
            try printText(chars.v);
        }
    }
}

// Draw a box with title text
pub fn drawRectWithTitle(x: u16, y: u16, width: u16, height: u16, opts: BoxOpts, title: []const u8) !void {
    // Draw the box first
    try drawRect(x, y, width, height, opts);
    
    // Overlay the title if it fits
    if (title.len > 0 and title.len + 4 < width) {
        const title_x = x + (width - @as(u16, @intCast(title.len))) / 2;
        
        // Only draw if we won't overwrite corners
        if (title_x > x + 2 and title_x + title.len < x + width - 2) {
            try moveTo(title_x - 1, y);
            try printText(" ");
            try printText(title);
            try printText(" ");
        }
    }
}

// Draw a box with title and bottom text
pub fn drawRectWithTitleAndBottom(x: u16, y: u16, width: u16, height: u16, opts: BoxOpts, title: []const u8, bottom_text: []const u8) !void {
    // Draw the box first
    try drawRect(x, y, width, height, opts);
    
    // Overlay the title if it fits
    if (title.len > 0 and title.len + 4 < width) {
        const title_x = x + (width - @as(u16, @intCast(title.len))) / 2;
        
        // Only draw if we won't overwrite corners
        if (title_x > x + 2 and title_x + title.len < x + width - 2) {
            try moveTo(title_x - 1, y);
            try printText(" ");
            try printText(title);
            try printText(" ");
        }
    }
    
    // Overlay the bottom text if it fits
    if (bottom_text.len > 0 and bottom_text.len + 4 < width) {
        const bottom_x = x + (width - @as(u16, @intCast(bottom_text.len))) / 2;
        
        // Only draw if we won't overwrite corners
        if (bottom_x > x + 2 and bottom_x + bottom_text.len < x + width - 2) {
            try moveTo(bottom_x - 1, y + height - 1);
            try printText(" ");
            try printText(bottom_text);
            try printText(" ");
        }
    }
}


pub fn drawBoxWithTitle(row: u16, col: u16, width: u16, height: u16, style: BoxStyle, title: []const u8) !void {
    try drawBoxWithTitleAndColors(row, col, width, height, style, title, current_fg, current_bg);
}

pub fn drawBoxWithTitleAndBottom(row: u16, col: u16, width: u16, height: u16, style: BoxStyle, title: []const u8, bottom_text: []const u8) !void {
    try drawBoxWithTitleBottomAndColors(row, col, width, height, style, title, bottom_text, current_fg, current_bg);
}

// Draw a simple box from top-left to bottom-right with optional style
pub fn drawBox(top_row: u16, left_col: u16, bottom_row: u16, right_col: u16, style: BoxStyle) !void {
    const BoxChars = struct {
        tl: []const u8,
        tr: []const u8,
        bl: []const u8,
        br: []const u8,
        h: []const u8,
        v: []const u8,
    };
    
    const chars: BoxChars = switch (style) {
        .Single => .{ .tl = "┌", .tr = "┐", .bl = "└", .br = "┘", .h = "─", .v = "│" },
        .Double => .{ .tl = "╔", .tr = "╗", .bl = "╚", .br = "╝", .h = "═", .v = "║" },
        .Rounded => .{ .tl = "╭", .tr = "╮", .bl = "╰", .br = "╯", .h = "─", .v = "│" },
    };
    
    // Ensure coordinates are valid
    if (right_col <= left_col or bottom_row <= top_row) return;
    
    const width = right_col - left_col + 1;
    const height = bottom_row - top_row + 1;
    
    // Draw corners
    try moveCursor(top_row, left_col);
    try printText(chars.tl); // Top-left
    
    try moveCursor(top_row, right_col);
    try printText(chars.tr); // Top-right
    
    try moveCursor(bottom_row, left_col);
    try printText(chars.bl); // Bottom-left
    
    try moveCursor(bottom_row, right_col);
    try printText(chars.br); // Bottom-right
    
    // Draw horizontal borders (excluding corners)
    if (width > 2) {
        try drawHLine(top_row, left_col + 1, width - 2, chars.h);
        try drawHLine(bottom_row, left_col + 1, width - 2, chars.h);
    }
    
    // Draw vertical borders (excluding corners)
    if (height > 2) {
        try drawVLine(top_row + 1, left_col, height - 2, chars.v);
        try drawVLine(top_row + 1, right_col, height - 2, chars.v);
    }
}

// Fill a rectangular area with a character
pub fn fillRect(row: u16, col: u16, width: u16, height: u16, char: []const u8) !void {
    for (0..height) |y| {
        try moveCursor(row + @as(u16, @intCast(y)), col);
        for (0..width) |_| {
            try print("{s}", .{char});
        }
    }
}

// Fill a rectangular area with spaces (useful for backgrounds)
pub fn fillBackground(row: u16, col: u16, width: u16, height: u16) !void {
    try fillRect(row, col, width, height, " ");
}

// Center text horizontally
pub fn centerText(row: u16, text: []const u8, total_width: u16) !void {
    const col = (total_width - @as(u16, @intCast(text.len))) / 2;
    try moveCursor(row, col);
    try print("{s}", .{text});
}

// Draw a horizontal line starting at (row, col) for length characters
pub fn drawHLine(row: u16, col: u16, length: u16, char: []const u8) !void {
    var i: u16 = 0;
    while (i < length) : (i += 1) {
        try moveCursor(row, col + i);
        try printText(char);
    }
}

// Draw a vertical line starting at (row, col) for length characters
pub fn drawVLine(row: u16, col: u16, length: u16, char: []const u8) !void {
    var i: u16 = 0;
    while (i < length) : (i += 1) {
        try moveCursor(row + i, col);
        try printText(char);
    }
}

// Draw a box with a title
pub fn drawBoxWithTitleAndColors(row: u16, col: u16, width: u16, height: u16, style: BoxStyle, title: []const u8, fg: u8, bg: u8) !void {
    // Save current colors
    const saved_fg = current_fg;
    const saved_bg = current_bg;
    
    // Set box colors
    try setColor(fg, bg);
    
    // Draw the box using corner coordinates
    const bottom_row = row + height - 1;
    const right_col = col + width - 1;
    try drawBox(row, col, bottom_row, right_col, style);
    
    // Then overlay the title in the top border
    if (title.len > 0 and title.len + 4 < width) {
        // Calculate centered position for title
        const title_start = col + (width - @as(u16, @intCast(title.len))) / 2;
        
        // Only draw if we won't overwrite corners (leave at least 2 chars on each side)
        if (title_start > col + 2 and title_start + title.len < col + width - 2) {
            try moveCursor(row, title_start - 1);
            try printText(" ");
            try printText(title);
            try printText(" ");
        }
    }
    
    // Restore original colors
    try setColor(saved_fg, saved_bg);
}

// Draw a box with a title and bottom text
pub fn drawBoxWithTitleBottomAndColors(row: u16, col: u16, width: u16, height: u16, style: BoxStyle, title: []const u8, bottom_text: []const u8, fg: u8, bg: u8) !void {
    // Save current colors
    const saved_fg = current_fg;
    const saved_bg = current_bg;
    
    // Set box colors
    try setColor(fg, bg);
    
    // Draw the box using corner coordinates
    const bottom_row = row + height - 1;
    const right_col = col + width - 1;
    try drawBox(row, col, bottom_row, right_col, style);
    
    // Overlay the title in the top border
    if (title.len > 0 and title.len + 4 < width) {
        // Calculate centered position for title
        const title_start = col + (width - @as(u16, @intCast(title.len))) / 2;
        
        // Only draw if we won't overwrite corners (leave at least 2 chars on each side)
        if (title_start > col + 2 and title_start + title.len < col + width - 2) {
            try moveCursor(row, title_start - 1);
            try printText(" ");
            try printText(title);
            try printText(" ");
        }
    }
    
    // Overlay the bottom text in the bottom border
    if (bottom_text.len > 0 and bottom_text.len + 4 < width) {
        // Calculate centered position for bottom text
        const bottom_start = col + (width - @as(u16, @intCast(bottom_text.len))) / 2;
        
        // Only draw if we won't overwrite corners (leave at least 2 chars on each side)
        if (bottom_start > col + 2 and bottom_start + bottom_text.len < col + width - 2) {
            try moveCursor(bottom_row, bottom_start - 1);
            try printText(" ");
            try printText(bottom_text);
            try printText(" ");
        }
    }
    
    // Restore original colors
    try setColor(saved_fg, saved_bg);
}

// Note: Raw mode is now managed by TerminalState module