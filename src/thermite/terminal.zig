const std = @import("std");
const builtin = @import("builtin");
const system = builtin.os.tag;

// ANSI escape sequences
pub const CURSOR_HOME = "\x1b[H";
pub const CLEAR_SCREEN = "\x1b[2J";
pub const HIDE_CURSOR = "\x1b[?25l";
pub const SHOW_CURSOR = "\x1b[?25h";
pub const RESET_ALL = "\x1b[0m";
pub const ENTER_ALT_SCREEN = "\x1b[?1049h";
pub const EXIT_ALT_SCREEN = "\x1b[?1049l";

pub const TerminalInfo = struct {
    fd: i32,
    width: u32,
    height: u32,
};

// Platform-specific termios
const termios = if (system == .windows) struct {
    // Windows doesn't have termios, we'll handle it differently
} else std.posix.termios;

var original_termios: ?termios = null;

// Module-level state for signal handler access
var terminal_fd: ?i32 = null;
var resize_pending: bool = false;

pub fn getTerminalInfo() !TerminalInfo {
    const timer = @import("startup_timer");
    timer.mark("  getTerminalInfo: opening /dev/tty");

    const tty_fd = try std.posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0);
    timer.mark("  getTerminalInfo: /dev/tty opened");

    // Get terminal size
    var winsize: std.posix.winsize = undefined;

    // Platform-specific ioctl
    switch (system) {
        .linux => _ = try std.os.linux.ioctl(tty_fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&winsize)),
        .macos => {
            // On macOS, we need to use the system ioctl
            const TIOCGWINSZ = 0x40087468; // macOS specific value
            _ = std.c.ioctl(tty_fd, TIOCGWINSZ, @intFromPtr(&winsize));
        },
        else => return error.UnsupportedPlatform,
    }
    timer.mark("  getTerminalInfo: ioctl done");

    return TerminalInfo{
        .fd = tty_fd,
        .width = winsize.col,
        .height = winsize.row,
    };
}

pub fn enterRawMode(fd: i32) !void {
    const timer = @import("startup_timer");

    if (system == .windows) {
        // TODO: Windows console mode
        return;
    }

    timer.mark("  enterRawMode: tcgetattr start");
    // Save original terminal settings
    var tios = try std.posix.tcgetattr(fd);
    original_termios = tios;
    timer.mark("  enterRawMode: tcgetattr done");

    // Modify for raw mode
    // Turn off:
    // - ECHO: Don't echo input characters
    // - ICANON: Disable canonical mode (line buffering)
    // - ISIG: Disable signals so Ctrl+C/Ctrl+Z are read as input
    // - IEXTEN: Disable implementation-defined input processing (Ctrl+O, Ctrl+V, etc.)
    // - IXON: Disable software flow control (Ctrl+S/Ctrl+Q)
    tios.lflag.ECHO = false;
    tios.lflag.ICANON = false;
    tios.lflag.ISIG = false; // Handle Ctrl+C ourselves
    tios.lflag.IEXTEN = false; // Handle Ctrl+O, Ctrl+V ourselves
    tios.iflag.IXON = false;
    tios.iflag.ICRNL = false; // Don't translate CR to NL
    tios.oflag.OPOST = false; // Disable output processing

    // Set minimum characters and timeout
    tios.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    tios.cc[@intFromEnum(std.posix.V.TIME)] = 1;

    timer.mark("  enterRawMode: tcsetattr FLUSH start");
    _ = try std.posix.tcsetattr(fd, .FLUSH, tios);
    timer.mark("  enterRawMode: tcsetattr FLUSH done");

    // Enter alternate screen buffer - gives us a clean slate and
    // tells the terminal this is a full-screen app (may improve resize behavior)
    _ = try std.posix.write(fd, ENTER_ALT_SCREEN);

    // Disable auto-wrap mode (DECAWM) - prevents unexpected wrapping when writing
    // to the last column. We use explicit cursor positioning instead.
    _ = try std.posix.write(fd, "\x1b[?7l");

    // NOTE: Don't enable sync output mode here - it buffers subsequent writes
    // (hideCursor, clearScreen) until the end marker is sent. Instead, sync
    // mode is enabled/disabled per-frame in renderDifferential().
}

pub fn exitRawMode(fd: i32) !void {
    if (system == .windows) {
        return;
    }

    // Disable synchronized output mode
    _ = std.posix.write(fd, "\x1b[?2026l") catch {};

    // Re-enable auto-wrap mode
    _ = std.posix.write(fd, "\x1b[?7h") catch {};

    // Exit alternate screen buffer - restores main screen
    _ = std.posix.write(fd, EXIT_ALT_SCREEN) catch {};

    if (original_termios) |tios| {
        _ = try std.posix.tcsetattr(fd, .FLUSH, tios);
    }
}

