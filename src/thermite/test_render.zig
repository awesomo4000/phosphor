const std = @import("std");
const testing = std.testing;
const MockTerminal = @import("mock_terminal.zig").MockTerminal;
const Renderer = @import("renderer.zig").Renderer;
const Plane = @import("plane.zig").Plane;
const Cell = @import("cell.zig").Cell;
const blocks = @import("blocks.zig");

test "render output inspection" {
    const allocator = testing.allocator;
    
    // Create a mock terminal
    const mt = try MockTerminal.init(allocator, 80, 24);
    defer mt.deinit();
    
    // Create planes for testing
    const front = try Plane.init(allocator, 80, 24);
    defer front.deinit();
    
    const back = try Plane.init(allocator, 80, 24);
    defer back.deinit();
    
    // Set up some test content
    back.setCell(0, 0, Cell{ .ch = '█', .fg = 0xFF0000, .bg = 0x000000 });
    back.setCell(1, 0, Cell{ .ch = '▀', .fg = 0x00FF00, .bg = 0x0000FF });
    
    // Simulate render output
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);
    const writer = output.writer();
    
    // Write what the renderer would write
    try writer.writeAll("\x1b[H"); // Home
    try writer.print("\x1b[38;2;255;0;0m", .{}); // Red fg
    try writer.print("\x1b[48;2;0;0;0m", .{}); // Black bg
    try writer.writeAll("█");
    try writer.print("\x1b[38;2;0;255;0m", .{}); // Green fg
    try writer.print("\x1b[48;2;0;0;255m", .{}); // Blue bg
    try writer.writeAll("▀");
    
    // Feed to mock terminal
    try mt.write(output.items);
    
    // Check results
    const cell1 = mt.getCell(0, 0).?;
    try testing.expect(cell1.ch == '█');
    try testing.expect(cell1.fg == 0xFF0000);
    
    const cell2 = mt.getCell(1, 0).?;
    try testing.expect(cell2.ch == '▀');
    try testing.expect(cell2.fg == 0x00FF00);
    
    // Look for stray characters
    std.debug.print("\nOutput buffer ({} bytes):\n", .{output.items.len});
    for (output.items, 0..) |byte, i| {
        if (byte >= 0x20 and byte <= 0x7E and byte != 0x1b) {
            std.debug.print("  [{:3}] = '{c}' (0x{x:0>2})\n", .{ i, byte, byte });
        }
    }
}

test "detect stray characters in render" {
    const allocator = testing.allocator;
    
    const mt = try MockTerminal.init(allocator, 10, 10);
    defer mt.deinit();
    
    // Test various escape sequences that might produce stray numbers
    const test_sequences = [_][]const u8{
        "\x1b[6", // Incomplete sequence
        "\x1b[38;2;100;6", // Incomplete color
        "\x1b[6;6H", // Valid cursor position
        "\x1b[38;2;255;255;255m6", // Color followed by '6'
    };
    
    for (test_sequences, 0..) |seq, i| {
        mt.clearOutput();
        mt.cursor_x = 0;
        mt.cursor_y = 0;
        
        try mt.write(seq);
        
        std.debug.print("\nTest {}: \"{s}\"\n", .{ i, seq });
        std.debug.print("Cursor at ({}, {})\n", .{ mt.cursor_x, mt.cursor_y });
        
        // Check if '6' appears as a character
        for (0..mt.height) |y| {
            for (0..mt.width) |x| {
                if (mt.getCell(@intCast(x), @intCast(y))) |cell| {
                    if (cell.ch == '6') {
                        std.debug.print("Found '6' at ({}, {})\n", .{ x, y });
                    }
                }
            }
        }
    }
}

test "pixel to block rendering verification" {
    const allocator = testing.allocator;
    
    // Create a simple 4x4 pixel pattern
    const pixels = [_]u32{
        0xFF0000FF, 0xFF0000FF, 0x00FF00FF, 0x00FF00FF,
        0xFF0000FF, 0xFF0000FF, 0x00FF00FF, 0x00FF00FF,
        0x0000FFFF, 0x0000FFFF, 0xFFFF00FF, 0xFFFF00FF,
        0x0000FFFF, 0x0000FFFF, 0xFFFF00FF, 0xFFFF00FF,
    };
    
    const block_mappings = try blocks.pixelBufferToBlocks(&pixels, 4, 4, allocator);
    defer allocator.free(block_mappings);
    
    // Should produce 2x2 blocks
    try testing.expect(block_mappings.len == 4);
    
    // Top-left should be solid red
    try testing.expect(block_mappings[0].ch == blocks.FULL);
    try testing.expect(block_mappings[0].fg == 0xFF0000);
    
    // Top-right should be solid green
    try testing.expect(block_mappings[1].ch == blocks.FULL);
    try testing.expect(block_mappings[1].fg == 0x00FF00);
}