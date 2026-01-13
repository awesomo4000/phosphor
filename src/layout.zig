const std = @import("std");
const Allocator = std.mem.Allocator;
const render_commands = @import("render_commands.zig");
const DrawCommand = render_commands.DrawCommand;

/// Calculate how many bytes of a UTF-8 string fit in the given column width.
/// Assumes each codepoint takes 1 column (doesn't handle wide chars like CJK).
fn utf8BytesForColumns(str: []const u8, max_cols: u16) usize {
    var cols: u16 = 0;
    var bytes: usize = 0;

    while (bytes < str.len and cols < max_cols) {
        const byte = str[bytes];
        // UTF-8 leading byte tells us how many bytes in this codepoint
        const codepoint_len: usize = if (byte < 0x80) 1 // ASCII
        else if (byte < 0xE0) 2 // 2-byte sequence
        else if (byte < 0xF0) 3 // 3-byte sequence
        else 4; // 4-byte sequence

        if (bytes + codepoint_len > str.len) break; // Truncated sequence
        bytes += codepoint_len;
        cols += 1;
    }

    return bytes;
}

/// Rectangle bounds for layout
pub const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    pub fn right(self: Rect) u16 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) u16 {
        return self.y + self.h;
    }
};

/// Layout direction
pub const Direction = enum {
    horizontal,
    vertical,
};

/// How an element sizes along one axis
pub const SizingAxis = union(enum) {
    /// Fixed size in characters/rows
    fixed: u16,

    /// Fit to content with min/max bounds
    fit: struct { min: u16 = 0, max: u16 = 65535 },

    /// Grow to fill available space with min/max bounds
    grow: struct { min: u16 = 0, max: u16 = 65535 },
};

/// Sizing for both axes
pub const Sizing = struct {
    w: SizingAxis = .{ .grow = .{} },
    h: SizingAxis = .{ .grow = .{} },
};

/// Padding on all sides
pub const Padding = struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,

    pub fn all(size: u16) Padding {
        return .{ .left = size, .right = size, .top = size, .bottom = size };
    }

    pub fn xy(v: u16, h: u16) Padding {
        return .{ .left = h, .right = h, .top = v, .bottom = v };
    }

    pub fn horizontal(self: Padding) u16 {
        return self.left + self.right;
    }

    pub fn vertical(self: Padding) u16 {
        return self.top + self.bottom;
    }
};

/// Interface for widgets that can be laid out
pub const WidgetVTable = struct {
    ptr: *anyopaque,

    /// Given available width, what height does this widget prefer?
    /// Used for text wrapping and content-based sizing.
    getPreferredHeightFn: ?*const fn (ptr: *anyopaque, width: u16) u16 = null,

    /// What width does this widget prefer (for horizontal fit sizing)?
    getPreferredWidthFn: ?*const fn (ptr: *anyopaque) u16 = null,

    /// Render the widget into the given bounds
    viewFn: *const fn (ptr: *anyopaque, bounds: Rect, allocator: Allocator) anyerror![]DrawCommand,

    pub fn getPreferredHeight(self: WidgetVTable, width: u16) u16 {
        if (self.getPreferredHeightFn) |f| {
            return f(self.ptr, width);
        }
        return 1; // Default: single row
    }

    pub fn getPreferredWidth(self: WidgetVTable) u16 {
        if (self.getPreferredWidthFn) |f| {
            return f(self.ptr);
        }
        return 1; // Default: single column
    }

    pub fn view(self: WidgetVTable, bounds: Rect, allocator: Allocator) ![]DrawCommand {
        return self.viewFn(self.ptr, bounds, allocator);
    }
};

