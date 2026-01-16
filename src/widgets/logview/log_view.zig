const std = @import("std");
const Allocator = std.mem.Allocator;
const phosphor = @import("phosphor");
const LayoutNode = phosphor.LayoutNode;
const LocalWidgetVTable = phosphor.LocalWidgetVTable;
const LayoutSize = phosphor.LayoutSize;
const DrawCommand = phosphor.DrawCommand;

/// A scrolling log view widget - displays lines with newest at the bottom.
/// Like a chat client or terminal output.
pub const LogView = struct {
    allocator: Allocator,
    lines: std.ArrayListUnmanaged(Line),
    capacity: usize,

    pub const Line = struct {
        text: []const u8,
        // Could add: timestamp, color, style, etc.
    };

    pub fn init(allocator: Allocator, capacity: usize) LogView {
        return .{
            .allocator = allocator,
            .lines = .{},
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *LogView) void {
        for (self.lines.items) |line| {
            self.allocator.free(line.text);
        }
        self.lines.deinit(self.allocator);
    }

    /// Append a line to the log. If at capacity, oldest line is removed.
    /// If text contains newlines, splits into multiple lines.
    pub fn append(self: *LogView, text: []const u8) !void {
        var iter = std.mem.splitScalar(u8, text, '\n');
        while (iter.next()) |line| {
            try self.appendSingleLine(line);
        }
    }

    /// Append a single line (no newline handling)
    fn appendSingleLine(self: *LogView, text: []const u8) !void {
        // If at capacity, remove oldest
        if (self.lines.items.len >= self.capacity) {
            const removed = self.lines.orderedRemove(0);
            self.allocator.free(removed.text);
        }

        // Copy and store the new line
        const text_copy = try self.allocator.dupe(u8, text);
        try self.lines.append(self.allocator, .{ .text = text_copy });
    }

    /// Append a formatted line. Splits on newlines.
    pub fn print(self: *LogView, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(text);

        var iter = std.mem.splitScalar(u8, text, '\n');
        while (iter.next()) |line| {
            try self.appendSingleLine(line);
        }
    }

    /// Clear all lines
    pub fn clear(self: *LogView) void {
        for (self.lines.items) |line| {
            self.allocator.free(line.text);
        }
        self.lines.clearRetainingCapacity();
    }

    /// Get number of lines
    pub fn count(self: *const LogView) usize {
        return self.lines.items.len;
    }

    /// Get lines to render for a given view height.
    /// Returns the lines that should be visible, with index 0 being the topmost visible line.
    /// The caller should render these from top to bottom of the view area.
    pub fn getVisibleLines(self: *const LogView, view_height: usize) []const Line {
        if (self.lines.items.len == 0) return &.{};

        const visible_count = @min(view_height, self.lines.items.len);
        const start_idx = self.lines.items.len - visible_count;
        return self.lines.items[start_idx..];
    }

    /// Render the log view to the terminal.
    /// Renders from start_row to end_row (inclusive), with newest content at the bottom.
    pub fn render(self: *const LogView, writer: anytype, start_row: u16, end_row: u16, start_col: u16, width: u16) !void {
        const view_height = end_row - start_row + 1;
        const visible = self.getVisibleLines(view_height);

        // Calculate where to start rendering (align to bottom)
        const empty_rows = view_height - visible.len;

        // Clear empty rows at top
        for (0..empty_rows) |i| {
            const row = start_row + @as(u16, @intCast(i));
            try writer.print("\x1b[{};{}H\x1b[K", .{ row + 1, start_col + 1 });
        }

        // Render visible lines
        for (visible, 0..) |line, i| {
            const row = start_row + @as(u16, @intCast(empty_rows + i));
            try writer.print("\x1b[{};{}H\x1b[K", .{ row + 1, start_col + 1 });

            // Truncate if too wide
            const display_len = @min(line.text.len, width);
            try writer.writeAll(line.text[0..display_len]);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // LocalWidget interface (draws at 0,0, layout translates)
    // ─────────────────────────────────────────────────────────────

    /// Get a LocalWidgetVTable for use with LayoutNode.localWidget()
    /// The widget will receive its size at render time from the layout system.
    pub fn localWidget(self: *LogView) LocalWidgetVTable {
        return .{
            .ptr = self,
            .getPreferredHeightFn = null, // Grows to fill
            .viewFn = localView,
        };
    }

    /// Render at local coordinates (0,0). Layout will translate.
    fn localView(ptr: *anyopaque, size: LayoutSize, alloc: Allocator) ![]DrawCommand {
        const self: *LogView = @ptrCast(@alignCast(ptr));

        // Guard against degenerate sizes
        if (size.w < 2 or size.h < 1) {
            const commands = try alloc.alloc(DrawCommand, 0);
            return commands;
        }

        const visible = self.getVisibleLines(size.h);

        // Count commands needed: move+text for each row, accounting for wrapping
        // But cap total rows to available height
        var total_rows: usize = 0;
        for (visible) |line| {
            const line_rows = countWrappedRows(line.text, size.w);
            total_rows += line_rows;
            // Stop counting if we've exceeded available height
            if (total_rows >= size.h) {
                total_rows = size.h;
                break;
            }
        }

        // Each row needs: move_cursor + draw_text = 2 commands per row
        const empty_rows: u16 = @intCast(size.h -| total_rows);
        // Allocate for all rows: empty rows (clear) + content rows
        const cmd_count = size.h * 2;

        var commands = try alloc.alloc(DrawCommand, cmd_count);
        var cmd_idx: usize = 0;

        // Clear empty rows at top (bottom-aligned content)
        for (0..empty_rows) |i| {
            commands[cmd_idx] = .{ .move_cursor = .{ .x = 0, .y = @intCast(i) } };
            cmd_idx += 1;
            commands[cmd_idx] = .clear_line;
            cmd_idx += 1;
        }

        // Render visible lines with wrapping
        var row: u16 = empty_rows;
        for (visible) |line| {
            // Stop if we've filled the view
            if (row >= size.h) break;

            var remaining: []const u8 = line.text;
            // Handle empty lines
            if (remaining.len == 0) {
                commands[cmd_idx] = .{ .move_cursor = .{ .x = 0, .y = row } };
                cmd_idx += 1;
                commands[cmd_idx] = .{ .draw_text = .{ .text = "" } };
                cmd_idx += 1;
                row += 1;
                continue;
            }

            // Wrap text across multiple rows
            while (remaining.len > 0 and row < size.h) {
                const segment_len = @min(remaining.len, size.w);
                commands[cmd_idx] = .{ .move_cursor = .{ .x = 0, .y = row } };
                cmd_idx += 1;
                commands[cmd_idx] = .{ .draw_text = .{ .text = remaining[0..segment_len] } };
                cmd_idx += 1;
                remaining = remaining[segment_len..];
                row += 1;
            }
        }

        return commands[0..cmd_idx];
    }

    // ─────────────────────────────────────────────────────────────
    // Legacy declarative view (returns LayoutNode tree)
    // ─────────────────────────────────────────────────────────────

    /// Returns a declarative layout tree for the log view.
    /// Width is used for wrapping long lines.
    /// Height limits how many lines are shown (pass available screen rows).
    /// Returns a ViewTree that can build LayoutNodes.
    pub fn viewTree(self: *LogView, width: u16, height: u16, frame_alloc: Allocator) !ViewTree {
        const visible = self.getVisibleLines(height);

        // First pass: count total rows needed (including wrapped lines)
        var total_rows: usize = 0;
        for (visible) |line| {
            total_rows += countWrappedRows(line.text, width);
        }

        // Build vbox children: [spacer, ...wrapped rows]
        const children = try frame_alloc.alloc(LayoutNode, total_rows + 1);

        // First child is a spacer that grows to fill empty space
        children[0] = phosphor.Spacer.node();

        // Add wrapped line segments
        var row_idx: usize = 1;
        for (visible) |line| {
            var remaining = line.text;
            while (remaining.len > 0) {
                const segment_len = @min(remaining.len, width);
                children[row_idx] = LayoutNode.text(remaining[0..segment_len]);
                remaining = remaining[segment_len..];
                row_idx += 1;
            }
            // Handle empty lines
            if (line.text.len == 0) {
                children[row_idx] = LayoutNode.text("");
                row_idx += 1;
            }
        }

        return ViewTree{
            .children = children,
            .frame_alloc = frame_alloc,
        };
    }

    /// Count how many rows a line needs when wrapped at given width
    fn countWrappedRows(text: []const u8, width: u16) usize {
        if (text.len == 0) return 1;
        return (text.len + width - 1) / width; // Ceiling division
    }

    pub const ViewTree = struct {
        children: []LayoutNode,
        frame_alloc: Allocator,

        /// Build a vbox containing spacer + visible lines (bottom-aligned)
        pub fn build(self: *const ViewTree) LayoutNode {
            return LayoutNode.vbox(self.children);
        }

        pub fn deinit(self: *ViewTree) void {
            self.frame_alloc.free(self.children);
        }
    };
};

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

test "basic append and get" {
    var log = LogView.init(std.testing.allocator, 100);
    defer log.deinit();

    try log.append("line 1");
    try log.append("line 2");
    try log.append("line 3");

    try std.testing.expectEqual(@as(usize, 3), log.count());

    const visible = log.getVisibleLines(10);
    try std.testing.expectEqual(@as(usize, 3), visible.len);
    try std.testing.expectEqualStrings("line 1", visible[0].text);
    try std.testing.expectEqualStrings("line 2", visible[1].text);
    try std.testing.expectEqualStrings("line 3", visible[2].text);
}

test "capacity limit" {
    var log = LogView.init(std.testing.allocator, 3);
    defer log.deinit();

    try log.append("line 1");
    try log.append("line 2");
    try log.append("line 3");
    try log.append("line 4"); // Should remove "line 1"

    try std.testing.expectEqual(@as(usize, 3), log.count());

    const visible = log.getVisibleLines(10);
    try std.testing.expectEqualStrings("line 2", visible[0].text);
    try std.testing.expectEqualStrings("line 3", visible[1].text);
    try std.testing.expectEqualStrings("line 4", visible[2].text);
}

test "visible lines with limited height" {
    var log = LogView.init(std.testing.allocator, 100);
    defer log.deinit();

    try log.append("line 1");
    try log.append("line 2");
    try log.append("line 3");
    try log.append("line 4");
    try log.append("line 5");

    // Only show last 3 lines
    const visible = log.getVisibleLines(3);
    try std.testing.expectEqual(@as(usize, 3), visible.len);
    try std.testing.expectEqualStrings("line 3", visible[0].text);
    try std.testing.expectEqualStrings("line 4", visible[1].text);
    try std.testing.expectEqualStrings("line 5", visible[2].text);
}

test "print formatted" {
    var log = LogView.init(std.testing.allocator, 100);
    defer log.deinit();

    try log.print("count: {}", .{42});
    try log.print("hello {s}", .{"world"});

    const visible = log.getVisibleLines(10);
    try std.testing.expectEqualStrings("count: 42", visible[0].text);
    try std.testing.expectEqualStrings("hello world", visible[1].text);
}

test "clear" {
    var log = LogView.init(std.testing.allocator, 100);
    defer log.deinit();

    try log.append("line 1");
    try log.append("line 2");
    log.clear();

    try std.testing.expectEqual(@as(usize, 0), log.count());
}
