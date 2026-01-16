const std = @import("std");
const posix = std.posix;
const capabilities = @import("capabilities.zig");

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = posix.write(1, msg) catch {};
}

fn printRaw(s: []const u8) void {
    _ = posix.write(1, s) catch {};
}

/// Result of color query using the DA1 trick
const ColorQueryResult = struct {
    osc11_response: ?[]const u8 = null,
    da1_response: ?[]const u8 = null,
    /// True if OSC 11 response uses BEL terminator (legacy terminal like Apple Terminal)
    uses_bel_terminator: bool = false,

    const Static = struct {
        var response_buf: [512]u8 = undefined;
    };
};

/// Query terminal color using the DA1 trick for fast detection.
/// Sends OSC 11 + DA1 together. If terminal doesn't support OSC 11,
/// DA1 response comes back immediately and we can bail without waiting.
fn queryColorWithDA1Trick(fd: posix.fd_t, timeout_ms: i32) ColorQueryResult {
    var result = ColorQueryResult{};

    // Save original terminal settings
    const original = posix.tcgetattr(fd) catch return result;

    // Set raw mode to read response
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0; // Non-blocking
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    posix.tcsetattr(fd, .FLUSH, raw) catch return result;

    defer posix.tcsetattr(fd, .FLUSH, original) catch {};

    // Send BOTH queries together: OSC 11 + DA1
    // Terminals respond in order, so if we get DA1 without OSC 11,
    // we know OSC 11 is not supported and can bail immediately.
    _ = posix.write(fd, "\x1b]11;?\x1b\\" ++ "\x1b[c") catch return result;

    var fds = [_]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    // Read responses - may get OSC 11, DA1, or both
    var total_read: usize = 0;
    var attempts: u32 = 0;
    const max_attempts: u32 = 5; // Multiple reads in case responses come separately

    while (attempts < max_attempts) : (attempts += 1) {
        const poll_result = posix.poll(&fds, timeout_ms) catch break;
        if (poll_result == 0) break; // Timeout

        const n = posix.read(fd, ColorQueryResult.Static.response_buf[total_read..]) catch break;
        if (n == 0) break;
        total_read += n;

        // Check if we have both responses or can bail early
        const data = ColorQueryResult.Static.response_buf[0..total_read];

        // Look for DA1 response: \x1b[?...c
        const has_da1 = std.mem.indexOf(u8, data, "\x1b[?") != null and
                        std.mem.indexOfScalar(u8, data, 'c') != null;

        // Look for OSC 11 response: \x1b]11;rgb:... terminated by \x07 or \x1b\\
        const has_osc11 = std.mem.indexOf(u8, data, "\x1b]11;") != null;

        if (has_da1 and !has_osc11) {
            // Got DA1 but no OSC 11 - terminal doesn't support color query
            // Bail immediately - no need to wait
            break;
        }

        if (has_osc11 and has_da1) {
            // Got both responses - we're done
            break;
        }

        // If we only have OSC 11 so far, keep reading for DA1
        // (short timeout for subsequent reads)
    }

    if (total_read == 0) return result;

    const data = ColorQueryResult.Static.response_buf[0..total_read];

    // Parse OSC 11 response
    if (std.mem.indexOf(u8, data, "\x1b]11;")) |osc_start| {
        // Find terminator - either BEL (\x07) or ST (\x1b\\)
        var osc_end: usize = data.len;

        if (std.mem.indexOfScalarPos(u8, data, osc_start, 0x07)) |bel_pos| {
            osc_end = bel_pos + 1;
            result.uses_bel_terminator = true;
        } else if (std.mem.indexOfPos(u8, data, osc_start, "\x1b\\")) |st_pos| {
            osc_end = st_pos + 2;
            result.uses_bel_terminator = false;
        }

        result.osc11_response = data[osc_start..osc_end];
    }

    // Parse DA1 response
    if (std.mem.indexOf(u8, data, "\x1b[?")) |da1_start| {
        if (std.mem.indexOfScalarPos(u8, data, da1_start, 'c')) |c_pos| {
            result.da1_response = data[da1_start .. c_pos + 1];
        }
    }

    return result;
}