/// A node in the layout tree
pub const LayoutNode = struct {
    /// How this node sizes within its parent
    sizing: Sizing = .{},

    /// Padding inside this node
    padding: Padding = .{},

    /// Gap between children
    gap: u16 = 0,

    /// Layout direction for children
    direction: Direction = .vertical,

    /// Content: either a widget (leaf) or children (branch)
    content: Content,

    pub const Content = union(enum) {
        /// Leaf node with a widget (legacy vtable approach)
        widget: WidgetVTable,

        /// Branch node with children
        children: []const LayoutNode,

        /// Empty placeholder
        empty,

        // ─────────────────────────────────────────────────────────────
        // Declarative node types (new approach)
        // ─────────────────────────────────────────────────────────────

        /// Simple text content
        text: []const u8,

        /// Cursor position marker - runtime will position cursor here
        cursor,

        /// Styled content - applies fg/bg color to child
        styled: StyledContent,

        pub const StyledContent = struct {
            fg: ?u32 = null,
            bg: ?u32 = null,
            child: *const LayoutNode,
        };
    };

    /// Create a leaf node from a widget
    pub fn leaf(widget: WidgetVTable) LayoutNode {
        return .{ .content = .{ .widget = widget } };
    }

    /// Create a leaf node with sizing
    pub fn leafSized(widget: WidgetVTable, sizing: Sizing) LayoutNode {
        return .{ .sizing = sizing, .content = .{ .widget = widget } };
    }

    /// Create a branch node with children
    pub fn branch(children: []const LayoutNode) LayoutNode {
        return .{ .content = .{ .children = children } };
    }

    /// Create a vertical container
    pub fn vbox(children: []const LayoutNode) LayoutNode {
        return .{ .direction = .vertical, .content = .{ .children = children } };
    }

    /// Create a horizontal container
    pub fn hbox(children: []const LayoutNode) LayoutNode {
        return .{ .direction = .horizontal, .content = .{ .children = children } };
    }

    // ─────────────────────────────────────────────────────────────
    // Declarative node constructors
    // ─────────────────────────────────────────────────────────────

    /// Create a text node
    pub fn text(str: []const u8) LayoutNode {
        return .{
            .sizing = .{ .w = .{ .fit = .{} }, .h = .{ .fixed = 1 } },
            .content = .{ .text = str },
        };
    }

    /// Create a cursor marker node
    pub fn cursorNode() LayoutNode {
        return .{
            .sizing = .{ .w = .{ .fixed = 0 }, .h = .{ .fixed = 0 } },
            .content = .cursor,
        };
    }

    /// Create a styled wrapper
    pub fn styled(fg: ?u32, bg: ?u32, child: *const LayoutNode) LayoutNode {
        return .{
            .content = .{ .styled = .{ .fg = fg, .bg = bg, .child = child } },
        };
    }
};

/// Calculate layout and render the tree
pub fn renderTree(
    node: *const LayoutNode,
    bounds: Rect,
    allocator: Allocator,
) ![]DrawCommand {
    var commands: std.ArrayListUnmanaged(DrawCommand) = .{};
    errdefer commands.deinit(allocator);

    try renderNode(node, bounds, allocator, &commands);

    return commands.toOwnedSlice(allocator);
}

