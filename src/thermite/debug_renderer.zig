const std = @import("std");
const Renderer = @import("renderer.zig").Renderer;
const Cell = @import("cell.zig").Cell;
const terminal = @import("terminal.zig");

/// Debug version of render that logs all output
pub fn debugRender(renderer: *Renderer, writer: anytype) !void {
    // Move cursor to home
    try writer.writeAll(terminal.CURSOR_HOME);
    
    // Track current colors to minimize escape sequences
    var current_fg: ?u32 = null;
    var current_bg: ?u32 = null;
    var last_x: u32 = 0;
    var last_y: u32 = 0;

    // Render each cell
    for (0..renderer.term_height) |y| {
        for (0..renderer.term_width) |x| {
            const old_cell = renderer.front_plane.getCell(@intCast(x), @intCast(y));
            const new_cell = renderer.back_plane.getCell(@intCast(x), @intCast(y));

            // Skip if unchanged
            if (old_cell != null and new_cell != null and old_cell.?.eql(new_cell.?.*)) {
                continue;
            }

            if (new_cell) |cell| {
                // Only move cursor if we're not already at the right position
                if (x != last_x + 1 or y != last_y) {
                    try writer.print("\x1b[{};{}H", .{ y + 1, x + 1 });
                    std.debug.print("Move cursor to ({}, {})\n", .{ x, y });
                }

                // Update foreground color if changed
                if (current_fg == null or current_fg.? != cell.fg) {
                    const r = (cell.fg >> 16) & 0xFF;
                    const g = (cell.fg >> 8) & 0xFF;
                    const b = cell.fg & 0xFF;
                    try writer.print("\x1b[38;2;{};{};{}m", .{ r, g, b });
                    std.debug.print("Set FG color: R={}, G={}, B={}\n", .{ r, g, b });
                    current_fg = cell.fg;
                }

                // Update background color if changed
                if (current_bg == null or current_bg.? != cell.bg) {
                    const r = (cell.bg >> 16) & 0xFF;
                    const g = (cell.bg >> 8) & 0xFF;
                    const b = cell.bg & 0xFF;
                    try writer.print("\x1b[48;2;{};{};{}m", .{ r, g, b });
                    std.debug.print("Set BG color: R={}, G={}, B={}\n", .{ r, g, b });
                    current_bg = cell.bg;
                }

                // Write the character
                if (cell.ch <= 0x7F) {
                    try writer.writeByte(@intCast(cell.ch));
                    std.debug.print("Write ASCII: '{}' (0x{x})\n", .{ cell.ch, cell.ch });
                } else {
                    // UTF-8 encode
                    var buf: [4]u8 = undefined;
                    const len = try std.unicode.utf8Encode(@intCast(cell.ch), &buf);
                    try writer.writeAll(buf[0..len]);
                    std.debug.print("Write Unicode: U+{X:0>4}\n", .{cell.ch});
                }
                
                last_x = @intCast(x);
                last_y = @intCast(y);
            }
        }
    }

    // Reset colors at end
    try writer.writeAll(terminal.RESET_ALL);
}