/// Query terminal with XTVERSION and return response (or null on timeout)
fn queryXtversion(fd: posix.fd_t) ?[]const u8 {
    // Save original terminal settings
    const original = posix.tcgetattr(fd) catch return null;

    // Set raw mode to read response
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0; // Non-blocking
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    posix.tcsetattr(fd, .FLUSH, raw) catch return null;

    defer posix.tcsetattr(fd, .FLUSH, original) catch {};

    // Send XTVERSION query: \x1b[>0q
    _ = posix.write(fd, "\x1b[>0q") catch return null;

    // Poll for response with 100ms timeout
    var fds = [_]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const poll_result = posix.poll(&fds, 100) catch return null;
    if (poll_result == 0) return null; // Timeout

    // Read response into static buffer
    const Static = struct {
        var response_buf: [256]u8 = undefined;
    };

    const n = posix.read(fd, &Static.response_buf) catch return null;
    if (n == 0) return null;

    return Static.response_buf[0..n];
}

/// Format bytes as readable string (escape non-printable)
fn formatResponse(response: []const u8, buf: []u8) []const u8 {
    var i: usize = 0;
    for (response) |c| {
        if (i + 4 >= buf.len) break;
        if (c == 0x1b) {
            buf[i] = '\\';
            buf[i + 1] = 'x';
            buf[i + 2] = '1';
            buf[i + 3] = 'b';
            i += 4;
        } else if (c == '\\') {
            buf[i] = '\\';
            buf[i + 1] = '\\';
            i += 2;
        } else if (c >= 0x20 and c < 0x7f) {
            buf[i] = c;
            i += 1;
        } else {
            // Hex escape for other non-printable
            const hex = "0123456789abcdef";
            buf[i] = '\\';
            buf[i + 1] = 'x';
            buf[i + 2] = hex[c >> 4];
            buf[i + 3] = hex[c & 0xf];
            i += 4;
        }
    }
    return buf[0..i];
}