fn renderNode(
    node: *const LayoutNode,
    bounds: Rect,
    allocator: Allocator,
    commands: *std.ArrayListUnmanaged(DrawCommand),
) !void {
    // Apply padding to get content area
    const content_bounds = Rect{
        .x = bounds.x + node.padding.left,
        .y = bounds.y + node.padding.top,
        .w = bounds.w -| node.padding.horizontal(),
        .h = bounds.h -| node.padding.vertical(),
    };

    switch (node.content) {
        .widget => |widget| {
            // Leaf: render the widget (legacy vtable approach)
            const widget_commands = try widget.view(content_bounds, allocator);
            defer allocator.free(widget_commands);
            try commands.appendSlice(allocator, widget_commands);
        },
        .children => |children| {
            // Branch: calculate child bounds and render each
            const child_bounds = try calculateChildBounds(node, children, content_bounds, allocator);
            defer allocator.free(child_bounds);

            for (children, child_bounds) |*child, cb| {
                try renderNode(child, cb, allocator, commands);
            }
        },
        .empty => {},

        // ─────────────────────────────────────────────────────────────
        // Declarative node rendering
        // ─────────────────────────────────────────────────────────────

        .text => |str| {
            // Render text at current position
            try commands.append(allocator, .{ .move_cursor = .{ .x = content_bounds.x, .y = content_bounds.y } });
            // Truncate to width in columns (not bytes) - UTF-8 aware
            const display_bytes = utf8BytesForColumns(str, content_bounds.w);
            if (display_bytes > 0) {
                try commands.append(allocator, .{ .draw_text = .{ .text = str[0..display_bytes] } });
            }
        },
        .cursor => {
            // Mark cursor position - runtime will show cursor here
            try commands.append(allocator, .{ .move_cursor = .{ .x = content_bounds.x, .y = content_bounds.y } });
            try commands.append(allocator, .{ .show_cursor = .{ .visible = true } });
        },
        .styled => |style| {
            // Apply colors, render child, reset
            if (style.fg != null or style.bg != null) {
                try commands.append(allocator, .{ .set_color = .{
                    .fg = if (style.fg) |fg| colorFromU32(fg) else null,
                    .bg = if (style.bg) |bg| colorFromU32(bg) else null,
                } });
            }
            try renderNode(style.child, content_bounds, allocator, commands);
            if (style.fg != null or style.bg != null) {
                try commands.append(allocator, .reset_attributes);
            }
        },
    }
}

/// Convert u32 RGB to Color enum (finds closest match)
fn colorFromU32(rgb: u32) render_commands.Color {
    // For now, just map to basic colors - could do better matching later
    const r: u8 = @truncate(rgb >> 16);
    const g: u8 = @truncate(rgb >> 8);
    const b: u8 = @truncate(rgb);

    // Simple brightness-based mapping
    const brightness = (@as(u16, r) + @as(u16, g) + @as(u16, b)) / 3;

    if (brightness < 64) return .black;
    if (brightness < 192) return .light_gray;
    return .white;
}

/// Calculate bounds for each child based on sizing rules
fn calculateChildBounds(
    parent: *const LayoutNode,
    children: []const LayoutNode,
    available: Rect,
    allocator: Allocator,
) ![]Rect {
    var bounds = try allocator.alloc(Rect, children.len);
    errdefer allocator.free(bounds);

    if (children.len == 0) return bounds;

    const is_vertical = parent.direction == .vertical;
    const total_gap = parent.gap * @as(u16, @intCast(children.len -| 1));
    const available_main = if (is_vertical)
        available.h -| total_gap
    else
        available.w -| total_gap;

    // First pass: calculate fixed and fit sizes, count grow children
    var fixed_total: u16 = 0;
    var grow_count: u16 = 0;
    var child_sizes = try allocator.alloc(u16, children.len);
    defer allocator.free(child_sizes);

    for (children, 0..) |*child, i| {
        const sizing = if (is_vertical) child.sizing.h else child.sizing.w;
        switch (sizing) {
            .fixed => |size| {
                child_sizes[i] = size;
                fixed_total += size;
            },
            .fit => |fit| {
                // Ask widget for preferred size
                const preferred = getPreferredSize(child, available, is_vertical);
                child_sizes[i] = std.math.clamp(preferred, fit.min, fit.max);
                fixed_total += child_sizes[i];
            },
            .grow => {
                child_sizes[i] = 0; // Will be calculated
                grow_count += 1;
            },
        }
    }

    // Second pass: distribute remaining space to grow children
    if (grow_count > 0) {
        const remaining = available_main -| fixed_total;
        const per_grow = remaining / grow_count;
        var extra = remaining % grow_count;

        for (children, 0..) |*child, i| {
            const sizing = if (is_vertical) child.sizing.h else child.sizing.w;
            if (sizing == .grow) {
                const grow = sizing.grow;
                var size = per_grow;
                if (extra > 0) {
                    size += 1;
                    extra -= 1;
                }
                child_sizes[i] = std.math.clamp(size, grow.min, grow.max);
            }
        }
    }

    // Third pass: position children
    var pos: u16 = if (is_vertical) available.y else available.x;

    for (0..children.len) |i| {
        if (is_vertical) {
            bounds[i] = .{
                .x = available.x,
                .y = pos,
                .w = available.w,
                .h = child_sizes[i],
            };
        } else {
            bounds[i] = .{
                .x = pos,
                .y = available.y,
                .w = child_sizes[i],
                .h = available.h,
            };
        }
        pos += child_sizes[i] + parent.gap;
    }

    return bounds;
}

