const std = @import("std");
const Allocator = std.mem.Allocator;
const LineBuffer = @import("line_buffer.zig").LineBuffer;
const phosphor = @import("phosphor");
const DrawCommand = phosphor.DrawCommand;
const Key = phosphor.Key;
const LayoutNode = phosphor.LayoutNode;

/// Segment kind - distinguishes typed input from pasted content
pub const SegmentKind = enum {
    typed,
    pasted,
};

/// A segment of input text with its kind
pub const Segment = struct {
    kind: SegmentKind,
    start: usize,
    end: usize,

    pub fn len(self: Segment) usize {
        return self.end - self.start;
    }
};

/// REPL widget - readline-style input with modern features
pub const Repl = struct {
    allocator: Allocator,

    // Core state
    buffer: LineBuffer,
    history: History,
    segments: std.ArrayListUnmanaged(Segment),
    in_paste: bool,

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
            .segments = .{},
            .in_paste = false,
            .config = config,
        };
    }

    pub fn deinit(self: *Repl) void {
        self.buffer.deinit();
        self.history.deinit();
        self.segments.deinit(self.allocator);
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
        self.segments.clearRetainingCapacity();
        self.in_paste = false;

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
        self.segments.clearRetainingCapacity();
        self.in_paste = false;
    }

    /// Called when paste starts (ESC[200~)
    pub fn pasteStart(self: *Repl) void {
        self.in_paste = true;
        // Start a new pasted segment at current position
        const pos = self.buffer.len();
        self.segments.append(self.allocator, .{
            .kind = .pasted,
            .start = pos,
            .end = pos,
        }) catch {};
    }

    /// Called when paste ends (ESC[201~)
    pub fn pasteEnd(self: *Repl) void {
        self.in_paste = false;
        // Finalize the pasted segment
        if (self.segments.items.len > 0) {
            const last = &self.segments.items[self.segments.items.len - 1];
            if (last.kind == .pasted) {
                last.end = self.buffer.len();
            }
        }
    }

    /// Check if a position is within a pasted segment
    pub fn isPasted(self: *const Repl, pos: usize) bool {
        for (self.segments.items) |seg| {
            if (seg.kind == .pasted and pos >= seg.start and pos < seg.end) {
                return true;
            }
        }
        return false;
    }

    /// Count newlines in pasted segments (for "[N lines]" display)
    pub fn countPastedNewlines(self: *const Repl, text: []const u8) usize {
        var count: usize = 0;
        for (self.segments.items) |seg| {
            if (seg.kind == .pasted) {
                const start = @min(seg.start, text.len);
                const end = @min(seg.end, text.len);
                for (text[start..end]) |c| {
                    if (c == '\n') count += 1;
                }
            }
        }
        return count;
    }

    /// Generate draw commands to render the input line
    /// The view renders at the specified row, returns commands and actual rows used
    pub fn view(
        self: *const Repl,
        row: u16,
        width: u16,
        allocator: Allocator,
    ) !ViewResult {
        var commands: std.ArrayListUnmanaged(DrawCommand) = .{};
        errdefer commands.deinit(allocator);

        var text_allocs: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (text_allocs.items) |t| allocator.free(t);
            text_allocs.deinit(allocator);
        }

        const text = try self.buffer.getText(allocator);
        defer allocator.free(text);

        const prompt = self.config.prompt;
        const prompt_len: u16 = @intCast(@min(prompt.len, width));

        // Move to row and clear line
        try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = row } });
        try commands.append(allocator, .clear_line);

        // Draw prompt
        try commands.append(allocator, .{ .draw_text = .{ .text = prompt } });

        // Draw text (simple single-line version)
        const available_width = width -| prompt_len;
        const cursor = self.buffer.cursor();

        // For now, simple rendering: show text from start
        const display_len = @min(text.len, available_width);
        if (display_len > 0) {
            // We need to allocate the text slice to survive the commands array
            const text_copy = try allocator.dupe(u8, text[0..display_len]);
            try text_allocs.append(allocator, text_copy);
            try commands.append(allocator, .{ .draw_text = .{ .text = text_copy } });
        }

        // Position cursor
        const cursor_x = prompt_len + @as(u16, @intCast(@min(cursor, available_width)));
        try commands.append(allocator, .{ .move_cursor = .{ .x = cursor_x, .y = row } });

        return .{
            .commands = try commands.toOwnedSlice(allocator),
            .rows_used = 1,
            .text_allocs = try text_allocs.toOwnedSlice(allocator),
        };
    }

    pub const ViewResult = struct {
        commands: []DrawCommand,
        rows_used: u16,
        text_allocs: [][]const u8, // Text allocations to free

        pub fn deinit(self: *ViewResult, allocator: Allocator) void {
            for (self.text_allocs) |t| {
                allocator.free(t);
            }
            allocator.free(self.text_allocs);
            allocator.free(self.commands);
        }
    };

    pub const Action = enum {
        none,
        redraw,
        submit,
        cancel,
        eof,
        clear_screen,
    };

    // ─────────────────────────────────────────────────────────────
    // New declarative view (returns LayoutNode tree)
    // ─────────────────────────────────────────────────────────────

    /// Returns a declarative layout tree describing the REPL
    /// Allocator is used for text that needs to be copied (frame lifetime)
    pub fn viewTree(self: *const Repl, frame_alloc: Allocator) !ViewTree {
        // Get text - this allocation lives for the frame
        const text = try self.buffer.getText(frame_alloc);
        const cursor_pos = self.buffer.cursor();
        const prompt = self.config.prompt;

        // Allocate children array on frame allocator (survives function return)
        const children = try frame_alloc.alloc(LayoutNode, 3);
        children[0] = LayoutNode.text(prompt);
        children[1] = LayoutNode.text(text);
        children[2] = LayoutNode.cursorNode();

        return ViewTree{
            .frame_alloc = frame_alloc,
            .text = text,
            .prompt = prompt,
            .cursor_pos = cursor_pos,
            .children = children,
        };
    }

    pub const ViewTree = struct {
        frame_alloc: Allocator,
        text: []const u8,
        prompt: []const u8,
        cursor_pos: usize,
        children: []LayoutNode, // Allocated on frame_alloc

        /// Build the actual LayoutNode tree
        /// Returns an hbox with [prompt][text][cursor]
        pub fn build(self: *const ViewTree) LayoutNode {
            return LayoutNode.hbox(self.children);
        }

        /// Get cursor X position (prompt_len + cursor_pos)
        pub fn getCursorX(self: *const ViewTree) u16 {
            return @intCast(self.prompt.len + @min(self.cursor_pos, self.text.len));
        }

        pub fn deinit(self: *ViewTree) void {
            self.frame_alloc.free(self.text);
            self.frame_alloc.free(self.children);
        }
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

test "view generates draw commands" {
    var repl = try Repl.init(std.testing.allocator, .{ .prompt = "> " });
    defer repl.deinit();

    // Type some text
    _ = try repl.handleKey(.{ .char = 'h' });
    _ = try repl.handleKey(.{ .char = 'i' });

    // Get view commands
    var result = try repl.view(10, 80, std.testing.allocator);
    defer result.deinit(std.testing.allocator);

    // Should have commands: move_cursor, clear_line, draw_text (prompt), draw_text (input), move_cursor
    try std.testing.expect(result.commands.len >= 4);
    try std.testing.expectEqual(@as(u16, 1), result.rows_used);

    // First command should be move_cursor to row 10
    try std.testing.expectEqual(DrawCommand{ .move_cursor = .{ .x = 0, .y = 10 } }, result.commands[0]);

    // Second should be clear_line
    try std.testing.expectEqual(DrawCommand.clear_line, result.commands[1]);
}

test "view renders to MemoryBackend" {
    const MemoryBackend = phosphor.MemoryBackend;

    // Create REPL
    var repl = try Repl.init(std.testing.allocator, .{ .prompt = "> " });
    defer repl.deinit();

    // Type "hello"
    _ = try repl.handleKey(.{ .char = 'h' });
    _ = try repl.handleKey(.{ .char = 'e' });
    _ = try repl.handleKey(.{ .char = 'l' });
    _ = try repl.handleKey(.{ .char = 'l' });
    _ = try repl.handleKey(.{ .char = 'o' });

    // Create memory backend
    var mem = try MemoryBackend.init(std.testing.allocator, 40, 10);
    defer mem.deinit();

    // Get view commands and execute on memory backend
    var result = try repl.view(0, 40, std.testing.allocator);
    defer result.deinit(std.testing.allocator);

    const backend = mem.backend();
    backend.execute(result.commands);

    // Verify the rendered output
    const line = try mem.getLine(0, std.testing.allocator);
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("> hello", line);
}

test "paste segments tracking" {
    var repl = try Repl.init(std.testing.allocator, .{ .prompt = "> " });
    defer repl.deinit();

    // Type "hello "
    _ = try repl.handleKey(.{ .char = 'h' });
    _ = try repl.handleKey(.{ .char = 'e' });
    _ = try repl.handleKey(.{ .char = 'l' });
    _ = try repl.handleKey(.{ .char = 'l' });
    _ = try repl.handleKey(.{ .char = 'o' });
    _ = try repl.handleKey(.{ .char = ' ' });

    // Simulate paste of "world\nfoo"
    repl.pasteStart();
    _ = try repl.handleKey(.{ .char = 'w' });
    _ = try repl.handleKey(.{ .char = 'o' });
    _ = try repl.handleKey(.{ .char = 'r' });
    _ = try repl.handleKey(.{ .char = 'l' });
    _ = try repl.handleKey(.{ .char = 'd' });
    _ = try repl.handleKey(.{ .char = '\n' });
    _ = try repl.handleKey(.{ .char = 'f' });
    _ = try repl.handleKey(.{ .char = 'o' });
    _ = try repl.handleKey(.{ .char = 'o' });
    repl.pasteEnd();

    // Should have one pasted segment
    try std.testing.expectEqual(@as(usize, 1), repl.segments.items.len);
    try std.testing.expectEqual(SegmentKind.pasted, repl.segments.items[0].kind);
    try std.testing.expectEqual(@as(usize, 6), repl.segments.items[0].start); // starts after "hello "
    try std.testing.expectEqual(@as(usize, 15), repl.segments.items[0].end); // "world\nfoo" = 9 chars

    // Check isPasted
    try std.testing.expect(!repl.isPasted(5)); // "hello" not pasted
    try std.testing.expect(repl.isPasted(6)); // start of paste
    try std.testing.expect(repl.isPasted(10)); // middle of paste
    try std.testing.expect(!repl.isPasted(15)); // end is exclusive

    // Count newlines in pasted content
    const text = try repl.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 1), repl.countPastedNewlines(text));
}
