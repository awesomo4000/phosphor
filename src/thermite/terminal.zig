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

    // Exit alternate screen buffer - restores main screen
    _ = std.posix.write(fd, EXIT_ALT_SCREEN) catch {};

    if (original_termios) |tios| {
        _ = try std.posix.tcsetattr(fd, .FLUSH, tios);
    }
}

pub fn clearScreen(fd: i32) !void {
    _ = try std.posix.write(fd, CLEAR_SCREEN ++ CURSOR_HOME);
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

/// Non-blocking read from terminal
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