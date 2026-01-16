const std = @import("std");
const posix = std.posix;

/// Terminal capabilities detected at runtime
pub const Capabilities = struct {
    /// Color support tier
    color: ColorTier = .basic,
    /// Unicode rendering width calculation method
    unicode: UnicodeMethod = .wcwidth,
    /// Kitty keyboard protocol support
    kitty_keyboard: bool = false,
    /// Kitty graphics protocol support
    kitty_graphics: bool = false,
    /// Sixel graphics support
    sixel: bool = false,
    /// Synchronized output support (flicker-free rendering)
    synchronized_output: bool = false,
    /// OSC 8 hyperlink support
    hyperlinks: bool = false,
    /// Terminal name (if detected)
    terminal: Terminal = .unknown,

    pub const ColorTier = enum {
        /// No color support
        none,
        /// 8 basic colors (ANSI 30-37, 40-47)
        basic,
        /// 256 color palette
        @"256",
        /// 24-bit true color (16 million colors)
        truecolor,

        pub fn supportsRgb(self: ColorTier) bool {
            return self == .truecolor;
        }

        pub fn supports256(self: ColorTier) bool {
            return self == .@"256" or self == .truecolor;
        }
    };

    pub const UnicodeMethod = enum {
        /// Use wcwidth (standard, may be inaccurate for emoji)
        wcwidth,
        /// Use Unicode 2027 mode (accurate)
        unicode,
    };

    pub const Terminal = enum {
        unknown,
        // Modern terminals with full features
        iterm2,
        kitty,
        wezterm,
        alacritty,
        ghostty,
        // Windows terminals
        windows_terminal,
        conpty,
        // Limited terminals
        apple_terminal, // macOS Terminal.app - no true color!
        linux_console,
        // Multiplexers
        tmux,
        screen,
        zellij,
        // VS Code integrated terminal
        vscode,
        // SSH/remote
        xterm,
    };
};

/// Control sequences for terminal queries
pub const ctlseqs = struct {
    /// Primary Device Attributes - most terminals respond to this
    pub const primary_device_attrs = "\x1b[c";
    /// XTVERSION - get terminal name and version
    pub const xtversion = "\x1b[>0q";
    /// Query Kitty keyboard protocol
    pub const csi_u_query = "\x1b[?u";
    /// Query Kitty graphics protocol
    pub const kitty_graphics_query = "\x1b_Gi=1,a=q\x1b\\";
    /// Synchronized output enable/disable
    pub const sync_set = "\x1b[?2026h";
    pub const sync_reset = "\x1b[?2026l";
};

