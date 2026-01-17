const std = @import("std");
const Allocator = std.mem.Allocator;

/// Gap buffer for efficient text editing at cursor position.
/// Text is stored as: [text_before_cursor][gap][text_after_cursor]
/// Insert/delete at cursor is O(1), moving cursor is O(n) where n = gap size.
pub const LineBuffer = struct {
    allocator: Allocator,

    /// Buffer storing all text
    buffer: []u8,

    /// Start of the gap (also = cursor position in logical text)
    gap_start: usize,

    /// End of the gap (exclusive)
    gap_end: usize,

    const INITIAL_GAP_SIZE = 64;
    const MIN_GAP_SIZE = 16;

    pub fn init(allocator: Allocator) !LineBuffer {
        const buffer = try allocator.alloc(u8, INITIAL_GAP_SIZE);
        return .{
            .allocator = allocator,
            .buffer = buffer,
            .gap_start = 0,
            .gap_end = INITIAL_GAP_SIZE,
        };
    }

    pub fn deinit(self: *LineBuffer) void {
        self.allocator.free(self.buffer);
    }

    /// Length of actual text (excluding gap)
    pub fn len(self: *const LineBuffer) usize {
        return self.buffer.len - self.gapLen();
    }

    /// Current gap size
    fn gapLen(self: *const LineBuffer) usize {
        return self.gap_end - self.gap_start;
    }

    /// Cursor position in logical text
    pub fn cursor(self: *const LineBuffer) usize {
        return self.gap_start;
    }

    /// Insert text at cursor position
    pub fn insert(self: *LineBuffer, text: []const u8) !void {
        // Ensure we have enough gap space
        if (text.len > self.gapLen()) {
            try self.expandGap(text.len);
        }

        // Copy text into gap
        @memcpy(self.buffer[self.gap_start..][0..text.len], text);
        self.gap_start += text.len;
    }

    /// Insert single character at cursor
    pub fn insertChar(self: *LineBuffer, char: u8) !void {
        if (self.gapLen() == 0) {
            try self.expandGap(1);
        }
        self.buffer[self.gap_start] = char;
        self.gap_start += 1;
    }

    /// Insert a unicode codepoint (UTF-8 encoded)
    pub fn insertCodepoint(self: *LineBuffer, codepoint: u21) !void {
        var buf: [4]u8 = undefined;
        const byte_len = std.unicode.utf8Encode(codepoint, &buf) catch return;
        try self.insert(buf[0..byte_len]);
    }

    /// Delete n bytes before cursor (backspace)
    pub fn deleteBackward(self: *LineBuffer, n: usize) void {
        const to_delete = @min(n, self.gap_start);
        self.gap_start -= to_delete;
    }

    /// Delete n bytes after cursor (delete key)
    pub fn deleteForward(self: *LineBuffer, n: usize) void {
        const available = self.buffer.len - self.gap_end;
        const to_delete = @min(n, available);
        self.gap_end += to_delete;
    }

    /// Delete one character (grapheme) backward - UTF-8 aware
    pub fn deleteCharBackward(self: *LineBuffer) void {
        if (self.gap_start == 0) return;

        // Find start of previous UTF-8 character
        var i: usize = 1;
        while (i <= self.gap_start and i <= 4) : (i += 1) {
            const byte = self.buffer[self.gap_start - i];
            // UTF-8 continuation bytes start with 10xxxxxx
            if ((byte & 0xC0) != 0x80) {
                break;
            }
        }
        self.gap_start -= i;
    }

    /// Delete one character (grapheme) forward - UTF-8 aware
    pub fn deleteCharForward(self: *LineBuffer) void {
        if (self.gap_end >= self.buffer.len) return;

        const byte = self.buffer[self.gap_end];
        const char_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        const available = self.buffer.len - self.gap_end;
        self.gap_end += @min(char_len, available);
    }

    /// Move cursor left by n bytes
    pub fn moveCursorLeft(self: *LineBuffer, n: usize) void {
        const to_move = @min(n, self.gap_start);
        if (to_move == 0) return;

        // Move text from before gap to after gap
        const src_start = self.gap_start - to_move;
        const dst_start = self.gap_end - to_move;

        // Copy backwards to handle overlap
        var i: usize = to_move;
        while (i > 0) {
            i -= 1;
            self.buffer[dst_start + i] = self.buffer[src_start + i];
        }

        self.gap_start -= to_move;
        self.gap_end -= to_move;
    }

    /// Move cursor right by n bytes
    pub fn moveCursorRight(self: *LineBuffer, n: usize) void {
        const available = self.buffer.len - self.gap_end;
        const to_move = @min(n, available);
        if (to_move == 0) return;

        // Move text from after gap to before gap
        @memcpy(self.buffer[self.gap_start..][0..to_move], self.buffer[self.gap_end..][0..to_move]);

        self.gap_start += to_move;
        self.gap_end += to_move;
    }

    /// Move cursor left by one UTF-8 character
    pub fn moveCursorLeftChar(self: *LineBuffer) void {
        if (self.gap_start == 0) return;

        // Find start of previous UTF-8 character
        var i: usize = 1;
        while (i < self.gap_start and i <= 4) : (i += 1) {
            const byte = self.buffer[self.gap_start - i];
            if ((byte & 0xC0) != 0x80) {
                break;
            }
        }
        self.moveCursorLeft(i);
    }

    /// Move cursor right by one UTF-8 character
    pub fn moveCursorRightChar(self: *LineBuffer) void {
        if (self.gap_end >= self.buffer.len) return;

        const byte = self.buffer[self.gap_end];
        const char_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        const available = self.buffer.len - self.gap_end;
        self.moveCursorRight(@min(char_len, available));
    }

    /// Move cursor to absolute position
    pub fn moveCursorTo(self: *LineBuffer, pos: usize) void {
        const target = @min(pos, self.len());
        if (target < self.gap_start) {
            self.moveCursorLeft(self.gap_start - target);
        } else if (target > self.gap_start) {
            self.moveCursorRight(target - self.gap_start);
        }
    }

    /// Move cursor to start of buffer
    pub fn moveCursorToStart(self: *LineBuffer) void {
        self.moveCursorTo(0);
    }

    /// Move cursor to end of buffer
    pub fn moveCursorToEnd(self: *LineBuffer) void {
        self.moveCursorTo(self.len());
    }

    /// Get the full text content (allocates)
    pub fn getText(self: *const LineBuffer, allocator: Allocator) ![]u8 {
        const text_len = self.len();
        const result = try allocator.alloc(u8, text_len);

        // Copy text before gap
        @memcpy(result[0..self.gap_start], self.buffer[0..self.gap_start]);

        // Copy text after gap
        const after_gap_len = self.buffer.len - self.gap_end;
        @memcpy(result[self.gap_start..], self.buffer[self.gap_end..]);

        _ = after_gap_len;
        return result;
    }

    /// Get text as slice (only valid if gap is at end)
    /// Returns null if gap is not at end - use getText() instead
    pub fn getTextSlice(self: *const LineBuffer) ?[]const u8 {
        if (self.gap_end == self.buffer.len) {
            return self.buffer[0..self.gap_start];
        }
        return null;
    }

    /// Get text as two slices (before cursor and after cursor)
    /// Always valid, no allocation needed. Iterate both to get full text.
    pub fn getTextParts(self: *const LineBuffer) struct { before: []const u8, after: []const u8 } {
        return .{
            .before = self.buffer[0..self.gap_start],
            .after = self.buffer[self.gap_end..],
        };
    }

    /// Set the entire text content, cursor goes to end
    pub fn setText(self: *LineBuffer, text: []const u8) !void {
        self.clear();
        try self.insert(text);
    }

    /// Clear all text
    pub fn clear(self: *LineBuffer) void {
        self.gap_start = 0;
        self.gap_end = self.buffer.len;
    }

    /// Expand the gap to fit at least `needed` more bytes
    fn expandGap(self: *LineBuffer, needed: usize) !void {
        const new_gap_size = @max(needed * 2, MIN_GAP_SIZE);
        const text_after_len = self.buffer.len - self.gap_end;
        const new_size = self.gap_start + new_gap_size + text_after_len;

        const new_buffer = try self.allocator.alloc(u8, new_size);

        // Copy text before gap
        @memcpy(new_buffer[0..self.gap_start], self.buffer[0..self.gap_start]);

        // Copy text after gap to new position
        const new_gap_end = new_size - text_after_len;
        @memcpy(new_buffer[new_gap_end..], self.buffer[self.gap_end..]);

        self.allocator.free(self.buffer);
        self.buffer = new_buffer;
        self.gap_end = new_gap_end;
    }

    // ─────────────────────────────────────────────────────────────
    // Word operations (for Ctrl+Left/Right, Ctrl+Backspace)
    // ─────────────────────────────────────────────────────────────

    /// Find the start of the previous word
    pub fn wordBoundaryLeft(self: *const LineBuffer) usize {
        if (self.gap_start == 0) return 0;

        var pos = self.gap_start;

        // Skip whitespace
        while (pos > 0 and isWhitespace(self.buffer[pos - 1])) {
            pos -= 1;
        }

        // Skip word characters
        while (pos > 0 and !isWhitespace(self.buffer[pos - 1])) {
            pos -= 1;
        }

        return pos;
    }

    /// Find the end of the next word
    pub fn wordBoundaryRight(self: *const LineBuffer) usize {
        const text_end = self.buffer.len;
        if (self.gap_end >= text_end) return self.gap_start;

        var pos = self.gap_end;

        // Skip whitespace
        while (pos < text_end and isWhitespace(self.buffer[pos])) {
            pos += 1;
        }

        // Skip word characters
        while (pos < text_end and !isWhitespace(self.buffer[pos])) {
            pos += 1;
        }

        // Convert buffer position to logical position
        return self.gap_start + (pos - self.gap_end);
    }

    /// Move cursor to previous word boundary
    pub fn moveCursorWordLeft(self: *LineBuffer) void {
        const target = self.wordBoundaryLeft();
        self.moveCursorTo(target);
    }

    /// Move cursor to next word boundary
    pub fn moveCursorWordRight(self: *LineBuffer) void {
        const target = self.wordBoundaryRight();
        self.moveCursorTo(target);
    }

    /// Delete from cursor to previous word boundary (Ctrl+W / Ctrl+Backspace)
    pub fn deleteWordBackward(self: *LineBuffer) void {
        const target = self.wordBoundaryLeft();
        const to_delete = self.gap_start - target;
        self.deleteBackward(to_delete);
    }

    /// Delete from cursor to next word boundary (Ctrl+Delete)
    pub fn deleteWordForward(self: *LineBuffer) void {
        const target = self.wordBoundaryRight();
        const to_delete = target - self.gap_start;
        self.deleteForward(to_delete);
    }

    /// Delete from cursor to start of line (Ctrl+U)
    pub fn deleteToStart(self: *LineBuffer) void {
        self.deleteBackward(self.gap_start);
    }

    /// Delete from cursor to end of line (Ctrl+K)
    pub fn deleteToEnd(self: *LineBuffer) void {
        self.deleteForward(self.buffer.len - self.gap_end);
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }

    // ─────────────────────────────────────────────────────────────
    // Line operations (for multi-line support)
    // ─────────────────────────────────────────────────────────────

    /// Count total lines (1 + number of newlines)
    pub fn lineCount(self: *const LineBuffer) usize {
        var count: usize = 1;
        for (self.buffer[0..self.gap_start]) |c| {
            if (c == '\n') count += 1;
        }
        for (self.buffer[self.gap_end..]) |c| {
            if (c == '\n') count += 1;
        }
        return count;
    }

    /// Get current line number (0-indexed)
    pub fn currentLine(self: *const LineBuffer) usize {
        var line: usize = 0;
        for (self.buffer[0..self.gap_start]) |c| {
            if (c == '\n') line += 1;
        }
        return line;
    }

    /// Get column position on current line
    pub fn currentColumn(self: *const LineBuffer) usize {
        var col: usize = 0;
        var i = self.gap_start;
        while (i > 0) {
            i -= 1;
            if (self.buffer[i] == '\n') break;
            col += 1;
        }
        return col;
    }
};

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

