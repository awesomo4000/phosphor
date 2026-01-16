const std = @import("std");
const Allocator = std.mem.Allocator;
const layout = @import("../layout.zig");
const render_commands = @import("../render_commands.zig");
const LayoutNode = layout.LayoutNode;
const LocalWidgetVTable = layout.LocalWidgetVTable;
const LayoutSize = layout.Size;
const DrawCommand = render_commands.DrawCommand;

/// A horizontal separator line that fills available width.
/// Renders "─" characters to fill the allocated space.
pub const Separator = struct {
    /// Create a separator layout node (height=1, fills width)
    pub fn node() LayoutNode {
        return .{
            .sizing = .{ .w = .{ .grow = .{} }, .h = .{ .fixed = 1 } },
            .content = .{ .local_widget = vtable() },
        };
    }

    fn vtable() LocalWidgetVTable {
        return .{
            .ptr = undefined, // Stateless widget
            .viewFn = render,
        };
    }

    fn render(_: *anyopaque, size: LayoutSize, allocator: Allocator) ![]DrawCommand {
        var commands = try allocator.alloc(DrawCommand, 2);
        commands[0] = .{ .move_cursor = .{ .x = 0, .y = 0 } };

        // Build separator string to fill width
        const sep = try allocator.alloc(u8, size.w * 3);
        var idx: usize = 0;
        for (0..size.w) |_| {
            sep[idx] = 0xe2; // UTF-8 for ─
            sep[idx + 1] = 0x94;
            sep[idx + 2] = 0x80;
            idx += 3;
        }
        commands[1] = .{ .draw_text = .{ .text = sep[0..idx] } };

        return commands;
    }
};
