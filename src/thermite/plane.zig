const std = @import("std");
const testing = std.testing;
const Cell = @import("cell.zig").Cell;

/// A 2D plane of cells representing a drawable surface
pub const Plane = struct {
    cells: []Cell,
    width: u32,
    height: u32,
    cursor_y: i32,
    cursor_x: i32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !*Plane {
        const plane = try allocator.create(Plane);
        errdefer allocator.destroy(plane);

        const cell_count = width * height;
        const cells = try allocator.alloc(Cell, cell_count);
        errdefer allocator.free(cells);

        // Initialize all cells to blank
        for (cells) |*cell| {
            cell.* = Cell.init();
        }

        plane.* = .{
            .cells = cells,
            .width = width,
            .height = height,
            .cursor_y = 0,
            .cursor_x = 0,
            .allocator = allocator,
        };

        return plane;
    }

    pub fn deinit(self: *Plane) void {
        self.allocator.free(self.cells);
        self.allocator.destroy(self);
    }

    pub fn clear(self: *Plane) void {
        for (self.cells) |*cell| {
            cell.* = Cell.init();
        }
        self.cursor_y = 0;
        self.cursor_x = 0;
    }

    pub fn getCell(self: *const Plane, x: u32, y: u32) ?*const Cell {
        if (x >= self.width or y >= self.height) return null;
        return &self.cells[y * self.width + x];
    }

    pub fn getCellMut(self: *Plane, x: u32, y: u32) ?*Cell {
        if (x >= self.width or y >= self.height) return null;
        return &self.cells[y * self.width + x];
    }

    pub fn setCell(self: *Plane, x: u32, y: u32, cell: Cell) void {
        if (self.getCellMut(x, y)) |c| {
            c.* = cell;
        }
    }

    pub fn fill(self: *Plane, cell: Cell) void {
        for (self.cells) |*c| {
            c.* = cell;
        }
    }

    /// Copy the contents of another plane into this one
    pub fn copyFrom(self: *Plane, other: *const Plane) void {
        if (self.width != other.width or self.height != other.height) return;
        std.mem.copyForwards(Cell, self.cells, other.cells);
    }
};

test "Plane initialization and basic operations" {
    const allocator = testing.allocator;
    
    const plane = try Plane.init(allocator, 10, 5);
    defer plane.deinit();

    try testing.expect(plane.width == 10);
    try testing.expect(plane.height == 5);
    try testing.expect(plane.cells.len == 50);

    // Test that all cells are initialized
    for (plane.cells) |cell| {
        try testing.expect(cell.ch == ' ');
    }

    // Test cell access
    const cell = plane.getCell(5, 2).?;
    try testing.expect(cell.ch == ' ');

    // Test out of bounds
    try testing.expect(plane.getCell(10, 5) == null);

    // Test setting a cell
    plane.setCell(3, 2, Cell{ .ch = 'X', .fg = 0xFF0000, .bg = 0x00FF00 });
    const modified = plane.getCell(3, 2).?;
    try testing.expect(modified.ch == 'X');
}

test "Plane fill and clear" {
    const allocator = testing.allocator;
    
    const plane = try Plane.init(allocator, 5, 5);
    defer plane.deinit();

    // Fill with a specific cell
    const fill_cell = Cell{ .ch = '#', .fg = 0x0000FF, .bg = 0xFFFF00 };
    plane.fill(fill_cell);

    for (plane.cells) |cell| {
        try testing.expect(cell.eql(fill_cell));
    }

    // Clear should reset to default
    plane.clear();
    for (plane.cells) |cell| {
        try testing.expect(cell.ch == ' ');
    }
}