test "basic insert and get" {
    var buf = try LineBuffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert("hello");
    const text = try buf.getText(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("hello", text);
    try std.testing.expectEqual(@as(usize, 5), buf.len());
    try std.testing.expectEqual(@as(usize, 5), buf.cursor());
}

test "insert at cursor" {
    var buf = try LineBuffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert("helo");
    buf.moveCursorLeft(2);
    try buf.insertChar('l');

    const text = try buf.getText(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("hello", text);
}

test "delete backward" {
    var buf = try LineBuffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert("hello");
    buf.deleteBackward(2);

    const text = try buf.getText(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("hel", text);
}

test "cursor movement" {
    var buf = try LineBuffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert("hello");

    buf.moveCursorToStart();
    try std.testing.expectEqual(@as(usize, 0), buf.cursor());

    buf.moveCursorToEnd();
    try std.testing.expectEqual(@as(usize, 5), buf.cursor());

    buf.moveCursorLeft(2);
    try std.testing.expectEqual(@as(usize, 3), buf.cursor());

    buf.moveCursorRight(1);
    try std.testing.expectEqual(@as(usize, 4), buf.cursor());
}

test "word operations" {
    var buf = try LineBuffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert("hello world test");

    // Cursor at end, find previous word
    try std.testing.expectEqual(@as(usize, 12), buf.wordBoundaryLeft());

    buf.moveCursorWordLeft();
    try std.testing.expectEqual(@as(usize, 12), buf.cursor());

    buf.moveCursorWordLeft();
    try std.testing.expectEqual(@as(usize, 6), buf.cursor());
}

test "clear" {
    var buf = try LineBuffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert("hello");
    buf.clear();

    try std.testing.expectEqual(@as(usize, 0), buf.len());
    try std.testing.expectEqual(@as(usize, 0), buf.cursor());
}

test "setText" {
    var buf = try LineBuffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert("old text");
    try buf.setText("new text");

    const text = try buf.getText(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("new text", text);
}