pub fn clearScreen(fd: i32) !void {
    _ = try std.posix.write(fd, CLEAR_SCREEN ++ CURSOR_HOME);
}

/// Clear screen with an explicit background color (for terminals that don't handle transparent well)
pub fn clearScreenWithBg(fd: i32, r: u8, g: u8, b: u8) !void {
    var buf: [64]u8 = undefined;
    // Set background color, clear screen, reset to default
    const seq = try std.fmt.bufPrint(&buf, "\x1b[48;2;{};{};{}m" ++ CLEAR_SCREEN ++ CURSOR_HOME ++ RESET_ALL, .{ r, g, b });
    _ = try std.posix.write(fd, seq);
}

/// Sync with the terminal - blocks until terminal has processed all prior output.
/// Uses a cursor position query (DSR) as a round-trip barrier.
/// Useful for measuring actual display latency vs write latency.
pub fn sync(fd: i32) !void {
    // Send Device Status Report - cursor position query
    _ = try std.posix.write(fd, "\x1b[6n");

    // Read until we get the response: \x1b[{row};{col}R
    // The response arriving means terminal has processed everything before the query
    var buf: [32]u8 = undefined;
    var total_read: usize = 0;

    while (total_read < buf.len) {
        const n = try std.posix.read(fd, buf[total_read..]);
        if (n == 0) break;
        total_read += n;

        // Look for 'R' which terminates the cursor position response
        if (std.mem.indexOfScalar(u8, buf[0..total_read], 'R') != null) {
            break;
        }
    }
}

/// Measure time for terminal to actually render (not just write completion).
/// Returns elapsed nanoseconds from write to terminal acknowledgment.
pub fn measureDisplayLatency(fd: i32) !i128 {
    const start = std.time.nanoTimestamp();
    try sync(fd);
    return std.time.nanoTimestamp() - start;
}

pub fn hideCursor(fd: i32) !void {
    _ = try std.posix.write(fd, HIDE_CURSOR);
}

pub fn showCursor(fd: i32) !void {
    _ = try std.posix.write(fd, SHOW_CURSOR);
}

pub fn moveCursor(fd: i32, x: u32, y: u32) !void {
    var buf: [32]u8 = undefined;
    const seq = try std.fmt.bufPrint(&buf, "\x1b[{};{}H", .{ y + 1, x + 1 });
    _ = try std.posix.write(fd, seq);
}

pub fn setForegroundColor(fd: i32, r: u8, g: u8, b: u8) !void {
    var buf: [32]u8 = undefined;
    const seq = try std.fmt.bufPrint(&buf, "\x1b[38;2;{};{};{}m", .{ r, g, b });
    _ = try std.posix.write(fd, seq);
}

pub fn setBackgroundColor(fd: i32, r: u8, g: u8, b: u8) !void {
    var buf: [32]u8 = undefined;
    const seq = try std.fmt.bufPrint(&buf, "\x1b[48;2;{};{};{}m", .{ r, g, b });
    _ = try std.posix.write(fd, seq);
}

pub fn resetColors(fd: i32) !void {
    _ = try std.posix.write(fd, RESET_ALL);
}

/// Non-blocking read from terminal (single byte - use readKeyEvent for escape sequences)
pub fn readKey(fd: i32) ?u8 {
    // Set non-blocking mode temporarily
    const old_flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch return null;
    const O_NONBLOCK = if (@import("builtin").os.tag == .macos) @as(c_int, 0x0004) else std.posix.O.NONBLOCK;
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, old_flags | O_NONBLOCK) catch return null;
    defer _ = std.posix.fcntl(fd, std.posix.F.SETFL, old_flags) catch {};

    var buf: [1]u8 = undefined;
    const result = std.posix.read(fd, &buf) catch return null;
    if (result > 0) {
        return buf[0];
    }
    return null;
}

/// Key event type for terminal input
pub const Key = union(enum) {
    // Regular characters (letters, numbers, symbols)
    char: u21,

    // Special keys
    enter,
    backspace,
    delete,
    tab,
    escape,
    insert,

    // Navigation
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,

    // Function keys (F1-F12)
    f: u4,

    // Control key combinations
    ctrl_a,
    ctrl_b,
    ctrl_c,
    ctrl_d,
    ctrl_e,
    ctrl_f,
    ctrl_g,
    ctrl_h,
    ctrl_i,
    ctrl_j,
    ctrl_k,
    ctrl_l,
    ctrl_m,
    ctrl_n,
    ctrl_o,
    ctrl_p,
    ctrl_q,
    ctrl_r,
    ctrl_s,
    ctrl_t,
    ctrl_u,
    ctrl_v,
    ctrl_w,
    ctrl_x,
    ctrl_y,
    ctrl_z,
    ctrl_left,
    ctrl_right,
    ctrl_up,
    ctrl_down,
    ctrl_home,
    ctrl_end,

    // Alt key combinations
    alt: u21, // Alt + any character
    alt_enter,

    // Shift combinations
    shift_enter,
    shift_tab,

    unknown,
};