pub fn main() void {
    const caps = capabilities.detectFromEnv();

    print("\n=== Phosphor Terminal Capabilities ===\n\n", .{});
    print("Detected terminal: {s}\n", .{@tagName(caps.terminal)});
    print("Color support:     {s}\n", .{@tagName(caps.color)});
    print("Sync output:       {}\n", .{caps.synchronized_output});
    print("Kitty keyboard:    {}\n", .{caps.kitty_keyboard});
    print("Kitty graphics:    {}\n", .{caps.kitty_graphics});
    print("Hyperlinks:        {}\n", .{caps.hyperlinks});

    print("\n--- Environment Variables ---\n", .{});
    print("TERM_PROGRAM: {s}\n", .{posix.getenv("TERM_PROGRAM") orelse "(not set)"});
    print("TERM:         {s}\n", .{posix.getenv("TERM") orelse "(not set)"});
    print("COLORTERM:    {s}\n", .{posix.getenv("COLORTERM") orelse "(not set)"});
    print("KITTY_WINDOW_ID: {s}\n", .{posix.getenv("KITTY_WINDOW_ID") orelse "(not set)"});
    print("WT_SESSION:   {s}\n", .{posix.getenv("WT_SESSION") orelse "(not set)"});

    print("\n--- Color Test ---\n", .{});
    print("Testing color output for detected mode ({s}):\n\n", .{@tagName(caps.color)});

    switch (caps.color) {
        .truecolor => {
            // True color test
            printRaw("  \x1b[48;2;255;0;0m RED \x1b[0m");
            printRaw("  \x1b[48;2;0;255;0m GRN \x1b[0m");
            printRaw("  \x1b[48;2;0;0;255m BLU \x1b[0m");
            printRaw("  \x1b[48;2;128;0;128m PUR \x1b[0m\n");
        },
        .@"256" => {
            // 256 color test
            printRaw("  \x1b[48;5;196m RED \x1b[0m"); // 196 = bright red
            printRaw("  \x1b[48;5;46m GRN \x1b[0m"); // 46 = bright green
            printRaw("  \x1b[48;5;21m BLU \x1b[0m"); // 21 = bright blue
            printRaw("  \x1b[48;5;129m PUR \x1b[0m\n"); // 129 = purple
        },
        .basic => {
            // Basic 8 color test
            printRaw("  \x1b[41m RED \x1b[0m");
            printRaw("  \x1b[42m GRN \x1b[0m");
            printRaw("  \x1b[44m BLU \x1b[0m");
            printRaw("  \x1b[45m MAG \x1b[0m\n");
        },
        .none => {
            printRaw("  (no color support detected)\n");
        },
    }

    print("\nIf colors look wrong, try: PHOSPHOR_COLOR=256 ./caps-check\n", .{});

    // Runtime query section
    print("\n--- Runtime Queries ---\n", .{});
    print("(These query the actual terminal, not env vars)\n\n", .{});

    // Need a tty fd - try stdin
    const tty_fd: posix.fd_t = 0; // stdin

    // Query XTVERSION (separate query, just for info)
    print("XTVERSION query (\\x1b[>0q): ", .{});
    if (queryXtversion(tty_fd)) |response| {
        var fmt_buf: [512]u8 = undefined;
        const formatted = formatResponse(response, &fmt_buf);
        print("{s}\n", .{formatted});

        // Try to extract terminal name from response
        // Format: \x1bP>|TerminalName Version\x1b\\
        if (std.mem.indexOf(u8, response, "|")) |start| {
            const name_start = start + 1;
            if (std.mem.indexOf(u8, response[name_start..], "\x1b")) |end| {
                print("  -> Parsed: {s}\n", .{response[name_start .. name_start + end]});
            }
        }
    } else {
        print("(no response - timeout or unsupported)\n", .{});
    }

    // Combined OSC 11 + DA1 query using the DA1 trick
    print("\n--- DA1 Trick (OSC 11 + DA1 combined) ---\n", .{});
    print("Sending OSC 11 + DA1 together with 50ms timeout...\n", .{});

    const color_result = queryColorWithDA1Trick(tty_fd, 50);

    print("DA1 response: ", .{});
    if (color_result.da1_response) |response| {
        var fmt_buf: [512]u8 = undefined;
        const formatted = formatResponse(response, &fmt_buf);
        print("{s}\n", .{formatted});
    } else {
        print("(none)\n", .{});
    }

    print("OSC 11 response: ", .{});
    if (color_result.osc11_response) |response| {
        var fmt_buf: [512]u8 = undefined;
        const formatted = formatResponse(response, &fmt_buf);
        print("{s}\n", .{formatted});

        // Parse the color
        if (std.mem.indexOf(u8, response, "rgb:")) |start| {
            const color_start = start + 4;
            if (std.mem.indexOfAny(u8, response[color_start..], "\x1b\x07")) |end| {
                print("  -> Color: {s}\n", .{response[color_start .. color_start + end]});
            }
        }

        print("  -> Terminator: {s}\n", .{if (color_result.uses_bel_terminator) "BEL (\\x07) - legacy" else "ST (\\x1b\\\\) - modern"});
    } else {
        print("(none - terminal does not support color queries)\n", .{});
    }

    // Interpretation
    print("\n--- Interpretation ---\n", .{});
    if (color_result.osc11_response == null and color_result.da1_response != null) {
        print("Terminal supports DA1 but NOT OSC 11 color queries.\n", .{});
        print("Detection was FAST (no timeout needed).\n", .{});
    } else if (color_result.osc11_response != null) {
        if (color_result.uses_bel_terminator) {
            print("Terminal uses BEL terminator -> likely LEGACY terminal (Apple Terminal, etc.)\n", .{});
            print("RECOMMENDATION: Use 256-color mode for safety.\n", .{});
        } else {
            print("Terminal uses ST terminator -> likely MODERN terminal.\n", .{});
            print("RECOMMENDATION: Truecolor should be safe.\n", .{});
        }
    } else {
        print("No response to either query - very limited terminal.\n", .{});
    }

    // If we're in tmux, try the passthrough hack to query outer terminal
    if (posix.getenv("TMUX") != null) {
        print("\n--- Tmux Passthrough Test (EXPERIMENTAL) ---\n", .{});
        print("Detected tmux session. Attempting to query OUTER terminal...\n\n", .{});

        // Check current passthrough state
        const check_result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "tmux", "show", "-p", "allow-passthrough" },
        }) catch |err| {
            print("Failed to check passthrough state: {}\n", .{err});
            print("\n==========================================\n\n", .{});
            return;
        };
        defer std.heap.page_allocator.free(check_result.stdout);
        defer std.heap.page_allocator.free(check_result.stderr);

        const was_enabled = std.mem.indexOf(u8, check_result.stdout, "on") != null;
        print("Current allow-passthrough: {s}\n", .{if (was_enabled) "on" else "off"});

        // Enable passthrough if needed
        if (!was_enabled) {
            print("Enabling passthrough temporarily...\n", .{});
            _ = std.process.Child.run(.{
                .allocator = std.heap.page_allocator,
                .argv = &.{ "tmux", "set", "-p", "allow-passthrough", "on" },
            }) catch |err| {
                print("Failed to enable passthrough: {}\n", .{err});
                print("\n==========================================\n\n", .{});
                return;
            };

            // Verify it actually changed
            const verify_result = std.process.Child.run(.{
                .allocator = std.heap.page_allocator,
                .argv = &.{ "tmux", "show", "-p", "allow-passthrough" },
            }) catch |err| {
                print("Failed to verify passthrough state: {}\n", .{err});
                print("\n==========================================\n\n", .{});
                return;
            };
            defer std.heap.page_allocator.free(verify_result.stdout);
            defer std.heap.page_allocator.free(verify_result.stderr);

            const now_enabled = std.mem.indexOf(u8, verify_result.stdout, "on") != null;
            if (!now_enabled) {
                print("ERROR: Failed to enable passthrough (still showing: {s})\n", .{std.mem.trim(u8, verify_result.stdout, "\n\r\t ")});
                print("\n==========================================\n\n", .{});
                return;
            }
            print("Verified: passthrough is now on\n", .{});

            // Small delay to let tmux process the config change
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }

        // Now query through passthrough
        // The passthrough format is: DCS tmux ; <escaped content> ST
        // All ESC in content need to be doubled

        // First, test if passthrough works at all with a simple DA1 query
        print("Testing passthrough with DA1 query first...\n", .{});
        const da1_test = queryDA1ViaTmux(tty_fd, 200, true);
        if (da1_test) |response| {
            var fmt_buf: [256]u8 = undefined;
            print("  DA1 via passthrough: {s}\n", .{formatResponse(response, &fmt_buf)});
            print("  -> Passthrough is WORKING!\n\n", .{});
        } else {
            print("  DA1 via passthrough: (no response)\n", .{});
            print("  -> Passthrough may not be working or outer terminal doesn't respond.\n\n", .{});
        }

        // Try XTVERSION through passthrough - modern terminals respond, Apple Terminal won't
        print("Testing XTVERSION via passthrough...\n", .{});
        const xtver_test = queryXtversionViaTmux(tty_fd, 200, true);
        if (xtver_test) |response| {
            var fmt_buf: [256]u8 = undefined;
            print("  XTVERSION via passthrough: {s}\n", .{formatResponse(response, &fmt_buf)});
            print("  -> Outer terminal is MODERN (supports XTVERSION)\n\n", .{});
        } else {
            print("  XTVERSION via passthrough: (no response)\n", .{});
            print("  -> Outer terminal is likely LEGACY (no XTVERSION support)\n", .{});
            print("  -> RECOMMENDATION: Use 256-color mode!\n\n", .{});
        }

        // Now try OSC 11 with BEL terminator (Apple Terminal style)
        print("Sending passthrough-wrapped OSC 11 query (BEL terminator, 200ms timeout)...\n", .{});

        const passthrough_result = queryOuterTerminalViaTmux(tty_fd, 200, true);

        print("Outer terminal OSC 11: ", .{});
        if (passthrough_result.osc11_response) |response| {
            var fmt_buf: [512]u8 = undefined;
            const formatted = formatResponse(response, &fmt_buf);
            print("{s}\n", .{formatted});
            print("  -> Terminator: {s}\n", .{if (passthrough_result.uses_bel_terminator) "BEL (\\x07) - LEGACY" else "ST (\\x1b\\\\) - modern"});

            if (passthrough_result.uses_bel_terminator) {
                print("\n*** OUTER TERMINAL IS LEGACY (e.g., Apple Terminal) ***\n", .{});
                print("*** Should use 256-color even though tmux claims truecolor ***\n", .{});
            } else {
                print("\n*** OUTER TERMINAL IS MODERN ***\n", .{});
                print("*** Truecolor is safe ***\n", .{});
            }
        } else {
            print("(no response or passthrough failed)\n", .{});
        }

        // Restore passthrough state if we changed it
        if (!was_enabled) {
            print("\nRestoring passthrough to off...\n", .{});
            _ = std.process.Child.run(.{
                .allocator = std.heap.page_allocator,
                .argv = &.{ "tmux", "set", "-p", "allow-passthrough", "off" },
            }) catch {};

            // Verify restoration
            const restore_result = std.process.Child.run(.{
                .allocator = std.heap.page_allocator,
                .argv = &.{ "tmux", "show", "-p", "allow-passthrough" },
            }) catch {
                print("(could not verify restoration)\n", .{});
                return;
            };
            defer std.heap.page_allocator.free(restore_result.stdout);
            defer std.heap.page_allocator.free(restore_result.stderr);

            const restored_off = std.mem.indexOf(u8, restore_result.stdout, "off") != null;
            print("Verified: passthrough is now {s}\n", .{if (restored_off) "off" else "STILL ON (unexpected)"});
        }
    }

    print("\n==========================================\n\n", .{});
}

