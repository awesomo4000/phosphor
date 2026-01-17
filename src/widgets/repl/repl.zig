const std = @import("std");
const Allocator = std.mem.Allocator;
const LineBuffer = @import("line_buffer.zig").LineBuffer;
const phosphor = @import("phosphor");
const DrawCommand = phosphor.DrawCommand;
const Key = phosphor.Key;
const LayoutNode = phosphor.LayoutNode;
const LocalWidgetVTable = phosphor.LocalWidgetVTable;
const LayoutSize = phosphor.LayoutSize;
const Sub = phosphor.Sub;

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

    /// Declare what events this widget wants to receive.
    /// Runtime calls this to build event routing table.
    pub fn subscriptions(self: *const Repl) []const Sub {
        _ = self; // For now, always want these - could vary based on state later
        return &.{ .keyboard, .paste };
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
                // Only change text if actively navigating history
                if (self.history.next()) |text| {
                    try self.buffer.setText(text);
                }
                // Don't clear when reaching end - keep current input
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
                self.buffer.clear();
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
            .ctrl_o => {
                // Emacs-style open-line: insert newline, keep cursor on current line
                try self.buffer.insertChar('\n');
                self.buffer.moveCursorLeft(1);
                return .redraw;
            },
            .shift_enter, .alt_enter => {
                // Insert newline and move to it (standard multiline editing)
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
            // Unhandled keys (page up/down, F-keys, etc.)
            else => {
                return .none;
            },
        }
    }

    /// Submit current input, add to history, clear buffer
    /// Returns allocated copy of text (caller must free)
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

    /// Internal action type (used by handleKey and handleKeyEffect)
    pub const Action = enum {
        none,
        redraw,
        submit,
        cancel,
        eof,
        clear_screen,
    };

    // ─────────────────────────────────────────────────────────────
    // Effect-based API (Lustre-style)
    // ─────────────────────────────────────────────────────────────

    /// Configuration for mapping Repl events to app messages
    /// Pass message constructors for each event type you want to handle
    pub fn MsgConfig(comptime Msg: type) type {
        return struct {
            on_submit: *const fn ([]const u8) Msg,
            on_cancel: Msg,
            on_eof: Msg,
            on_clear_screen: ?Msg = null,
        };
    }

    /// Handle a key event, returning Effect(Msg) for the runtime
    /// This is the new Effect-based API - returns effects instead of ?ReplMsg
    ///
    /// Note: Cursor positioning is handled by the view function (via layoutWithCursor
    /// or Effect.after.set_cursor resolved by the runtime). This function focuses on
    /// dispatching messages for semantic actions.
    pub fn handleKeyEffect(self: *Repl, key: Key, comptime Msg: type, config: MsgConfig(Msg)) !phosphor.Effect(Msg) {
        const action = try self.handleKey(key);

        return switch (action) {
            .none, .redraw => .none,
            .submit => blk: {
                // getTextSlice only works when cursor at end; fall back to getText
                const text_slice = self.buffer.getTextSlice();
                const text_alloc = if (text_slice == null) self.buffer.getText(self.allocator) catch "" else null;
                defer if (text_alloc) |t| self.allocator.free(t);
                const text = text_slice orelse text_alloc.?;

                // Add to history and clear buffer
                if (text.len > 0) {
                    try self.history.add(text);
                }
                self.buffer.clear();
                self.history.resetNavigation();
                break :blk .{ .dispatch = config.on_submit(text) };
            },
            .cancel => .{ .dispatch = config.on_cancel },
            .eof => .{ .dispatch = config.on_eof },
            .clear_screen => if (config.on_clear_screen) |msg|
                .{ .dispatch = msg }
            else
                .none,
        };
    }

    /// Get cursor position (x, y) relative to widget origin
    /// Requires width to calculate wrapping
    pub fn getCursorPosition(self: *const Repl, width: u16) struct { x: u16, y: u16 } {
        const prompt_len: u16 = @intCast(self.config.prompt.len);

        // Guard against degenerate widths
        if (width < 10) return .{ .x = prompt_len, .y = 0 };

        // getTextSlice only works when cursor at end; fall back to getText which allocates
        const text_slice = self.buffer.getTextSlice();
        const text_alloc = if (text_slice == null) self.buffer.getText(self.allocator) catch return .{ .x = prompt_len, .y = 0 } else null;
        defer if (text_alloc) |t| self.allocator.free(t);
        const text = text_slice orelse text_alloc.?;

        const cursor_pos = self.buffer.cursor();
        const cont_len: u16 = 4; // "... "
        const wrap_len: u16 = 4; // "    "

        var cursor_row: u16 = 0;
        var cursor_col: u16 = prompt_len;
        var char_idx: usize = 0;
        var is_first_logical_line = true;
        var line_start: usize = 0;

        // Process each logical line (split by \n)
        var i: usize = 0;
        while (i <= text.len) : (i += 1) {
            const is_newline = i < text.len and text[i] == '\n';
            const is_end = i == text.len;

            if (is_newline or is_end) {
                const line_text = text[line_start..i];
                const prefix_len = if (is_first_logical_line) prompt_len else cont_len;
                const content_width = if (width > prefix_len) width - prefix_len else 1;
                const wrap_content_width = if (width > wrap_len) width - wrap_len else 1;

                if (line_text.len == 0) {
                    if (cursor_pos >= char_idx and cursor_pos <= char_idx) {
                        cursor_col = prefix_len;
                        return .{ .x = cursor_col, .y = cursor_row };
                    }
                    cursor_row += 1;
                } else {
                    var remaining = line_text.len;
                    var first_segment = true;
                    var segment_start: usize = 0;

                    while (remaining > 0) {
                        const seg_width = if (first_segment) content_width else wrap_content_width;
                        const seg_len = @min(remaining, seg_width);
                        const seg_prefix_len: u16 = if (first_segment) prefix_len else wrap_len;

                        const seg_char_start = char_idx + segment_start;
                        const seg_char_end = seg_char_start + seg_len;
                        if (cursor_pos >= seg_char_start and cursor_pos <= seg_char_end) {
                            cursor_col = seg_prefix_len + @as(u16, @intCast(cursor_pos - seg_char_start));
                            return .{ .x = cursor_col, .y = cursor_row };
                        }

                        cursor_row += 1;
                        segment_start += seg_len;
                        remaining -= seg_len;
                        first_segment = false;
                    }
                }

                char_idx += line_text.len;
                if (is_newline) {
                    if (cursor_pos == char_idx) {
                        cursor_col = cont_len;
                        return .{ .x = cursor_col, .y = cursor_row };
                    }
                    char_idx += 1;
                }

                line_start = i + 1;
                is_first_logical_line = false;
            }
        }

        return .{ .x = cursor_col, .y = cursor_row };
    }

    // ─────────────────────────────────────────────────────────────
    // LocalWidget interface (for layout system integration)
    // ─────────────────────────────────────────────────────────────

    /// Returns a LocalWidgetVTable for use with the layout system.
    /// The layout system will track this widget's position, enabling
    /// Effect.after.set_cursor to resolve absolute screen coordinates.
    pub fn localWidget(self: *Repl) LocalWidgetVTable {
        return .{
            .ptr = self,
            .getPreferredHeightFn = localWidgetGetHeight,
            .getPreferredWidthFn = null, // Repl grows to fill width
            .viewFn = localWidgetView,
        };
    }

    fn localWidgetGetHeight(ptr: *anyopaque, width: u16) u16 {
        const self: *Repl = @ptrCast(@alignCast(ptr));
        return self.calculateHeight(width);
    }

    /// Calculate the number of display rows needed for current content
    pub fn calculateHeight(self: *const Repl, width: u16) u16 {
        // Guard against degenerate widths
        if (width < 10) return 1;

        // getTextSlice only works when cursor at end; fall back to getText which allocates
        const text_slice = self.buffer.getTextSlice();
        const text_alloc = if (text_slice == null) self.buffer.getText(self.allocator) catch return 1 else null;
        defer if (text_alloc) |t| self.allocator.free(t);
        const text = text_slice orelse text_alloc.?;

        const prompt_len: u16 = @intCast(self.config.prompt.len);
        const cont_len: u16 = 4; // "... "
        const wrap_len: u16 = 4; // "    "

        var total_rows: u16 = 0;
        var is_first_logical_line = true;
        var line_start: usize = 0;

        // Process each logical line (split by \n)
        var i: usize = 0;
        while (i <= text.len) : (i += 1) {
            const is_newline = i < text.len and text[i] == '\n';
            const is_end = i == text.len;

            if (is_newline or is_end) {
                const line_text = text[line_start..i];
                const prefix_len = if (is_first_logical_line) prompt_len else cont_len;
                const content_width = if (width > prefix_len) width - prefix_len else 1;
                const wrap_content_width = if (width > wrap_len) width - wrap_len else 1;

                if (line_text.len == 0) {
                    total_rows += 1;
                } else {
                    var remaining = line_text.len;
                    var first_segment = true;
                    while (remaining > 0) {
                        const seg_width = if (first_segment) content_width else wrap_content_width;
                        const seg_len = @min(remaining, seg_width);
                        total_rows += 1;
                        remaining -= seg_len;
                        first_segment = false;
                    }
                }

                line_start = i + 1;
                is_first_logical_line = false;
            }
        }

        return if (total_rows == 0) 1 else total_rows;
    }

    fn localWidgetView(ptr: *anyopaque, size: LayoutSize, allocator: Allocator) anyerror![]DrawCommand {
        const self: *Repl = @ptrCast(@alignCast(ptr));

        var commands: std.ArrayListUnmanaged(DrawCommand) = .{};
        errdefer commands.deinit(allocator);

        const prompt = self.config.prompt;

        // Guard against degenerate sizes
        if (size.w < 10) {
            try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = 0 } });
            try commands.append(allocator, .{ .draw_text = .{ .text = prompt } });
            return commands.toOwnedSlice(allocator);
        }

        // getTextSlice() only works when cursor is at end; use getText() as fallback
        const text = self.buffer.getTextSlice() orelse try self.buffer.getText(allocator);
        const continuation = "... ";
        const wrap_indent = "    ";

        const prompt_len: u16 = @intCast(prompt.len);
        const cont_len: u16 = @intCast(continuation.len);
        const wrap_len: u16 = @intCast(wrap_indent.len);
        const width = size.w;

        var row: u16 = 0;
        var is_first_logical_line = true;
        var line_start: usize = 0;

        // Process each logical line (split by \n)
        var i: usize = 0;
        while (i <= text.len) : (i += 1) {
            const is_newline = i < text.len and text[i] == '\n';
            const is_end = i == text.len;

            if (is_newline or is_end) {
                const line_text = text[line_start..i];
                const prefix = if (is_first_logical_line) prompt else continuation;
                const prefix_len = if (is_first_logical_line) prompt_len else cont_len;
                const content_width = if (width > prefix_len) width - prefix_len else 1;
                const wrap_content_width = if (width > wrap_len) width - wrap_len else 1;

                if (line_text.len == 0) {
                    // Empty line - just render prefix
                    try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = row } });
                    try commands.append(allocator, .{ .draw_text = .{ .text = prefix } });
                    row += 1;
                } else {
                    var remaining: usize = line_text.len;
                    var seg_start: usize = 0;
                    var first_segment = true;

                    while (remaining > 0) {
                        const seg_width = if (first_segment) content_width else wrap_content_width;
                        const seg_len = @min(remaining, seg_width);
                        const seg_prefix = if (first_segment) prefix else wrap_indent;

                        try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = row } });
                        // Render prefix + segment
                        const line = try std.fmt.allocPrint(allocator, "{s}{s}", .{
                            seg_prefix,
                            line_text[seg_start .. seg_start + seg_len],
                        });
                        try commands.append(allocator, .{ .draw_text = .{ .text = line } });

                        row += 1;
                        seg_start += seg_len;
                        remaining -= seg_len;
                        first_segment = false;
                    }
                }

                line_start = i + 1;
                is_first_logical_line = false;
            }
        }

        // Handle empty buffer case
        if (row == 0) {
            try commands.append(allocator, .{ .move_cursor = .{ .x = 0, .y = 0 } });
            try commands.append(allocator, .{ .draw_text = .{ .text = prompt } });
        }

        // Add cursor position and show cursor
        const cursor_pos = self.getCursorPosition(size.w);
        try commands.append(allocator, .{ .move_cursor = .{ .x = cursor_pos.x, .y = cursor_pos.y } });
        try commands.append(allocator, .{ .show_cursor = .{ .visible = true } });

        return commands.toOwnedSlice(allocator);
    }

    // ─────────────────────────────────────────────────────────────
    // New declarative view (returns LayoutNode tree)
    // ─────────────────────────────────────────────────────────────

    /// Returns a declarative layout tree describing the REPL
    /// Width is needed for line wrapping
    pub fn viewTree(self: *const Repl, width: u16, frame_alloc: Allocator) !ViewTree {
        const text = try self.buffer.getText(frame_alloc);
        const cursor_pos = self.buffer.cursor();
        const prompt = self.config.prompt;
        const continuation = "... ";
        const wrap_indent = "    ";

        const prompt_len: u16 = @intCast(prompt.len);
        const cont_len: u16 = @intCast(continuation.len);
        const wrap_len: u16 = @intCast(wrap_indent.len);

        // First pass: count total display rows and track cursor position
        var total_rows: usize = 0;
        var cursor_row: usize = 0;
        var cursor_col: usize = 0;
        var char_idx: usize = 0;
        var is_first_logical_line = true;
        var line_start: usize = 0;

        // Process each logical line (split by \n)
        var i: usize = 0;
        while (i <= text.len) : (i += 1) {
            const is_newline = i < text.len and text[i] == '\n';
            const is_end = i == text.len;

            if (is_newline or is_end) {
                const line_text = text[line_start..i];
                const prefix_len = if (is_first_logical_line) prompt_len else cont_len;
                const content_width = if (width > prefix_len) width - prefix_len else 1;
                const wrap_content_width = if (width > wrap_len) width - wrap_len else 1;

                // Count rows for this logical line
                if (line_text.len == 0) {
                    // Empty line = 1 row
                    if (cursor_pos >= char_idx and cursor_pos <= char_idx) {
                        cursor_row = total_rows;
                        cursor_col = prefix_len;
                    }
                    total_rows += 1;
                } else {
                    var remaining = line_text.len;
                    var first_segment = true;
                    var segment_start: usize = 0;

                    while (remaining > 0) {
                        const seg_width = if (first_segment) content_width else wrap_content_width;
                        const seg_len = @min(remaining, seg_width);
                        const seg_prefix_len = if (first_segment) prefix_len else wrap_len;

                        // Check if cursor is in this segment
                        const seg_char_start = char_idx + segment_start;
                        const seg_char_end = seg_char_start + seg_len;
                        if (cursor_pos >= seg_char_start and cursor_pos <= seg_char_end) {
                            cursor_row = total_rows;
                            cursor_col = seg_prefix_len + (cursor_pos - seg_char_start);
                        }

                        total_rows += 1;
                        segment_start += seg_len;
                        remaining -= seg_len;
                        first_segment = false;
                    }
                }

                char_idx += line_text.len;
                if (is_newline) {
                    // Cursor right after newline
                    if (cursor_pos == char_idx) {
                        cursor_row = total_rows;
                        cursor_col = cont_len;
                    }
                    char_idx += 1; // Count the newline
                }

                line_start = i + 1;
                is_first_logical_line = false;
            }
        }

        if (total_rows == 0) total_rows = 1;

        // Second pass: build layout nodes
        const line_nodes = try frame_alloc.alloc(LayoutNode, total_rows);
        var row_idx: usize = 0;
        is_first_logical_line = true;
        line_start = 0;

        i = 0;
        while (i <= text.len) : (i += 1) {
            const is_newline = i < text.len and text[i] == '\n';
            const is_end = i == text.len;

            if (is_newline or is_end) {
                const line_text = text[line_start..i];
                const prefix = if (is_first_logical_line) prompt else continuation;
                const prefix_len = if (is_first_logical_line) prompt_len else cont_len;
                const content_width = if (width > prefix_len) width - prefix_len else 1;
                const wrap_content_width = if (width > wrap_len) width - wrap_len else 1;

                if (line_text.len == 0) {
                    // Empty line
                    const row_children = try frame_alloc.alloc(LayoutNode, 2);
                    row_children[0] = LayoutNode.text(prefix);
                    row_children[1] = LayoutNode.text("");
                    line_nodes[row_idx] = LayoutNode.hbox(row_children);
                    row_idx += 1;
                } else {
                    var remaining: usize = line_text.len;
                    var seg_start: usize = 0;
                    var first_segment = true;

                    while (remaining > 0) {
                        const seg_width = if (first_segment) content_width else wrap_content_width;
                        const seg_len = @min(remaining, seg_width);
                        const seg_prefix = if (first_segment) prefix else wrap_indent;

                        const row_children = try frame_alloc.alloc(LayoutNode, 2);
                        row_children[0] = LayoutNode.text(seg_prefix);
                        row_children[1] = LayoutNode.text(line_text[seg_start .. seg_start + seg_len]);
                        line_nodes[row_idx] = LayoutNode.hbox(row_children);

                        row_idx += 1;
                        seg_start += seg_len;
                        remaining -= seg_len;
                        first_segment = false;
                    }
                }

                line_start = i + 1;
                is_first_logical_line = false;
            }
        }

        return ViewTree{
            .frame_alloc = frame_alloc,
            .text = text,
            .prompt = prompt,
            .cursor_pos = cursor_pos,
            .cursor_row = cursor_row,
            .cursor_col = cursor_col,
            .line_count = total_rows,
            .line_nodes = line_nodes,
        };
    }

    pub const ViewTree = struct {
        frame_alloc: Allocator,
        text: []const u8,
        prompt: []const u8,
        cursor_pos: usize,
        cursor_row: usize,
        cursor_col: usize,
        line_count: usize,
        line_nodes: []LayoutNode,

        /// Build the actual LayoutNode tree
        /// Returns a vbox of lines for multiline, or single hbox for single line
        pub fn build(self: *const ViewTree) LayoutNode {
            if (self.line_count == 1) {
                return self.line_nodes[0];
            }
            return LayoutNode.vbox(self.line_nodes);
        }

        /// Get cursor X position (already includes prefix from viewTree calculation)
        pub fn getCursorX(self: *const ViewTree) u16 {
            return @intCast(self.cursor_col);
        }

        /// Get cursor Y offset from start of repl area
        pub fn getCursorRow(self: *const ViewTree) u16 {
            return @intCast(self.cursor_row);
        }

        /// Get total height in lines
        pub fn getHeight(self: *const ViewTree) u16 {
            return @intCast(self.line_count);
        }

        pub fn deinit(self: *ViewTree) void {
            self.frame_alloc.free(self.text);
            // Note: line_nodes and their children are on frame_alloc, freed with arena
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

    // 6. Test Ctrl+C cancel (should clear buffer)
    const action2 = try repl.handleKey(.ctrl_c);
    try std.testing.expectEqual(Repl.Action.cancel, action2);
    try std.testing.expectEqual(@as(usize, 0), repl.buffer.len()); // Buffer should be cleared

    // 7. Test Ctrl+D EOF on empty line (buffer already cleared by ctrl+c)
    const action3 = try repl.handleKey(.ctrl_d);
    try std.testing.expectEqual(Repl.Action.eof, action3);

    // 8. Verify history was saved
    try std.testing.expectEqual(@as(usize, 1), repl.history.count());
}

test "down arrow does not clear text when not navigating history" {
    var repl = try Repl.init(std.testing.allocator, .{ .prompt = "> " });
    defer repl.deinit();

    // Type some text
    _ = try repl.handleKey(.{ .char = 'h' });
    _ = try repl.handleKey(.{ .char = 'e' });
    _ = try repl.handleKey(.{ .char = 'l' });
    _ = try repl.handleKey(.{ .char = 'l' });
    _ = try repl.handleKey(.{ .char = 'o' });

    // Press down - should NOT clear text (no history to navigate)
    _ = try repl.handleKey(.down);

    const text = try repl.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
}

test "ctrl+o inserts newline but keeps cursor before it" {
    var repl = try Repl.init(std.testing.allocator, .{ .prompt = "> " });
    defer repl.deinit();

    // Type "helloworld"
    _ = try repl.handleKey(.{ .char = 'h' });
    _ = try repl.handleKey(.{ .char = 'e' });
    _ = try repl.handleKey(.{ .char = 'l' });
    _ = try repl.handleKey(.{ .char = 'l' });
    _ = try repl.handleKey(.{ .char = 'o' });
    _ = try repl.handleKey(.{ .char = 'w' });
    _ = try repl.handleKey(.{ .char = 'o' });
    _ = try repl.handleKey(.{ .char = 'r' });
    _ = try repl.handleKey(.{ .char = 'l' });
    _ = try repl.handleKey(.{ .char = 'd' });

    // Move cursor to middle (after "hello")
    _ = try repl.handleKey(.left);
    _ = try repl.handleKey(.left);
    _ = try repl.handleKey(.left);
    _ = try repl.handleKey(.left);
    _ = try repl.handleKey(.left);
    try std.testing.expectEqual(@as(usize, 5), repl.getCursor());

    // Ctrl+O - insert newline but cursor stays before it
    _ = try repl.handleKey(.ctrl_o);

    const text = try repl.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello\nworld", text);

    // Cursor should still be at position 5 (before the newline)
    try std.testing.expectEqual(@as(usize, 5), repl.getCursor());
}

test "getText works correctly when cursor is in middle" {
    var repl = try Repl.init(std.testing.allocator, .{ .prompt = "> " });
    defer repl.deinit();

    // Type "hello"
    _ = try repl.handleKey(.{ .char = 'h' });
    _ = try repl.handleKey(.{ .char = 'e' });
    _ = try repl.handleKey(.{ .char = 'l' });
    _ = try repl.handleKey(.{ .char = 'l' });
    _ = try repl.handleKey(.{ .char = 'o' });

    // Move cursor to middle
    _ = try repl.handleKey(.left);
    _ = try repl.handleKey(.left);
    try std.testing.expectEqual(@as(usize, 3), repl.getCursor());

    // getText should return full text even with cursor in middle
    const text = try repl.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);

    // getTextSlice returns null when cursor not at end
    try std.testing.expect(repl.buffer.getTextSlice() == null);

    // But getTextParts always works
    const parts = repl.buffer.getTextParts();
    try std.testing.expectEqualStrings("hel", parts.before);
    try std.testing.expectEqualStrings("lo", parts.after);
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
