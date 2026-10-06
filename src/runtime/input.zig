const std = @import("std");
const thermite = @import("thermite");

pub const Key = thermite.terminal.Key;
pub const PollResult = thermite.terminal.PollResult;

/// Input source abstraction - real terminal or test mock
pub const InputSource = union(enum) {
    /// Real terminal input
    terminal: TerminalInput,
    /// Test input - messages pushed programmatically
    test_input: void,

    pub fn poll(self: *InputSource, timeout_ms: i32) !PollResult {
        return switch (self.*) {
            .terminal => |*t| t.poll(timeout_ms),
            .test_input => .timeout, // Test input doesn't block
        };
    }

    pub fn readKey(self: *InputSource) ?Key {
        return switch (self.*) {
            .terminal => |*t| t.readKey(),
            .test_input => null, // Test input uses queue directly
        };
    }

    pub fn deinit(self: *InputSource) void {
        switch (self.*) {
            .terminal => |*t| t.deinit(),
            .test_input => {},
        }
    }
};

/// Real terminal input source
pub const TerminalInput = struct {
    io: std.Io,
    fd: i32,
    original_termios: ?std.posix.termios = null,

    pub fn init(io: std.Io) !TerminalInput {
        const fd = try thermite.terminal.openTty(io);
        errdefer thermite.terminal.closeTty(io, fd);

        // Enter raw mode
        const original = try std.posix.tcgetattr(fd);
        var raw = original;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(fd, .FLUSH, raw);

        // Install signal handlers
        thermite.terminal.installSignalHandlers(fd);

        return .{
            .io = io,
            .fd = fd,
            .original_termios = original,
        };
    }

    pub fn deinit(self: *TerminalInput) void {
        if (self.original_termios) |orig| {
            std.posix.tcsetattr(self.fd, .FLUSH, orig) catch {};
        }
        thermite.terminal.closeTty(self.io, self.fd);
    }

    pub fn poll(self: *TerminalInput, timeout_ms: i32) !PollResult {
        return thermite.terminal.pollInput(self.fd, timeout_ms);
    }

    pub fn readKey(self: *TerminalInput) ?Key {
        return thermite.terminal.readKeyEvent(self.io, self.fd);
    }

    pub fn getFd(self: *const TerminalInput) i32 {
        return self.fd;
    }
};

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

test "InputSource: test mode doesn't block" {
    var input = InputSource{ .test_input = {} };
    defer input.deinit();

    // Should return timeout immediately (non-blocking)
    const result = try input.poll(1000);
    try std.testing.expectEqual(PollResult.timeout, result);

    // Should return null (no real input)
    try std.testing.expectEqual(@as(?Key, null), input.readKey());
}