/// Query XTVERSION through tmux passthrough - modern terminals respond, legacy don't
fn queryXtversionViaTmux(fd: posix.fd_t, timeout_ms: i32, debug: bool) ?[]const u8 {
    const original = posix.tcgetattr(fd) catch return null;

    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    posix.tcsetattr(fd, .FLUSH, raw) catch return null;

    defer posix.tcsetattr(fd, .FLUSH, original) catch {};

    // XTVERSION query: \x1b[>0q
    // Doubled for passthrough: \x1b\x1b[>0q
    // Full: \x1bPtmux;\x1b\x1b[>0q\x1b\\
    const query = "\x1bPtmux;\x1b\x1b[>0q\x1b\\";

    if (debug) {
        print("  XTVERSION query bytes: ", .{});
        for (query) |c| {
            print("{x:0>2} ", .{c});
        }
        print("\n", .{});
    }

    _ = posix.write(fd, query) catch return null;

    var fds = [_]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const Static = struct {
        var buf: [256]u8 = undefined;
    };

    const poll_result = posix.poll(&fds, timeout_ms) catch return null;
    if (poll_result == 0) {
        if (debug) print("  (XTVERSION poll timeout)\n", .{});
        return null;
    }

    const n = posix.read(fd, &Static.buf) catch return null;
    if (n == 0) return null;

    if (debug) {
        print("  XTVERSION raw response ({} bytes): ", .{n});
        for (Static.buf[0..n]) |c| {
            print("{x:0>2} ", .{c});
        }
        print("\n", .{});
    }

    return Static.buf[0..n];
}

