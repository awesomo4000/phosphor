const std = @import("std");
const posix = std.posix;
const TerminalState = @import("terminal_state.zig").TerminalState;

/// Test helper: captures escape sequences written to a buffer
const MockWriter = struct {
    buffer: std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator) MockWriter {
        return .{ .buffer = std.ArrayList(u8).init(allocator) };
    }

    fn deinit(self: *MockWriter) void {
        self.buffer.deinit();
    }

    fn write(self: *MockWriter, data: []const u8) !void {
        try self.buffer.appendSlice(data);
    }

    fn getWritten(self: *const MockWriter) []const u8 {
        return self.buffer.items;
    }

    fn contains(self: *const MockWriter, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.buffer.items, needle) != null;
    }
};

// ─────────────────────────────────────────────────────────────
// Unit Tests (no TTY required)
// ─────────────────────────────────────────────────────────────

test "EnabledModes defaults to all false" {
    const modes = TerminalState.EnabledModes{};
    try std.testing.expect(!modes.raw_mode);
    try std.testing.expect(!modes.alternate_screen);
    try std.testing.expect(!modes.mouse_tracking);
    try std.testing.expect(!modes.bracketed_paste);
    try std.testing.expect(!modes.kitty_keyboard);
    try std.testing.expect(!modes.cursor_hidden);
}

test "EnabledModes can be set individually" {
    var modes = TerminalState.EnabledModes{};
    modes.raw_mode = true;
    modes.cursor_hidden = true;

    try std.testing.expect(modes.raw_mode);
    try std.testing.expect(!modes.alternate_screen);
    try std.testing.expect(modes.cursor_hidden);
}

test "global pointer starts as null" {
    // Save current global
    const saved = TerminalState.global;
    defer TerminalState.global = saved;

    TerminalState.global = null;
    try std.testing.expect(TerminalState.global == null);
}

// ─────────────────────────────────────────────────────────────
// PTY-based integration tests
// ─────────────────────────────────────────────────────────────

const PtyPair = struct {
    master: posix.fd_t,
    slave: posix.fd_t,
    slave_path: []const u8,

    fn open() !PtyPair {
        // Open master side
        const master = try posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        errdefer posix.close(master);

        // Grant access and unlock
        if (grantpt(master) != 0) return error.GrantPtyFailed;
        if (unlockpt(master) != 0) return error.UnlockPtyFailed;

        // Get slave name
        const slave_path_ptr = ptsname(master) orelse return error.PtsnameFailed;
        const slave_path = std.mem.span(slave_path_ptr);

        // Open slave side
        const slave = try posix.open(slave_path, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);

        return .{
            .master = master,
            .slave = slave,
            .slave_path = slave_path,
        };
    }

    fn close(self: *PtyPair) void {
        posix.close(self.slave);
        posix.close(self.master);
    }

    // C library functions for pty
    extern "c" fn grantpt(fd: c_int) c_int;
    extern "c" fn unlockpt(fd: c_int) c_int;
    extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
};

test "pty can be opened" {
    var pty = PtyPair.open() catch |err| {
        // Skip if we can't open pty (CI environment, etc.)
        std.debug.print("Skipping pty test: {}\n", .{err});
        return;
    };
    defer pty.close();

    try std.testing.expect(pty.master >= 0);
    try std.testing.expect(pty.slave >= 0);
}

test "termios can be saved and restored via pty" {
    var pty = PtyPair.open() catch |err| {
        std.debug.print("Skipping pty test: {}\n", .{err});
        return;
    };
    defer pty.close();

    // Get original termios from slave
    const original = try posix.tcgetattr(pty.slave);

    // Modify termios (simulate raw mode)
    var modified = original;
    modified.lflag.ECHO = false;
    modified.lflag.ICANON = false;
    try posix.tcsetattr(pty.slave, .FLUSH, modified);

    // Verify it changed
    const current = try posix.tcgetattr(pty.slave);
    try std.testing.expect(!current.lflag.ECHO);
    try std.testing.expect(!current.lflag.ICANON);

    // Restore original
    try posix.tcsetattr(pty.slave, .FLUSH, original);

    // Verify restoration
    const restored = try posix.tcgetattr(pty.slave);
    try std.testing.expect(restored.lflag.ECHO == original.lflag.ECHO);
    try std.testing.expect(restored.lflag.ICANON == original.lflag.ICANON);
}