/// Get preferred size of a node along the main axis
fn getPreferredSize(node: *const LayoutNode, available: Rect, is_vertical: bool) u16 {
    switch (node.content) {
        .widget => |widget| {
            if (is_vertical) {
                // For vertical layout, ask widget for height given width
                return widget.getPreferredHeight(available.w);
            } else {
                // For horizontal layout, ask widget for preferred width
                return widget.getPreferredWidth();
            }
        },
        .children => |children| {
            // Sum children's preferred sizes
            var total: u16 = 0;
            for (children) |*child| {
                total += getPreferredSize(child, available, is_vertical);
            }
            const gaps = node.gap * @as(u16, @intCast(children.len -| 1));
            return total + gaps + node.padding.vertical();
        },
        .empty => return 0,

        // Declarative nodes
        .text => |str| {
            if (is_vertical) {
                return 1; // Text is single line
            } else {
                return @intCast(@min(str.len, 65535));
            }
        },
        .cursor => return 0, // Cursor has no size
        .styled => |style| {
            return getPreferredSize(style.child, available, is_vertical);
        },
    }
}

// ─────────────────────────────────────────────────────────────
// Simple Text Widget
// ─────────────────────────────────────────────────────────────

/// A simple text widget for labels and headers
pub const Text = struct {
    text: []const u8,

    pub fn init(text: []const u8) Text {
        return .{ .text = text };
    }

    pub fn widget(self: *const Text) WidgetVTable {
        return .{
            .ptr = @constCast(@ptrCast(self)),
            .getPreferredWidthFn = getPreferredWidth,
            .viewFn = view,
        };
    }

    fn getPreferredWidth(ptr: *anyopaque) u16 {
        const self: *const Text = @ptrCast(@alignCast(ptr));
        return @intCast(self.text.len);
    }

    fn view(ptr: *anyopaque, bounds: Rect, allocator: Allocator) ![]DrawCommand {
        const self: *const Text = @ptrCast(@alignCast(ptr));
        var commands = try allocator.alloc(DrawCommand, 2);
        commands[0] = .{ .move_cursor = .{ .x = bounds.x, .y = bounds.y } };
        // Truncate to fit bounds (UTF-8 aware)
        const display_bytes = utf8BytesForColumns(self.text, bounds.w);
        commands[1] = .{ .draw_text = .{ .text = self.text[0..display_bytes] } };
        return commands;
    }
};

/// A spacer that grows to fill available space
pub const Spacer = struct {
    pub fn node() LayoutNode {
        return .{ .sizing = .{ .w = .{ .grow = .{} }, .h = .{ .grow = .{} } }, .content = .empty };
    }
};

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

