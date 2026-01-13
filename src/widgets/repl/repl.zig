const std = @import("std");
const Allocator = std.mem.Allocator;
const LineBuffer = @import("line_buffer.zig").LineBuffer;

/// REPL widget - readline-style input with modern features
pub const Repl = struct {
    allocator: Allocator,

    // Core state
    buffer: LineBuffer,
    history: History,

    // Configuration
    config: Config,

    // Callbacks
    on_submit: ?*const fn (text: []const u8, ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,

    pub const Config = struct {
        prompt: []const u8 = "> ",
        history_limit: usize = 1000,
    };

    pub fn init(allocator: Allocator, config: Config) !Repl {
        return .{
            .allocator = allocator,
            .buffer = try LineBuffer.init(allocator),
            .history = History.init(allocator, config.history_limit),
            .config = config,
        };
    }

    pub fn deinit(self: *Repl) void {
        self.buffer.deinit();
        self.history.deinit();
    }

    /// Handle a key event, returns action to take
    pub fn handleKey(self: *Repl, key: Key) !Action {
        switch (key) {
            .char => |c| {
                try self.buffer.insertCodepoint(c);
                return .redraw;
            },
            .enter => {
                return .submit;
            },
            .backspace => {
                self.buffer.deleteCharBackward();
                return .redraw;
            },
            .delete => {
                self.buffer.deleteCharForward();
                return .redraw;
            },
            .left => {
                self.buffer.moveCursorLeftChar();
                return .redraw;
            },
            .right => {
                self.buffer.moveCursorRightChar();
                return .redraw;
            },
            .home => {
                self.buffer.moveCursorToStart();
                return .redraw;
            },
            .end => {
                self.buffer.moveCursorToEnd();
                return .redraw;
            },
            .up => {
                if (self.history.previous()) |text| {
                    try self.buffer.setText(text);
                }
                return .redraw;
            },
            .down => {
                if (self.history.next()) |text| {
                    try self.buffer.setText(text);
                } else {
                    self.buffer.clear();
                }
                return .redraw;
            },
            .ctrl_a => {
                self.buffer.moveCursorToStart();
                return .redraw;
            },
            .ctrl_e => {
                self.buffer.moveCursorToEnd();
                return .redraw;
            },
            .ctrl_u => {
                self.buffer.deleteToStart();
                return .redraw;
            },
            .ctrl_k => {
                self.buffer.deleteToEnd();
                return .redraw;
            },
            .ctrl_w => {
                self.buffer.deleteWordBackward();
                return .redraw;
            },
            .ctrl_c => {
                return .cancel;
            },
            .ctrl_d => {
                if (self.buffer.len() == 0) {
                    return .eof;
                }
                self.buffer.deleteCharForward();
                return .redraw;
            },
            .ctrl_l => {
                return .clear_screen;
            },
            .ctrl_left => {
                self.buffer.moveCursorWordLeft();
                return .redraw;
            },
            .ctrl_right => {
                self.buffer.moveCursorWordRight();
                return .redraw;
            },
            .ctrl_o, .shift_enter, .alt_enter => {
                // Insert newline for multiline editing
                try self.buffer.insertChar('\n');
                return .redraw;
            },
            .tab => {
                // TODO: completion
                return .none;
            },
            .escape => {
                return .none;
            },
            .unknown => {
                return .none;
            },
        }
    }

    /// Submit current input, add to history, clear buffer
    pub fn submit(self: *Repl) !?[]const u8 {
        const text = try self.buffer.getText(self.allocator);

        // Add to history if non-empty
        if (text.len > 0) {
            try self.history.add(text);
        }

        // Clear buffer for next input
        self.buffer.clear();
        self.history.resetNavigation();

        return text;
    }

    /// Get current input text (caller must free)
    pub fn getText(self: *Repl) ![]const u8 {
        return self.buffer.getText(self.allocator);
    }

    /// Get cursor position
    pub fn getCursor(self: *const Repl) usize {
        return self.buffer.cursor();
    }

    /// Get prompt
    pub fn getPrompt(self: *const Repl) []const u8 {
        return self.config.prompt;
    }

    /// Cancel current input
    pub fn cancel(self: *Repl) void {
        self.buffer.clear();
        self.history.resetNavigation();
    }

    pub const Action = enum {
        none,
        redraw,
        submit,
        cancel,
        eof,
        clear_screen,
    };

    pub const Key = union(enum) {
        char: u21,
        enter,
        backspace,
        delete,
        tab,
        escape,
        up,
        down,
        left,
        right,
        home,
        end,
        ctrl_a,
        ctrl_c,
        ctrl_d,
        ctrl_e,
        ctrl_k,
        ctrl_l,
        ctrl_u,
        ctrl_w,
        ctrl_left,
        ctrl_right,
        ctrl_o, // Insert newline (open line)
        shift_enter, // Shift+Enter (kitty protocol)
        alt_enter, // Alt+Enter
        unknown,

    };
};

/// Simple history with navigation
pub const History = struct {
    allocator: Allocator,
    entries: std.ArrayListUnmanaged([]const u8),
    limit: usize,
    nav_index: ?usize = null, // null = not navigating
    temp_buffer: ?[]const u8 = null, // store current input when navigating

    pub fn init(allocator: Allocator, limit: usize) History {
        return .{
            .allocator = allocator,
            .entries = .{},
            .limit = limit,
        };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry);
        }
        self.entries.deinit(self.allocator);
        if (self.temp_buffer) |buf| {
            self.allocator.free(buf);
        }
    }

    pub fn add(self: *History, text: []const u8) !void {
        // Don't add duplicates of last entry
        if (self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            if (std.mem.eql(u8, last, text)) {
                return;
            }
        }

        // Remove oldest if at limit
        if (self.entries.items.len >= self.limit) {
            const removed = self.entries.orderedRemove(0);
            self.allocator.free(removed);
        }

        // Add copy
        const copy = try self.allocator.dupe(u8, text);
        try self.entries.append(self.allocator, copy);
    }

    /// Navigate to previous (older) history entry
    pub fn previous(self: *History) ?[]const u8 {
        if (self.entries.items.len == 0) return null;

        if (self.nav_index) |idx| {
            if (idx > 0) {
                self.nav_index = idx - 1;
                return self.entries.items[idx - 1];
            }
            return null;
        } else {
            // Start navigation from end
            self.nav_index = self.entries.items.len - 1;
            return self.entries.items[self.entries.items.len - 1];
        }
    }

    /// Navigate to next (newer) history entry
    pub fn next(self: *History) ?[]const u8 {
        if (self.nav_index) |idx| {
            if (idx + 1 < self.entries.items.len) {
                self.nav_index = idx + 1;
                return self.entries.items[idx + 1];
            }
            // At end of history
            self.nav_index = null;
            return null;
        }
        return null;
    }

    /// Reset navigation state
    pub fn resetNavigation(self: *History) void {
        self.nav_index = null;
        if (self.temp_buffer) |buf| {
            self.allocator.free(buf);
            self.temp_buffer = null;
        }
    }

    /// Number of history entries
    pub fn count(self: *const History) usize {
        return self.entries.items.len;
    }
};

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

