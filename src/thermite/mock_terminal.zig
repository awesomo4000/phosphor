const std = @import("std");
const Cell = @import("cell.zig").Cell;

/// Mock terminal for testing without a real terminal
pub const MockTerminal = struct {
    width: u32,
    height: u32,
    cells: []Cell,
    output_buffer: std.ArrayList(u8),
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    current_fg: u32 = 0xFFFFFF,
    current_bg: u32 = 0x000000,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !*MockTerminal {
        const mt = try allocator.create(MockTerminal);
        errdefer allocator.destroy(mt);

        const cells = try allocator.alloc(Cell, width * height);
        errdefer allocator.free(cells);

        for (cells) |*cell| {
            cell.* = Cell.init();
        }

        mt.* = .{
            .width = width,
            .height = height,
            .cells = cells,
            .output_buffer = std.ArrayList(u8){},
            .allocator = allocator,
        };

        return mt;
    }

    pub fn deinit(self: *MockTerminal) void {
        self.allocator.free(self.cells);
        self.output_buffer.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Process output data as if it were written to a terminal
    pub fn write(self: *MockTerminal, data: []const u8) !void {
        try self.output_buffer.appendSlice(data);
        
        var i: usize = 0;
        while (i < data.len) {
            if (data[i] == 0x1b and i + 1 < data.len and data[i + 1] == '[') {
                // Parse ANSI escape sequence
                i += 2; // Skip ESC[
                const seq_start = i;
                
                // Find the end of the sequence
                while (i < data.len and !isTerminator(data[i])) {
                    i += 1;
                }
                
                if (i < data.len) {
                    try self.processEscapeSequence(data[seq_start..i], data[i]);
                    i += 1;
                }
            } else if (data[i] == '\n') {
                self.cursor_y += 1;
                self.cursor_x = 0;
                i += 1;
            } else if (data[i] == '\r') {
                self.cursor_x = 0;
                i += 1;
            } else {
                // Regular character
                if (self.cursor_y < self.height and self.cursor_x < self.width) {
                    const idx = self.cursor_y * self.width + self.cursor_x;
                    
                    // Handle UTF-8
                    const char_len = std.unicode.utf8ByteSequenceLength(data[i]) catch 1;
                    if (i + char_len <= data.len) {
                        const codepoint = std.unicode.utf8Decode(data[i..i + char_len]) catch ' ';
                        self.cells[idx] = Cell{
                            .ch = codepoint,
                            .fg = self.current_fg,
                            .bg = self.current_bg,
                        };
                        i += char_len;
                    } else {
                        i += 1;
                    }
                    
                    self.cursor_x += 1;
                } else {
                    i += 1;
                }
            }
        }
    }

    fn isTerminator(c: u8) bool {
        return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
    }

    fn processEscapeSequence(self: *MockTerminal, params: []const u8, terminator: u8) !void {
        switch (terminator) {
            'H' => {
                // Cursor position
                var parts = std.mem.splitScalar(u8, params, ';');
                const row_str = parts.next() orelse "1";
                const col_str = parts.next() orelse "1";
                const row = std.fmt.parseInt(u32, row_str, 10) catch 1;
                const col = std.fmt.parseInt(u32, col_str, 10) catch 1;
                self.cursor_y = if (row > 0) row - 1 else 0;
                self.cursor_x = if (col > 0) col - 1 else 0;
            },
            'J' => {
                // Clear screen
                if (std.mem.eql(u8, params, "2")) {
                    for (self.cells) |*cell| {
                        cell.* = Cell.init();
                    }
                }
            },
            'C' => {
                // Cursor forward
                const n = std.fmt.parseInt(u32, params, 10) catch 1;
                self.cursor_x = @min(self.cursor_x + n, self.width - 1);
            },
            'm' => {
                // SGR (colors)
                var parts = std.mem.splitScalar(u8, params, ';');
                while (parts.next()) |part| {
                    const code = std.fmt.parseInt(u32, part, 10) catch continue;
                    
                    switch (code) {
                        0 => {
                            // Reset
                            self.current_fg = 0xFFFFFF;
                            self.current_bg = 0x000000;
                        },
                        38 => {
                            // Foreground color
                            if (parts.next()) |mode| {
                                if (std.fmt.parseInt(u32, mode, 10) catch 0 == 2) {
                                    // 24-bit color
                                    const r = std.fmt.parseInt(u8, parts.next() orelse "0", 10) catch 0;
                                    const g = std.fmt.parseInt(u8, parts.next() orelse "0", 10) catch 0;
                                    const b = std.fmt.parseInt(u8, parts.next() orelse "0", 10) catch 0;
                                    self.current_fg = (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
                                }
                            }
                        },
                        48 => {
                            // Background color
                            if (parts.next()) |mode| {
                                if (std.fmt.parseInt(u32, mode, 10) catch 0 == 2) {
                                    // 24-bit color
                                    const r = std.fmt.parseInt(u8, parts.next() orelse "0", 10) catch 0;
                                    const g = std.fmt.parseInt(u8, parts.next() orelse "0", 10) catch 0;
                                    const b = std.fmt.parseInt(u8, parts.next() orelse "0", 10) catch 0;
                                    self.current_bg = (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
                                }
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    /// Get the cell at a specific position
    pub fn getCell(self: *MockTerminal, x: u32, y: u32) ?Cell {
        if (x >= self.width or y >= self.height) return null;
        return self.cells[y * self.width + x];
    }

    /// Get the raw output buffer for inspection
    pub fn getOutput(self: *MockTerminal) []const u8 {
        return self.output_buffer.items;
    }

    /// Clear the output buffer
    pub fn clearOutput(self: *MockTerminal) void {
        self.output_buffer.clearRetainingCapacity();
    }

    /// Dump the current screen as text (for debugging)
    pub fn dumpScreen(self: *MockTerminal, writer: anytype) !void {
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const cell = self.cells[y * self.width + x];
                if (cell.ch <= 0x7F and cell.ch >= 0x20) {
                    try writer.writeByte(@intCast(cell.ch));
                } else if (cell.ch == ' ') {
                    try writer.writeByte(' ');
                } else {
                    try writer.writeByte('?');
                }
            }
            try writer.writeByte('\n');
        }
    }
};

test "MockTerminal basic operations" {
    const allocator = std.testing.allocator;
    
    const mt = try MockTerminal.init(allocator, 10, 5);
    defer mt.deinit();

    // Test writing a simple string
    try mt.write("Hello");
    try std.testing.expect(mt.getCell(0, 0).?.ch == 'H');
    try std.testing.expect(mt.getCell(1, 0).?.ch == 'e');
    try std.testing.expect(mt.getCell(2, 0).?.ch == 'l');
    try std.testing.expect(mt.getCell(3, 0).?.ch == 'l');
    try std.testing.expect(mt.getCell(4, 0).?.ch == 'o');

    // Test cursor movement
    try mt.write("\x1b[2;3H");
    try std.testing.expect(mt.cursor_y == 1);
    try std.testing.expect(mt.cursor_x == 2);

    try mt.write("X");
    try std.testing.expect(mt.getCell(2, 1).?.ch == 'X');
}

test "MockTerminal color handling" {
    const allocator = std.testing.allocator;
    
    const mt = try MockTerminal.init(allocator, 10, 5);
    defer mt.deinit();

    // Test 24-bit color
    try mt.write("\x1b[38;2;255;0;0m"); // Red foreground
    try mt.write("\x1b[48;2;0;255;0m"); // Green background
    try mt.write("R");

    const cell = mt.getCell(0, 0).?;
    try std.testing.expect(cell.ch == 'R');
    try std.testing.expect(cell.fg == 0xFF0000); // Red
    try std.testing.expect(cell.bg == 0x00FF00); // Green
}

test "MockTerminal Unicode handling" {
    const allocator = std.testing.allocator;
    
    const mt = try MockTerminal.init(allocator, 10, 5);
    defer mt.deinit();

    // Test Unicode block character
    try mt.write("█");
    try std.testing.expect(mt.getCell(0, 0).?.ch == '█');
}