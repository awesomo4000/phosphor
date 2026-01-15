const std = @import("std");
const testing = std.testing;
const MockTerminal = @import("mock_terminal.zig").MockTerminal;
const Renderer = @import("renderer.zig").Renderer;
const Plane = @import("plane.zig").Plane;
const Cell = @import("cell.zig").Cell;
const blocks = @import("blocks.zig");

test "find stray 6 in gradient rendering" {
    const allocator = testing.allocator;
    
    // Create a mock terminal
    const mt = try MockTerminal.init(allocator, 80, 24);
    defer mt.deinit();
    
    // Create a gradient similar to the demo
    const width: u32 = 64;
    const height: u32 = 64;
    const pixels = try allocator.alloc(u32, width * height);
    defer allocator.free(pixels);
    
    // Generate gradient with values that might produce '6' in escape sequences
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = y * width + x;
            // Create values that include 6 in the color components
            const r = @as(u8, @intCast((x * 4) % 256));
            const g = @as(u8, @intCast((y * 4) % 256));
            const b = @as(u8, 60); // Fixed value with 6
            pixels[idx] = (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
        }
    }
    
    // Convert to blocks
    const block_mappings = try blocks.pixelBufferToBlocks(pixels, width, height, allocator);
    defer allocator.free(block_mappings);
    
    // Simulate rendering
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);
    const writer = output.writer();
    
    // Render first few blocks
    try writer.writeAll("\x1b[H"); // Home
    
    for (0..3) |i| {
        const block = block_mappings[i];
        
        // Write color sequences
        const fg_r = (block.fg >> 16) & 0xFF;
        const fg_g = (block.fg >> 8) & 0xFF;
        const fg_b = block.fg & 0xFF;
        try writer.print("\x1b[38;2;{};{};{}m", .{ fg_r, fg_g, fg_b });
        
        const bg_r = (block.bg >> 16) & 0xFF;
        const bg_g = (block.bg >> 8) & 0xFF;
        const bg_b = block.bg & 0xFF;
        try writer.print("\x1b[48;2;{};{};{}m", .{ bg_r, bg_g, bg_b });
        
        // Write character
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(@intCast(block.ch), &buf);
        try writer.writeAll(buf[0..len]);
    }
    
    // Feed to mock terminal
    try mt.write(output.items);
    
    // Look for stray '6' characters
    var found_stray_6 = false;
    for (0..mt.height) |y| {
        for (0..mt.width) |x| {
            if (mt.getCell(@intCast(x), @intCast(y))) |cell| {
                if (cell.ch == '6' and x < 10) { // First 10 columns
                    std.debug.print("\nFound stray '6' at ({}, {})\n", .{ x, y });
                    found_stray_6 = true;
                }
            }
        }
    }
    
    // Debug: print escape sequence that contains '6'
    for (output.items, 0..) |byte, i| {
        if (byte == '6' and i > 0) {
            // Find start of escape sequence
            var start: usize = i;
            while (start > 0 and output.items[start] != 0x1b) {
                start -= 1;
            }
            const end = @min(i + 5, output.items.len);
            std.debug.print("\nEscape sequence with '6' at position {}: ", .{i});
            for (output.items[start..end]) |b| {
                if (b >= 0x20 and b <= 0x7E) {
                    std.debug.print("{c}", .{b});
                } else {
                    std.debug.print("\\x{x:0>2}", .{b});
                }
            }
            std.debug.print("\n", .{});
        }
    }
    
    try testing.expect(!found_stray_6);
}

test "cursor movement edge cases" {
    const allocator = testing.allocator;
    const mt = try MockTerminal.init(allocator, 10, 10);
    defer mt.deinit();
    
    // Test cursor forward at edge
    mt.cursor_x = 9;
    mt.cursor_y = 0;
    try mt.write("\x1b[C"); // Cursor forward
    try testing.expect(mt.cursor_x == 9); // Should not go past edge
    
    // Test incomplete escape at end of line
    mt.cursor_x = 8;
    try mt.write("X\x1b["); // X followed by incomplete escape
    try testing.expect(mt.getCell(8, 0).?.ch == 'X');
    
    // The incomplete escape should not render anything
    try testing.expect(mt.getCell(9, 0).?.ch == ' ');
}