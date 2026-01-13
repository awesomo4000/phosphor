const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Terminal state management - saves and restores terminal configuration.
/// Handles cleanup on crashes via signal handlers.
pub const TerminalState = struct {
    /// Original termios before we modified it
    original_termios: posix.termios,

    /// File descriptor for the terminal
    fd: posix.fd_t,

    /// Track what modes we've enabled (for cleanup)
    modes_enabled: EnabledModes = .{},

    pub const EnabledModes = struct {
        raw_mode: bool = false,
        alternate_screen: bool = false,
        mouse_tracking: bool = false,
        bracketed_paste: bool = false,
        kitty_keyboard: bool = false,
        cursor_hidden: bool = false,
    };

    /// Global instance for signal handler access
    pub var global: ?*TerminalState = null;

    /// Initialize terminal state - saves current state and installs signal handlers
    pub fn init() !TerminalState {
        const fd = std.fs.File.stdin().handle;

        // Save original termios
        const original = posix.tcgetattr(fd) catch |err| {
            if (err == error.ENOTTY) {
                return error.NotATerminal;
            }
            return err;
        };

        var state = TerminalState{
            .original_termios = original,
            .fd = fd,
        };

        // Install signal handlers for cleanup
        state.installSignalHandlers();

        // Note: Caller must set `global` pointer after storing the result,
        // since returning by value would make a dangling pointer here.
        // Example: terminal_state = TerminalState.init(); TerminalState.global = &terminal_state.?;

        return state;
    }

    /// Restore terminal to original state
    pub fn deinit(self: *TerminalState) void {
        // Disable any modes we enabled
        self.restoreAllModes();

        // Restore original termios
        posix.tcsetattr(self.fd, .FLUSH, self.original_termios) catch |err| {
            std.log.err("Failed to restore terminal: {}", .{err});
        };

        // Clear global
        if (global == self) {
            global = null;
        }
    }

    /// Enable raw mode
    pub fn enableRawMode(self: *TerminalState) !void {
        var raw = self.original_termios;

        // Input flags
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;

        // Output flags
        raw.oflag.OPOST = false;

        // Local flags
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        // Control flags
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;

        // Read settings: return immediately with whatever is available
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(self.fd, .FLUSH, raw);
        self.modes_enabled.raw_mode = true;
    }

    /// Send escape sequence to terminal
    fn sendSequence(seq: []const u8) void {
        const stdout = std.fs.File.stdout();
        _ = stdout.write(seq) catch {};
    }

    /// Enable alternate screen buffer
    pub fn enableAlternateScreen(self: *TerminalState) void {
        sendSequence("\x1b[?1049h");
        self.modes_enabled.alternate_screen = true;
    }

    /// Enable mouse tracking
    pub fn enableMouseTracking(self: *TerminalState) void {
        sendSequence("\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h");
        self.modes_enabled.mouse_tracking = true;
    }

    /// Enable bracketed paste
    pub fn enableBracketedPaste(self: *TerminalState) void {
        sendSequence("\x1b[?2004h");
        self.modes_enabled.bracketed_paste = true;
    }

    /// Enable kitty keyboard protocol
    pub fn enableKittyKeyboard(self: *TerminalState) void {
        sendSequence("\x1b[>1u");
        self.modes_enabled.kitty_keyboard = true;
    }

    /// Hide cursor
    pub fn hideCursor(self: *TerminalState) void {
        sendSequence("\x1b[?25l");
        self.modes_enabled.cursor_hidden = true;
    }

    /// Show cursor
    pub fn showCursor(self: *TerminalState) void {
        sendSequence("\x1b[?25h");
        self.modes_enabled.cursor_hidden = false;
    }

    /// Restore all enabled modes to their defaults
    pub fn restoreAllModes(self: *TerminalState) void {
        // Restore in reverse order of typical enabling

        // Show cursor if hidden
        if (self.modes_enabled.cursor_hidden) {
            sendSequence("\x1b[?25h");
            self.modes_enabled.cursor_hidden = false;
        }

        // Disable kitty keyboard
        if (self.modes_enabled.kitty_keyboard) {
            sendSequence("\x1b[<u");
            self.modes_enabled.kitty_keyboard = false;
        }

        // Disable bracketed paste
        if (self.modes_enabled.bracketed_paste) {
            sendSequence("\x1b[?2004l");
            self.modes_enabled.bracketed_paste = false;
        }

        // Disable mouse tracking
        if (self.modes_enabled.mouse_tracking) {
            sendSequence("\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l");
            self.modes_enabled.mouse_tracking = false;
        }

        // Exit alternate screen
        if (self.modes_enabled.alternate_screen) {
            sendSequence("\x1b[?1049l");
            self.modes_enabled.alternate_screen = false;
        }
    }

    /// Install signal handlers for cleanup on crash/interrupt
    pub fn installSignalHandlers(self: *TerminalState) void {
        _ = self;
        const Handler = struct {
            fn handle(sig: c_int) callconv(.c) void {
                // Restore terminal state
                if (global) |state| {
                    state.restoreAllModes();
                    posix.tcsetattr(state.fd, .FLUSH, state.original_termios) catch {};
                }

                // Re-raise the signal with default handler
                const sig_num: u8 = @intCast(sig);
                var act = posix.Sigaction{
                    .handler = .{ .handler = posix.SIG.DFL },
                    .mask = switch (builtin.os.tag) {
                        .macos => 0,
                        else => posix.sigemptyset(),
                    },
                    .flags = 0,
                };
                posix.sigaction(sig_num, &act, null);
                _ = posix.raise(sig_num) catch {};
            }
        };

        // Install for SIGINT (Ctrl+C), SIGTERM, SIGHUP
        var act = posix.Sigaction{
            .handler = .{ .handler = Handler.handle },
            .mask = switch (builtin.os.tag) {
                .macos => 0,
                else => posix.sigemptyset(),
            },
            .flags = 0,
        };

        _ = posix.sigaction(posix.SIG.INT, &act, null);
        _ = posix.sigaction(posix.SIG.TERM, &act, null);
        _ = posix.sigaction(posix.SIG.HUP, &act, null);
    }

    /// Panic handler - restore terminal before printing panic message
    pub fn panicHandler(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
        // Restore terminal first
        if (global) |state| {
            state.restoreAllModes();
            posix.tcsetattr(state.fd, .FLUSH, state.original_termios) catch {};
        }

        // Then call default panic handler
        std.builtin.default_panic(msg, trace, ret_addr);
    }
};

// Tests
test "basic init/deinit" {
    // Can't test without a real terminal, but at least check compilation
    _ = TerminalState;
}