/// Read a key event, parsing escape sequences for arrow keys, etc.
/// Returns null if no input available.
pub fn readKeyEvent(fd: i32) ?Key {
    // Set non-blocking mode temporarily
    const old_flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch return null;
    const O_NONBLOCK = if (@import("builtin").os.tag == .macos) @as(c_int, 0x0004) else std.posix.O.NONBLOCK;
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, old_flags | O_NONBLOCK) catch return null;
    defer _ = std.posix.fcntl(fd, std.posix.F.SETFL, old_flags) catch {};

    var buf: [16]u8 = undefined;
    var total: usize = 0;

    // Read first byte
    const n = std.posix.read(fd, buf[0..1]) catch return null;
    if (n == 0) return null;
    total = 1;

    // If it's an escape, try to read more bytes for the sequence
    if (buf[0] == 0x1b) {
        // Small delay to allow escape sequence bytes to arrive
        std.Thread.sleep(1 * std.time.ns_per_ms);

        // Try to read more bytes
        const more = std.posix.read(fd, buf[1..]) catch 0;
        total += more;
    }

    return parseKeySequence(buf[0..total]);
}

/// Parse a key sequence into a Key event
fn parseKeySequence(seq: []const u8) ?Key {
    if (seq.len == 0) return null;

    const first = seq[0];

    // Escape sequence
    if (first == 0x1b) {
        if (seq.len == 1) return .escape;

        // CSI sequences: ESC [
        if (seq.len >= 2 and seq[1] == '[') {
            return parseCSISequence(seq[2..]);
        }

        // SS3 sequences: ESC O (used by some terminals for arrow keys/F keys)
        if (seq.len >= 2 and seq[1] == 'O') {
            if (seq.len >= 3) {
                return switch (seq[2]) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    'P' => .{ .f = 1 },
                    'Q' => .{ .f = 2 },
                    'R' => .{ .f = 3 },
                    'S' => .{ .f = 4 },
                    else => .escape,
                };
            }
            return .escape;
        }

        // Alt+Enter: ESC followed by Enter
        if (seq.len >= 2 and (seq[1] == 13 or seq[1] == 10)) {
            return .alt_enter;
        }

        return .escape;
    }

    // Control characters
    return switch (first) {
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
        127 => .backspace,
        else => if (first >= 32 and first < 127) .{ .char = first } else .unknown,
    };
}

/// Parse CSI sequence (after ESC [)
fn parseCSISequence(seq: []const u8) Key {
    if (seq.len == 0) return .escape;

    // Simple arrow keys: ESC [ A/B/C/D
    if (seq.len == 1) {
        return switch (seq[0]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            'Z' => .shift_tab,
            else => .unknown,
        };
    }

    // Modified keys: ESC [ 1 ; <mod> <key>
    // mod: 2=shift, 3=alt, 4=shift+alt, 5=ctrl, 6=ctrl+shift, 7=ctrl+alt, 8=ctrl+shift+alt
    if (seq.len >= 3 and seq[0] == '1' and seq[1] == ';') {
        const modifier = seq[2];
        if (seq.len >= 4) {
            const key_char = seq[3];
            // Ctrl modifier (5)
            if (modifier == '5') {
                return switch (key_char) {
                    'A' => .ctrl_up,
                    'B' => .ctrl_down,
                    'C' => .ctrl_right,
                    'D' => .ctrl_left,
                    'H' => .ctrl_home,
                    'F' => .ctrl_end,
                    else => .unknown,
                };
            }
            // Shift modifier (2) - just return base key for now
            if (modifier == '2') {
                return switch (key_char) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    else => .unknown,
                };
            }
            // Alt modifier (3) - treat as base key for now
            if (modifier == '3') {
                return switch (key_char) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    else => .unknown,
                };
            }
        }
        return .unknown;
    }

    // Keypad/extended keys: ESC [ <num> ~
    // 1~=Home, 2~=Insert, 3~=Delete, 4~=End, 5~=PgUp, 6~=PgDn
    // 11~-15~ = F1-F5, 17~-21~ = F6-F10, 23~-24~ = F11-F12
    if (seq.len >= 2 and seq[seq.len - 1] == '~') {
        // Parse the number before ~
        var num: u8 = 0;
        for (seq[0 .. seq.len - 1]) |c| {
            if (c >= '0' and c <= '9') {
                num = num * 10 + (c - '0');
            } else if (c == ';') {
                // Modifier follows, ignore for now
                break;
            }
        }
        return switch (num) {
            1 => .home,
            2 => .insert,
            3 => .delete,
            4 => .end,
            5 => .page_up,
            6 => .page_down,
            11 => .{ .f = 1 },
            12 => .{ .f = 2 },
            13 => .{ .f = 3 },
            14 => .{ .f = 4 },
            15 => .{ .f = 5 },
            17 => .{ .f = 6 },
            18 => .{ .f = 7 },
            19 => .{ .f = 8 },
            20 => .{ .f = 9 },
            21 => .{ .f = 10 },
            23 => .{ .f = 11 },
            24 => .{ .f = 12 },
            else => .unknown,
        };
    }

    return .unknown;
}