test "basic input" {
    var repl = try Repl.init(std.testing.allocator, .{});
    defer repl.deinit();

    _ = try repl.handleKey(.{ .char = 'h' });
    _ = try repl.handleKey(.{ .char = 'i' });

    const text = try repl.getText();
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("hi", text);
}

test "backspace" {
    var repl = try Repl.init(std.testing.allocator, .{});
    defer repl.deinit();

    _ = try repl.handleKey(.{ .char = 'h' });
    _ = try repl.handleKey(.{ .char = 'i' });
    _ = try repl.handleKey(.backspace);

    const text = try repl.getText();
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("h", text);
}

test "history navigation" {
    var repl = try Repl.init(std.testing.allocator, .{});
    defer repl.deinit();

    // Type and submit "first"
    _ = try repl.handleKey(.{ .char = 'f' });
    _ = try repl.handleKey(.{ .char = 'i' });
    _ = try repl.handleKey(.{ .char = 'r' });
    _ = try repl.handleKey(.{ .char = 's' });
    _ = try repl.handleKey(.{ .char = 't' });
    const first = try repl.submit();
    defer std.testing.allocator.free(first.?);

    // Type and submit "second"
    _ = try repl.handleKey(.{ .char = 's' });
    _ = try repl.handleKey(.{ .char = 'e' });
    _ = try repl.handleKey(.{ .char = 'c' });
    _ = try repl.handleKey(.{ .char = 'o' });
    _ = try repl.handleKey(.{ .char = 'n' });
    _ = try repl.handleKey(.{ .char = 'd' });
    const second = try repl.submit();
    defer std.testing.allocator.free(second.?);

    // Navigate up should show "second"
    _ = try repl.handleKey(.up);
    const text1 = try repl.getText();
    defer std.testing.allocator.free(text1);
    try std.testing.expectEqualStrings("second", text1);

    // Navigate up again should show "first"
    _ = try repl.handleKey(.up);
    const text2 = try repl.getText();
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings("first", text2);
}