/// Query DA1 through tmux passthrough to test if passthrough works
fn queryDA1ViaTmux(fd: posix.fd_t, timeout_ms: i32, debug: bool) ?[]const u8 {
    const original = posix.tcgetattr(fd) catch return null;

    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    posix.tcsetattr(fd, .FLUSH, raw) catch return null;

    defer posix.tcsetattr(fd, .FLUSH, original) catch {};

    // DA1 query: \x1b[c
    // Doubled for passthrough: \x1b\x1b[c
    // Full: \x1bPtmux;\x1b\x1b[c\x1b\\
    const query = "\x1bPtmux;\x1b\x1b[c\x1b\\";

    if (debug) {
        print("  DA1 query bytes: ", .{});
        for (query) |c| {
            print("{x:0>2} ", .{c});
        }
        print("\n", .{});
    }

    _ = posix.write(fd, query) catch return null;

    var fds = [_]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const Static = struct {
        var buf: [256]u8 = undefined;
    };

    const poll_result = posix.poll(&fds, timeout_ms) catch return null;
    if (poll_result == 0) {
        if (debug) print("  (DA1 poll timeout)\n", .{});
        return null;
    }

    const n = posix.read(fd, &Static.buf) catch return null;
    if (n == 0) return null;

    if (debug) {
        print("  DA1 raw response ({} bytes): ", .{n});
        for (Static.buf[0..n]) |c| {
            print("{x:0>2} ", .{c});
        }
        print("\n", .{});
    }

    return Static.buf[0..n];
}

