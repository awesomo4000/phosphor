const std = @import("std");

/// Pure data structure representing drawing operations
pub const DrawCommand = union(enum) {
    move_cursor: struct { x: u16, y: u16 },
    draw_text: struct { text: []const u8 },
    draw_box: struct { 
        x: u16, 
        y: u16, 
        width: u16, 
        height: u16, 
        style: BoxStyle,
    },
    draw_line: struct {
        x: u16,
        y: u16,
        length: u16,
        direction: Direction,
        style: LineStyle,
    },
    set_color: struct { fg: ?Color, bg: ?Color },
    reset_attributes,
    clear_screen,
    clear_line,
    flush,
    show_cursor: struct { visible: bool },
};

pub const Direction = enum {
    horizontal,
    vertical,
};

pub const LineStyle = enum {
    single,
    double,
    dotted,
    heavy,
};

pub const BoxStyle = enum {
    square,
    rounded,
    single,
    double,
    dotted,
    heavy,
};

pub const Color = enum(u8) {
    black = 0,
    blue = 1,
    green = 2,
    cyan = 3,
    red = 4,
    magenta = 5,
    brown = 6,
    light_gray = 7,
    dark_gray = 8,
    light_blue = 9,
    light_green = 10,
    light_cyan = 11,
    light_red = 12,
    light_magenta = 13,
    yellow = 14,
    white = 15,
};

/// Convert widgets to draw commands (pure function)
pub fn widgetToCommands(widget: anytype, allocator: std.mem.Allocator) ![]DrawCommand {
    _ = widget;
    var commands = std.ArrayList(DrawCommand).init(allocator);
    errdefer commands.deinit();
    
    // This will be expanded to handle different widget types
    // For now, just a placeholder
    try commands.append(.clear_screen);
    
    return commands.toOwnedSlice();
}