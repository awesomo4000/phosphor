const std = @import("std");
const testing = std.testing;

/// Sentinel value meaning "use terminal's default color"
pub const DEFAULT_COLOR: u32 = 0xFFFFFFFF;

/// A single terminal cell containing a character and its colors
pub const Cell = struct {
    /// Unicode codepoint (typically a block character)
    ch: u32,
    /// Foreground color in RGB format (0xRRGGBB), or DEFAULT_COLOR for terminal default
    fg: u32,
    /// Background color in RGB format (0xRRGGBB), or DEFAULT_COLOR for terminal default
    bg: u32,

    /// Create a cell with terminal default colors (transparent background)
    pub fn init() Cell {
        return .{
            .ch = ' ',
            .fg = DEFAULT_COLOR, // Terminal default
            .bg = DEFAULT_COLOR, // Terminal default (transparent)
        };
    }

    pub fn eql(self: Cell, other: Cell) bool {
        return self.ch == other.ch and self.fg == other.fg and self.bg == other.bg;
    }
};

test "Cell initialization" {
    const cell = Cell.init();
    try testing.expect(cell.ch == ' ');
    try testing.expect(cell.fg == 0xFFFFFF);
    try testing.expect(cell.bg == 0x000000);
}

test "Cell equality" {
    const cell1 = Cell{ .ch = 'A', .fg = 0xFF0000, .bg = 0x00FF00 };
    const cell2 = Cell{ .ch = 'A', .fg = 0xFF0000, .bg = 0x00FF00 };
    const cell3 = Cell{ .ch = 'B', .fg = 0xFF0000, .bg = 0x00FF00 };
    
    try testing.expect(cell1.eql(cell2));
    try testing.expect(!cell1.eql(cell3));
}