/// Query the OUTER terminal through tmux passthrough
fn queryOuterTerminalViaTmux(fd: posix.fd_t, timeout_ms: i32, debug: bool) ColorQueryResult {
    var result = ColorQueryResult{};

    const original = posix.tcgetattr(fd) catch return result;

    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    posix.tcsetattr(fd, .FLUSH, raw) catch return result;

    defer posix.tcsetattr(fd, .FLUSH, original) catch {};

    // Tmux passthrough format: DCS tmux ; <escaped content> ST
    // DCS = \x1bP, ST = \x1b\\
    // In <escaped content>, all ESC (\x1b) must be doubled
    //
    // Use BEL terminator for OSC 11 (Apple Terminal style): \x1b]11;?\x07
    // Doubled: \x1b\x1b]11;?\x07 (BEL doesn't need doubling)
    // Full: \x1bPtmux;\x1b\x1b]11;?\x07\x1b\\
    const query = "\x1bPtmux;\x1b\x1b]11;?\x07\x1b\\";

    if (debug) {
        print("  Query bytes: ", .{});
        for (query) |c| {
            print("{x:0>2} ", .{c});
        }
        print("\n", .{});
    }

    _ = posix.write(fd, query) catch return result;

    var fds = [_]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    var total_read: usize = 0;
    var attempts: u32 = 0;

    while (attempts < 5) : (attempts += 1) {
        const poll_result = posix.poll(&fds, timeout_ms) catch break;
        if (poll_result == 0) {
            if (debug and attempts == 0) {
                print("  (poll timeout on attempt {})\n", .{attempts});
            }
            break;
        }

        const n = posix.read(fd, ColorQueryResult.Static.response_buf[total_read..]) catch break;
        if (n == 0) break;
        total_read += n;

        // Check for complete OSC response
        const data = ColorQueryResult.Static.response_buf[0..total_read];
        if (std.mem.indexOf(u8, data, "rgb:") != null) {
            if (std.mem.indexOfScalar(u8, data, 0x07) != null or
                std.mem.indexOf(u8, data, "\x1b\\") != null)
            {
                break; // Got complete response
            }
        }
    }

    if (debug and total_read > 0) {
        print("  Raw response ({} bytes): ", .{total_read});
        for (ColorQueryResult.Static.response_buf[0..total_read]) |c| {
            print("{x:0>2} ", .{c});
        }
        print("\n", .{});
    }

    if (total_read == 0) return result;

    const data = ColorQueryResult.Static.response_buf[0..total_read];

    // Parse OSC 11 response (might be wrapped in DCS passthrough response)
    // The response might come back as: DCS tmux ; <response> ST
    if (std.mem.indexOf(u8, data, "\x1b]11;")) |osc_start| {
        var osc_end: usize = data.len;

        if (std.mem.indexOfScalarPos(u8, data, osc_start, 0x07)) |bel_pos| {
            osc_end = bel_pos + 1;
            result.uses_bel_terminator = true;
        } else if (std.mem.indexOfPos(u8, data, osc_start, "\x1b\\")) |st_pos| {
            osc_end = st_pos + 2;
            result.uses_bel_terminator = false;
        }

        result.osc11_response = data[osc_start..osc_end];
    }

    return result;
}