/// Detect terminal capabilities from environment variables
/// This is fast but may not be accurate for all terminals
///
/// Environment variable overrides (for debugging):
/// - PHOSPHOR_COLOR: "truecolor", "256", "basic", or "none"
/// - PHOSPHOR_DEBUG_CAPS: "1" to print detected capabilities
pub fn detectFromEnv() Capabilities {
    var caps = Capabilities{};

    // Check for color mode override first
    if (getEnv("PHOSPHOR_COLOR")) |color_override| {
        if (std.mem.eql(u8, color_override, "truecolor")) {
            caps.color = .truecolor;
        } else if (std.mem.eql(u8, color_override, "256")) {
            caps.color = .@"256";
        } else if (std.mem.eql(u8, color_override, "basic")) {
            caps.color = .basic;
        } else if (std.mem.eql(u8, color_override, "none")) {
            caps.color = .none;
        }
        // Continue with terminal detection for other features
    }

    // Track if we have a manual color override
    const has_color_override = getEnv("PHOSPHOR_COLOR") != null;

    // Check TERM_PROGRAM first (most specific)
    if (getEnv("TERM_PROGRAM")) |prog| {
        if (std.mem.eql(u8, prog, "Apple_Terminal")) {
            caps.terminal = .apple_terminal;
            if (!has_color_override) caps.color = .@"256"; // Terminal.app lies about true color
            caps.synchronized_output = false;
            return caps;
        } else if (std.mem.eql(u8, prog, "iTerm.app")) {
            caps.terminal = .iterm2;
            caps.color = .truecolor;
            caps.kitty_graphics = false; // iTerm uses its own protocol
            caps.synchronized_output = true;
            caps.hyperlinks = true;
            return caps;
        } else if (std.mem.eql(u8, prog, "WezTerm")) {
            caps.terminal = .wezterm;
            caps.color = .truecolor;
            caps.kitty_graphics = true;
            caps.kitty_keyboard = true;
            caps.synchronized_output = true;
            caps.hyperlinks = true;
            caps.unicode = .unicode;
            return caps;
        } else if (std.mem.eql(u8, prog, "vscode")) {
            caps.terminal = .vscode;
            caps.color = .truecolor;
            caps.synchronized_output = true;
            return caps;
        } else if (std.mem.eql(u8, prog, "ghostty")) {
            caps.terminal = .ghostty;
            caps.color = .truecolor;
            caps.kitty_graphics = true;
            caps.kitty_keyboard = true;
            caps.synchronized_output = true;
            caps.hyperlinks = true;
            return caps;
        }
    }

    // Check for Kitty
    if (getEnv("KITTY_WINDOW_ID")) |_| {
        caps.terminal = .kitty;
        caps.color = .truecolor;
        caps.kitty_graphics = true;
        caps.kitty_keyboard = true;
        caps.synchronized_output = true;
        caps.hyperlinks = true;
        caps.unicode = .unicode;
        return caps;
    }

    // Check for Windows Terminal
    if (getEnv("WT_SESSION")) |_| {
        caps.terminal = .windows_terminal;
        caps.color = .truecolor;
        caps.synchronized_output = true;
        caps.hyperlinks = true;
        return caps;
    }

    // Check for Alacritty
    if (getEnv("ALACRITTY_WINDOW_ID")) |_| {
        caps.terminal = .alacritty;
        caps.color = .truecolor;
        caps.synchronized_output = true;
        return caps;
    }

    // Check for tmux (affects capabilities)
    // Important: tmux sets COLORTERM=truecolor, but the outer terminal might not support it
    // We use passthrough to detect the actual outer terminal capabilities
    if (getEnv("TMUX")) |_| {
        caps.terminal = .tmux;
        caps.synchronized_output = true;

        // Try to detect outer terminal via passthrough
        // If outer terminal responds to XTVERSION → modern → truecolor safe
        // If timeout → legacy (like Apple Terminal) → use 256-color
        if (!has_color_override) {
            if (probeOuterTerminalViaTmux()) {
                caps.color = .truecolor;
            } else {
                caps.color = .@"256"; // Conservative fallback for legacy terminals
            }
        }
        // Return early - don't let COLORTERM override our passthrough detection
        return caps;
    }

    // Check for Zellij
    if (getEnv("ZELLIJ")) |_| {
        caps.terminal = .zellij;
        caps.color = .truecolor;
        caps.synchronized_output = true;
    }

    // Check COLORTERM for true color hint
    if (getEnv("COLORTERM")) |ct| {
        if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")) {
            caps.color = .truecolor;
        }
    }

    // Fallback: check TERM for basic capability hints
    if (getEnv("TERM")) |term| {
        if (caps.color != .truecolor) {
            if (std.mem.indexOf(u8, term, "256color") != null) {
                caps.color = .@"256";
            } else if (std.mem.indexOf(u8, term, "color") != null or
                std.mem.indexOf(u8, term, "xterm") != null)
            {
                caps.color = .basic;
            }
        }

        // Detect xterm
        if (std.mem.startsWith(u8, term, "xterm")) {
            if (caps.terminal == .unknown) {
                caps.terminal = .xterm;
            }
        }

        // Linux console
        if (std.mem.eql(u8, term, "linux")) {
            caps.terminal = .linux_console;
            caps.color = .basic;
        }
    }

    // Debug output if requested - write to fd 2 (stderr) directly
    if (getEnv("PHOSPHOR_DEBUG_CAPS")) |_| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            \\
            \\=== Phosphor Capabilities Debug ===
            \\  Terminal: {s}
            \\  Color: {s}
            \\  Sync output: {}
            \\  TERM_PROGRAM: {s}
            \\  TERM: {s}
            \\  COLORTERM: {s}
            \\===================================
            \\
        , .{
            @tagName(caps.terminal),
            @tagName(caps.color),
            caps.synchronized_output,
            getEnv("TERM_PROGRAM") orelse "(not set)",
            getEnv("TERM") orelse "(not set)",
            getEnv("COLORTERM") orelse "(not set)",
        }) catch "";
        _ = posix.write(2, msg) catch {};
    }

    return caps;
}