test "vertical layout with fixed sizes" {
    const allocator = std.testing.allocator;

    // Mock widget that just returns empty commands
    const mock_view = struct {
        fn view(_: *anyopaque, _: Rect, alloc: Allocator) ![]DrawCommand {
            return try alloc.alloc(DrawCommand, 0);
        }
    }.view;

    var dummy: u8 = 0;
    const widget = WidgetVTable{
        .ptr = &dummy,
        .viewFn = mock_view,
    };

    const layout = LayoutNode{
        .direction = .vertical,
        .content = .{ .children = &[_]LayoutNode{
            .{ .sizing = .{ .h = .{ .fixed = 3 } }, .content = .{ .widget = widget } },
            .{ .sizing = .{ .h = .{ .grow = .{} } }, .content = .{ .widget = widget } },
            .{ .sizing = .{ .h = .{ .fixed = 5 } }, .content = .{ .widget = widget } },
        } },
    };

    const available = Rect{ .x = 0, .y = 0, .w = 80, .h = 24 };

    // Calculate bounds
    const child_bounds = try calculateChildBounds(&layout, layout.content.children, available, allocator);
    defer allocator.free(child_bounds);

    // Header: fixed 3
    try std.testing.expectEqual(@as(u16, 0), child_bounds[0].y);
    try std.testing.expectEqual(@as(u16, 3), child_bounds[0].h);

    // Middle: grows to fill (24 - 3 - 5 = 16)
    try std.testing.expectEqual(@as(u16, 3), child_bounds[1].y);
    try std.testing.expectEqual(@as(u16, 16), child_bounds[1].h);

    // Footer: fixed 5
    try std.testing.expectEqual(@as(u16, 19), child_bounds[2].y);
    try std.testing.expectEqual(@as(u16, 5), child_bounds[2].h);
}

test "layout with gap" {
    const allocator = std.testing.allocator;

    const mock_view = struct {
        fn view(_: *anyopaque, _: Rect, alloc: Allocator) ![]DrawCommand {
            return try alloc.alloc(DrawCommand, 0);
        }
    }.view;

    var dummy: u8 = 0;
    const widget = WidgetVTable{
        .ptr = &dummy,
        .viewFn = mock_view,
    };

    const layout = LayoutNode{
        .direction = .vertical,
        .gap = 1,
        .content = .{ .children = &[_]LayoutNode{
            .{ .sizing = .{ .h = .{ .fixed = 3 } }, .content = .{ .widget = widget } },
            .{ .sizing = .{ .h = .{ .grow = .{} } }, .content = .{ .widget = widget } },
        } },
    };

    const available = Rect{ .x = 0, .y = 0, .w = 80, .h = 24 };

    const child_bounds = try calculateChildBounds(&layout, layout.content.children, available, allocator);
    defer allocator.free(child_bounds);

    // Header at 0, height 3
    try std.testing.expectEqual(@as(u16, 0), child_bounds[0].y);
    try std.testing.expectEqual(@as(u16, 3), child_bounds[0].h);

    // Content at 4 (3 + 1 gap), height 20 (24 - 3 - 1 gap)
    try std.testing.expectEqual(@as(u16, 4), child_bounds[1].y);
    try std.testing.expectEqual(@as(u16, 20), child_bounds[1].h);
}

test "horizontal layout" {
    const allocator = std.testing.allocator;

    const mock_view = struct {
        fn view(_: *anyopaque, _: Rect, alloc: Allocator) ![]DrawCommand {
            return try alloc.alloc(DrawCommand, 0);
        }
    }.view;

    var dummy: u8 = 0;
    const widget = WidgetVTable{
        .ptr = &dummy,
        .viewFn = mock_view,
    };

    const layout = LayoutNode{
        .direction = .horizontal,
        .content = .{ .children = &[_]LayoutNode{
            .{ .sizing = .{ .w = .{ .fixed = 20 } }, .content = .{ .widget = widget } },
            .{ .sizing = .{ .w = .{ .grow = .{} } }, .content = .{ .widget = widget } },
        } },
    };

    const available = Rect{ .x = 0, .y = 0, .w = 80, .h = 24 };

    const child_bounds = try calculateChildBounds(&layout, layout.content.children, available, allocator);
    defer allocator.free(child_bounds);

    // Sidebar: fixed 20
    try std.testing.expectEqual(@as(u16, 0), child_bounds[0].x);
    try std.testing.expectEqual(@as(u16, 20), child_bounds[0].w);

    // Content: grows to fill (80 - 20 = 60)
    try std.testing.expectEqual(@as(u16, 20), child_bounds[1].x);
    try std.testing.expectEqual(@as(u16, 60), child_bounds[1].w);
}