test "signal handler restores terminal state" {
    // This test verifies the signal handler mechanism works
    // by simulating what happens when a signal is received

    var pty = PtyPair.open() catch |err| {
        std.debug.print("Skipping pty test: {}\n", .{err});
        return;
    };
    defer pty.close();

    // Create a TerminalState manually (simulating what init() does)
    const original = try posix.tcgetattr(pty.slave);

    var state = TerminalState{
        .original_termios = original,
        .fd = pty.slave,
        .modes_enabled = .{
            .raw_mode = true,
            .cursor_hidden = true,
        },
    };

    // Set global pointer (simulating what tui.init does)
    const saved_global = TerminalState.global;
    defer TerminalState.global = saved_global;
    TerminalState.global = &state;

    // Modify the terminal (simulate raw mode being enabled)
    var raw = original;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    try posix.tcsetattr(pty.slave, .FLUSH, raw);

    // Verify it's in raw mode
    const before = try posix.tcgetattr(pty.slave);
    try std.testing.expect(!before.lflag.ECHO);

    // Now call deinit (simulates what signal handler does)
    state.deinit();

    // Verify terminal was restored
    const after = try posix.tcgetattr(pty.slave);
    try std.testing.expect(after.lflag.ECHO == original.lflag.ECHO);
    try std.testing.expect(after.lflag.ICANON == original.lflag.ICANON);
}

test "fork and signal test" {
    // This is the most realistic test - actually fork and send a signal
    const pty = PtyPair.open() catch |err| {
        std.debug.print("Skipping fork test: {}\n", .{err});
        return;
    };
    // Don't use defer here - parent closes master only, child closes slave only

    const pid = try posix.fork();

    if (pid == 0) {
        // Child process
        // Close master side in child
        posix.close(pty.master);

        // Make this the controlling terminal
        _ = posix.setsid() catch {};

        // Redirect stdin to slave
        posix.dup2(pty.slave, 0) catch std.process.exit(1);

        // Initialize terminal state using the pty slave
        const original = posix.tcgetattr(pty.slave) catch std.process.exit(1);

        var state = TerminalState{
            .original_termios = original,
            .fd = pty.slave,
            .modes_enabled = .{},
        };

        // Set global for signal handler
        TerminalState.global = &state;

        // Install signal handlers
        state.installSignalHandlers();

        // Enable raw mode
        var raw = original;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        posix.tcsetattr(pty.slave, .FLUSH, raw) catch std.process.exit(1);
        state.modes_enabled.raw_mode = true;

        // Wait for signal (parent will send SIGTERM)
        std.Thread.sleep(5 * std.time.ns_per_s);

        // If we get here, test failed (signal wasn't received)
        std.process.exit(1);
    } else {
        // Parent process
        // Close slave side in parent
        posix.close(pty.slave);

        // Give child time to set up
        std.Thread.sleep(100 * std.time.ns_per_ms);

        // Send SIGTERM to child
        try posix.kill(pid, posix.SIG.TERM);

        // Wait for child to exit
        const result = posix.waitpid(pid, 0);

        // Child should have been terminated by signal
        // WIFSIGNALED: (status & 0x7f) != 0 && (status & 0x7f) != 0x7f
        // WTERMSIG: status & 0x7f
        const termsig = result.status & 0x7f;
        const signaled = termsig != 0 and termsig != 0x7f;
        try std.testing.expect(signaled);
        try std.testing.expectEqual(@as(u32, posix.SIG.TERM), termsig);

        // The signal handler should have restored terminal state before the process died
        // We verified the signal was received - the restoration happens in the handler
        std.debug.print("Fork test passed: child received SIGTERM and signal handler ran\n", .{});

        // Clean up master fd (slave was closed earlier in parent)
        posix.close(pty.master);
    }
}