/// Get environment variable, returning null if not set
fn getEnv(name: []const u8) ?[]const u8 {
    return posix.getenv(name);
}

/// Probe outer terminal via tmux passthrough to detect if it's modern.
/// Returns true if outer terminal responds to XTVERSION (modern terminal).
/// Returns false on timeout (legacy terminal like Apple Terminal).
fn probeOuterTerminalViaTmux() bool {
    // Check current passthrough state
    const check_result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "tmux", "show", "-p", "allow-passthrough" },
    }) catch return true; // If we can't check, assume modern (safer for user experience)
    defer std.heap.page_allocator.free(check_result.stdout);
    defer std.heap.page_allocator.free(check_result.stderr);

    const was_enabled = std.mem.indexOf(u8, check_result.stdout, "on") != null;

    // Enable passthrough if needed
    if (!was_enabled) {
        _ = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "tmux", "set", "-p", "allow-passthrough", "on" },
        }) catch return true; // If we can't enable, assume modern

        // Verify it changed
        const verify_result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "tmux", "show", "-p", "allow-passthrough" },
        }) catch return true;
        defer std.heap.page_allocator.free(verify_result.stdout);
        defer std.heap.page_allocator.free(verify_result.stderr);

        if (std.mem.indexOf(u8, verify_result.stdout, "on") == null) {
            return true; // Couldn't enable passthrough, assume modern
        }

        // Small delay for tmux to process config change
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Query XTVERSION via passthrough
    const is_modern = queryXtversionViaPassthrough();

    // Restore passthrough state if we changed it
    if (!was_enabled) {
        _ = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "tmux", "set", "-p", "allow-passthrough", "off" },
        }) catch {};
    }

    return is_modern;
}

/// Send XTVERSION query via tmux passthrough and check for response.
/// Returns true if we got a response (modern terminal).
fn queryXtversionViaPassthrough() bool {
    const fd: posix.fd_t = 0; // stdin

    // Save terminal state
    const original = posix.tcgetattr(fd) catch return true;

    // Set raw mode
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    posix.tcsetattr(fd, .FLUSH, raw) catch return true;

    defer posix.tcsetattr(fd, .FLUSH, original) catch {};

    // XTVERSION query: \x1b[>0q
    // Doubled for passthrough: \x1b\x1b[>0q
    // Full: \x1bPtmux;\x1b\x1b[>0q\x1b\\
    _ = posix.write(fd, "\x1bPtmux;\x1b\x1b[>0q\x1b\\") catch return true;

    // Poll with 50ms timeout (modern terminals respond in <10ms, legacy don't respond at all)
    var fds = [_]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const poll_result = posix.poll(&fds, 50) catch return true;
    if (poll_result == 0) {
        return false; // Timeout - legacy terminal
    }

    // Got a response - modern terminal
    // Drain any response data
    var buf: [256]u8 = undefined;
    _ = posix.read(fd, &buf) catch {};

    return true;
}

/// Format color using the appropriate method for the terminal's capabilities
pub fn formatFgColor(caps: *const Capabilities, r: u8, g: u8, b: u8, buf: []u8) []const u8 {
    return switch (caps.color) {
        .truecolor => std.fmt.bufPrint(buf, "\x1b[38;2;{d};{d};{d}m", .{ r, g, b }) catch "",
        .@"256" => blk: {
            const idx = rgbTo256(r, g, b);
            break :blk std.fmt.bufPrint(buf, "\x1b[38;5;{d}m", .{idx}) catch "";
        },
        .basic => blk: {
            const idx = rgbToBasic(r, g, b);
            break :blk std.fmt.bufPrint(buf, "\x1b[{d}m", .{30 + idx}) catch "";
        },
        .none => "",
    };
}

