const std = @import("std");
const Allocator = std.mem.Allocator;
const phosphor = @import("phosphor");
const LayoutNode = phosphor.LayoutNode;

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
    pub fn append(self: *LogView, text: []const u8) !void {
        // If at capacity, remove oldest
        if (self.lines.items.len >= self.capacity) {
            const removed = self.lines.orderedRemove(0);
            self.allocator.free(removed.text);
        }

        // Copy and store the new line
        const text_copy = try self.allocator.dupe(u8, text);
        try self.lines.append(self.allocator, .{ .text = text_copy });
    }

    /// Append a formatted line
    pub fn print(self: *LogView, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(text);

        // If at capacity, remove oldest
        if (self.lines.items.len >= self.capacity) {
            const removed = self.lines.orderedRemove(0);
            self.allocator.free(removed.text);
        }

        try self.lines.append(self.allocator, .{ .text = text });
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
    // New declarative view (returns LayoutNode tree)
    // ─────────────────────────────────────────────────────────────

    /// Returns a declarative layout tree for the log view.
    /// view_height determines how many lines to show.
    /// Returns a ViewTree that can build LayoutNodes.
    pub fn viewTree(self: *const LogView, view_height: usize, frame_alloc: Allocator) !ViewTree {
        const visible = self.getVisibleLines(view_height);

        // Allocate array of LayoutNodes for each line
        const line_nodes = try frame_alloc.alloc(LayoutNode, visible.len);
        for (visible, 0..) |line, i| {
            line_nodes[i] = LayoutNode.text(line.text);
        }

        return ViewTree{
            .line_nodes = line_nodes,
            .frame_alloc = frame_alloc,
        };
    }

    pub const ViewTree = struct {
        line_nodes: []LayoutNode,
        frame_alloc: Allocator,

        /// Build a vbox containing all visible lines
        pub fn build(self: *const ViewTree) LayoutNode {
            return LayoutNode.vbox(self.line_nodes);
        }

        pub fn deinit(self: *ViewTree) void {
            self.frame_alloc.free(self.line_nodes);
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