test "full session simulation without TTY" {
    // This test demonstrates how to fully test the REPL without any TTY
    // by programmatically injecting key events
    var repl = try Repl.init(std.testing.allocator, .{ .prompt = "test> " });
    defer repl.deinit();

    // Helper to type a string
    const typeString = struct {
        fn f(r: *Repl, s: []const u8) !void {
            for (s) |c| {
                _ = try r.handleKey(.{ .char = c });
            }
        }
    }.f;

    // 1. Type "hello world" and submit
    try typeString(&repl, "hello world");
    var text = try repl.getText();
    try std.testing.expectEqualStrings("hello world", text);
    std.testing.allocator.free(text);

    const action1 = try repl.handleKey(.enter);
    try std.testing.expectEqual(Repl.Action.submit, action1);

    const submitted = try repl.submit();
    defer std.testing.allocator.free(submitted.?);
    try std.testing.expectEqualStrings("hello world", submitted.?);

    // 2. Type something, use Ctrl+A to go to start, Ctrl+K to kill line
    try typeString(&repl, "delete me");
    _ = try repl.handleKey(.ctrl_a); // Go to start
    try std.testing.expectEqual(@as(usize, 0), repl.getCursor());

    _ = try repl.handleKey(.ctrl_k); // Kill to end
    text = try repl.getText();
    try std.testing.expectEqualStrings("", text);
    std.testing.allocator.free(text);

    // 3. Type new text, use Ctrl+W to delete word
    try typeString(&repl, "one two three");
    _ = try repl.handleKey(.ctrl_w); // Delete "three"
    text = try repl.getText();
    try std.testing.expectEqualStrings("one two ", text);
    std.testing.allocator.free(text);

    // 4. Clear and test cursor navigation
    _ = try repl.handleKey(.ctrl_u); // Clear line
    try typeString(&repl, "abcdef");
    _ = try repl.handleKey(.home); // Go to start
    try std.testing.expectEqual(@as(usize, 0), repl.getCursor());
    _ = try repl.handleKey(.end); // Go to end
    try std.testing.expectEqual(@as(usize, 6), repl.getCursor());

    // 5. Use arrow keys
    _ = try repl.handleKey(.left);
    _ = try repl.handleKey(.left);
    try std.testing.expectEqual(@as(usize, 4), repl.getCursor());

    // Insert in middle
    _ = try repl.handleKey(.{ .char = 'X' });
    text = try repl.getText();
    try std.testing.expectEqualStrings("abcdXef", text);
    std.testing.allocator.free(text);

    // 6. Test Ctrl+C cancel
    const action2 = try repl.handleKey(.ctrl_c);
    try std.testing.expectEqual(Repl.Action.cancel, action2);

    // 7. Test Ctrl+D EOF on empty line
    repl.cancel();
    const action3 = try repl.handleKey(.ctrl_d);
    try std.testing.expectEqual(Repl.Action.eof, action3);

    // 8. Verify history was saved
    try std.testing.expectEqual(@as(usize, 1), repl.history.count());
}