/// Format background color using the appropriate method for the terminal's capabilities
pub fn formatBgColor(caps: *const Capabilities, r: u8, g: u8, b: u8, buf: []u8) []const u8 {
    return switch (caps.color) {
        .truecolor => std.fmt.bufPrint(buf, "\x1b[48;2;{d};{d};{d}m", .{ r, g, b }) catch "",
        .@"256" => blk: {
            const idx = rgbTo256(r, g, b);
            break :blk std.fmt.bufPrint(buf, "\x1b[48;5;{d}m", .{idx}) catch "";
        },
        .basic => blk: {
            const idx = rgbToBasic(r, g, b);
            break :blk std.fmt.bufPrint(buf, "\x1b[{d}m", .{40 + idx}) catch "";
        },
        .none => "",
    };
}

/// Convert RGB to 256-color palette index
pub fn rgbTo256(r: u8, g: u8, b: u8) u8 {
    // Check if it's a grayscale
    if (r == g and g == b) {
        if (r < 8) return 16; // black
        if (r > 248) return 231; // white
        // Grayscale ramp is 232-255 (24 shades)
        return @intCast(232 + ((@as(u16, r) - 8) * 24 / 240));
    }

    // 6x6x6 color cube (indices 16-231)
    // Map 0-255 to 0-5 for each channel
    const ri: u16 = if (r < 48) 0 else if (r < 115) 1 else @min((@as(u16, r) - 35) / 40, 5);
    const gi: u16 = if (g < 48) 0 else if (g < 115) 1 else @min((@as(u16, g) - 35) / 40, 5);
    const bi: u16 = if (b < 48) 0 else if (b < 115) 1 else @min((@as(u16, b) - 35) / 40, 5);

    return @intCast(16 + 36 * ri + 6 * gi + bi);
}

/// Convert RGB to basic 8-color index
pub fn rgbToBasic(r: u8, g: u8, b: u8) u8 {
    // Simple threshold-based conversion
    const ri: u8 = if (r >= 128) 1 else 0;
    const gi: u8 = if (g >= 128) 1 else 0;
    const bi: u8 = if (b >= 128) 1 else 0;

    // ANSI color order: black, red, green, yellow, blue, magenta, cyan, white
    // Bit pattern: BGR
    return bi * 4 + gi * 2 + ri;
}

// Tests
test "detectFromEnv returns default for unknown terminal" {
    // This test runs in an environment where TERM_PROGRAM etc may not be set
    const caps = detectFromEnv();
    _ = caps; // Just verify it doesn't crash
}

test "rgbTo256 grayscale" {
    try std.testing.expectEqual(@as(u8, 16), rgbTo256(0, 0, 0));
    try std.testing.expectEqual(@as(u8, 231), rgbTo256(255, 255, 255));
    // Mid-gray
    const mid = rgbTo256(128, 128, 128);
    try std.testing.expect(mid >= 232 and mid <= 255);
}

test "rgbTo256 colors" {
    // Pure red should be in the color cube
    const red = rgbTo256(255, 0, 0);
    try std.testing.expect(red >= 16 and red <= 231);

    // Pure green
    const green = rgbTo256(0, 255, 0);
    try std.testing.expect(green >= 16 and green <= 231);

    // Pure blue
    const blue = rgbTo256(0, 0, 255);
    try std.testing.expect(blue >= 16 and blue <= 231);
}

test "rgbToBasic" {
    try std.testing.expectEqual(@as(u8, 0), rgbToBasic(0, 0, 0)); // black
    try std.testing.expectEqual(@as(u8, 7), rgbToBasic(255, 255, 255)); // white
    try std.testing.expectEqual(@as(u8, 1), rgbToBasic(255, 0, 0)); // red
    try std.testing.expectEqual(@as(u8, 2), rgbToBasic(0, 255, 0)); // green
    try std.testing.expectEqual(@as(u8, 4), rgbToBasic(0, 0, 255)); // blue
}