// ============================================================================
// Signal Handling
// ============================================================================

/// SIGWINCH handler - just sets flag (signal-safe)
fn handleSigwinch(_: c_int) callconv(.c) void {
    resize_pending = true;
}

/// Cleanup signal handler - restores terminal state AND re-raises signal
fn handleCleanupSignal(sig: c_int) callconv(.c) void {
    if (terminal_fd) |fd| {
        // Restore terminal state (signal-safe writes only)
        _ = std.posix.write(fd, "\x1b[?2026l") catch {}; // Disable sync output
        _ = std.posix.write(fd, EXIT_ALT_SCREEN) catch {};
        _ = std.posix.write(fd, SHOW_CURSOR) catch {};
        _ = std.posix.write(fd, RESET_ALL) catch {};
        if (original_termios) |tios| {
            _ = std.posix.tcsetattr(fd, .FLUSH, tios) catch {};
        }
    }

    // Re-raise signal with default handler so process actually dies
    const sig_num: u6 = @intCast(sig);
    var act = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    _ = std.posix.sigaction(sig_num, &act, null);
    _ = std.posix.raise(sig_num) catch {};
}

/// Install signal handlers for cleanup (Ctrl+C, etc.) and resize (SIGWINCH)
pub fn installSignalHandlers(fd: i32) void {
    terminal_fd = fd;

    if (system == .windows) return;

    // SIGWINCH for resize - don't restart syscalls (let poll return EINTR)
    var winch_act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigwinch },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    _ = std.posix.sigaction(std.posix.SIG.WINCH, &winch_act, null);

    // Cleanup signals - SIGINT (Ctrl+C), SIGTERM, SIGHUP
    var cleanup_act = std.posix.Sigaction{
        .handler = .{ .handler = handleCleanupSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    _ = std.posix.sigaction(std.posix.SIG.INT, &cleanup_act, null);
    _ = std.posix.sigaction(std.posix.SIG.TERM, &cleanup_act, null);
    _ = std.posix.sigaction(std.posix.SIG.HUP, &cleanup_act, null);
}

/// Check if resize is pending without clearing the flag
/// Use this to skip rendering when another resize is imminent
pub fn isResizePending() bool {
    return resize_pending;
}

/// Query current terminal size directly (for validation before output)
pub fn getCurrentSize(fd: i32) ?struct { width: u32, height: u32 } {
    // Zero-initialize to detect ioctl failures (would leave garbage otherwise)
    var winsize: std.posix.winsize = std.mem.zeroes(std.posix.winsize);

    const result: c_int = switch (system) {
        .linux => @bitCast(std.os.linux.ioctl(fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&winsize))),
        .macos => blk: {
            const TIOCGWINSZ = 0x40087468;
            break :blk std.c.ioctl(fd, TIOCGWINSZ, @intFromPtr(&winsize));
        },
        else => return null,
    };

    // ioctl returns -1 on error
    if (result == -1) return null;

    if (winsize.col > 0 and winsize.row > 0) {
        return .{ .width = winsize.col, .height = winsize.row };
    }
    return null;
}

/// Check if resize is pending, returns new size if so
pub fn checkResize(fd: i32) ?struct { width: u32, height: u32 } {
    if (!resize_pending) return null;
    resize_pending = false;

    // Query fresh terminal size
    var winsize: std.posix.winsize = undefined;
    switch (system) {
        .linux => _ = std.os.linux.ioctl(fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&winsize)),
        .macos => {
            const TIOCGWINSZ = 0x40087468;
            _ = std.c.ioctl(fd, TIOCGWINSZ, @intFromPtr(&winsize));
        },
        else => return null,
    }

    if (winsize.col > 0 and winsize.row > 0) {
        return .{ .width = winsize.col, .height = winsize.row };
    }
    return null;
}

pub const PollResult = enum { ready, timeout, resize };

/// Poll for input with timeout, handles EINTR from signals
pub fn pollInput(fd: i32, timeout_ms: i32) !PollResult {
    var pfd = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    const ready = std.posix.poll(&pfd, timeout_ms) catch |err| {
        if (err == error.Interrupted) {
            // Signal interrupted poll - check for resize
            if (resize_pending) return .resize;
            return .timeout;
        }
        return err;
    };

    if (ready > 0) return .ready;
    if (resize_pending) return .resize;
    return .timeout;
}