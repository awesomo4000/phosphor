const std = @import("std");
const testing = std.testing;

// Unicode block elements for pixel representation
pub const EMPTY = ' ';
pub const FULL = '█';
pub const UPPER_HALF = '▀';
pub const LOWER_HALF = '▄';
pub const LEFT_HALF = '▌';
pub const RIGHT_HALF = '▐';

// Quadrant blocks for 2x2 pixel mapping
pub const QUADRANTS = [16]u32{
    ' ',  // 0000 - Empty
    '▘',  // 0001 - Upper left
    '▝',  // 0010 - Upper right  
    '▀',  // 0011 - Upper half
    '▖',  // 0100 - Lower left
    '▌',  // 0101 - Left half
    '▞',  // 0110 - Diagonal \
    '▛',  // 0111 - Missing lower right
    '▗',  // 1000 - Lower right
    '▚',  // 1001 - Diagonal /
    '▐',  // 1010 - Right half
    '▜',  // 1011 - Missing lower left
    '▄',  // 1100 - Lower half
    '▙',  // 1101 - Missing upper right
    '▟',  // 1110 - Missing upper left
    '█',  // 1111 - Full block
};

pub const BlockMapping = struct {
    ch: u32,
    fg: u32,
    bg: u32,
};

/// Convert a 2x2 pixel block to the optimal Unicode character representation
/// pixels: [upper_left, upper_right, lower_left, lower_right] in RGBA format
pub fn pixelsToBlock(pixels: [4]u32) BlockMapping {
    // Extract RGB values (ignore alpha) - RGBA is 0xRRGGBBAA
    const colors = [4]u32{
        (pixels[0] >> 8) & 0xFFFFFF,
        (pixels[1] >> 8) & 0xFFFFFF,
        (pixels[2] >> 8) & 0xFFFFFF,
        (pixels[3] >> 8) & 0xFFFFFF,
    };

    // Count unique colors - use stack array (max 4 colors in 2x2 block)
    var unique_colors: [4]u32 = undefined;
    var num_unique: usize = 0;

    for (colors) |color| {
        var found = false;
        for (unique_colors[0..num_unique]) |uc| {
            if (uc == color) {
                found = true;
                break;
            }
        }
        if (!found and num_unique < 4) {
            unique_colors[num_unique] = color;
            num_unique += 1;
        }
    }

    // Simple case: all same color
    if (num_unique == 1) {
        return BlockMapping{
            .ch = FULL,
            .fg = unique_colors[0],
            .bg = unique_colors[0],
        };
    }

    // Two color case (most common)
    if (num_unique == 2) {
        const color1 = unique_colors[0];
        const color2 = unique_colors[1];

        // Count occurrences of each color
        var count1: u32 = 0;
        var count2: u32 = 0;
        for (colors) |color| {
            if (color == color1) count1 += 1;
            if (color == color2) count2 += 1;
        }

        // Choose the less common color as foreground (better for block characters)
        const fg_color = if (count1 <= count2) color1 else color2;
        const bg_color = if (count1 <= count2) color2 else color1;

        // Create a bitmask based on which pixels match foreground color
        var mask: u8 = 0;
        for (colors, 0..) |color, i| {
            if (color == fg_color) {
                mask |= @as(u8, 1) << @intCast(i);
            }
        }

        return BlockMapping{
            .ch = QUADRANTS[mask],
            .fg = fg_color,
            .bg = bg_color,
        };
    }

    // More than 2 colors: approximate by using most common color as background
    // and picking the best quadrant pattern
    var color_counts = [_]u32{0} ** 4;
    var color_values = [_]u32{0} ** 4;
    var num_counted: usize = 0;

    for (colors) |color| {
        var found = false;
        for (0..num_counted) |i| {
            if (color_values[i] == color) {
                color_counts[i] += 1;
                found = true;
                break;
            }
        }
        if (!found and num_counted < 4) {
            color_values[num_counted] = color;
            color_counts[num_counted] = 1;
            num_counted += 1;
        }
    }

    // Find most common color for background
    var max_count: u32 = 0;
    var bg_color: u32 = colors[0];
    for (0..num_counted) |i| {
        if (color_counts[i] > max_count) {
            max_count = color_counts[i];
            bg_color = color_values[i];
        }
    }

    // Find second most common for foreground
    var fg_color: u32 = bg_color;
    max_count = 0;
    for (0..num_counted) |i| {
        if (color_values[i] != bg_color and color_counts[i] > max_count) {
            max_count = color_counts[i];
            fg_color = color_values[i];
        }
    }

    // Create mask based on foreground color
    var mask: u8 = 0;
    for (colors, 0..) |color, i| {
        if (color == fg_color) {
            mask |= @as(u8, 1) << @intCast(i);
        }
    }

    return BlockMapping{
        .ch = QUADRANTS[mask],
        .fg = fg_color,
        .bg = bg_color,
    };
}

/// Convert an array of pixels to block characters for terminal display
/// Each 2x2 pixel region becomes one terminal character
pub fn pixelBufferToBlocks(
    pixels: []const u32,
    pixel_width: u32,
    pixel_height: u32,
    allocator: std.mem.Allocator,
) ![]BlockMapping {
    const block_width = (pixel_width + 1) / 2;
    const block_height = (pixel_height + 1) / 2;
    const blocks = try allocator.alloc(BlockMapping, block_width * block_height);

    for (0..block_height) |by| {
        for (0..block_width) |bx| {
            const px = bx * 2;
            const py = by * 2;

            // Get 2x2 pixel block, handling edge cases
            var pixel_block: [4]u32 = .{0} ** 4;

            // Upper left
            if (py < pixel_height and px < pixel_width) {
                pixel_block[0] = pixels[py * pixel_width + px];
            } else {
                pixel_block[0] = 0x000000FF; // Black with full alpha
            }
            // Upper right
            if (py < pixel_height and px + 1 < pixel_width) {
                pixel_block[1] = pixels[py * pixel_width + px + 1];
            } else {
                pixel_block[1] = 0x000000FF; // Black with full alpha
            }
            // Lower left
            if (py + 1 < pixel_height and px < pixel_width) {
                pixel_block[2] = pixels[(py + 1) * pixel_width + px];
            } else {
                pixel_block[2] = 0x000000FF; // Black with full alpha
            }
            // Lower right
            if (py + 1 < pixel_height and px + 1 < pixel_width) {
                pixel_block[3] = pixels[(py + 1) * pixel_width + px + 1];
            } else {
                pixel_block[3] = 0x000000FF; // Black with full alpha
            }

            blocks[by * block_width + bx] = pixelsToBlock(pixel_block);
        }
    }

    return blocks;
}

test "pixelsToBlock single color" {
    const pixels = [4]u32{ 0xFF0000FF, 0xFF0000FF, 0xFF0000FF, 0xFF0000FF };
    const block = pixelsToBlock(pixels);
    try testing.expect(block.ch == FULL);
    try testing.expect(block.fg == 0xFF0000);
}

test "pixelsToBlock two colors - upper half" {
    const pixels = [4]u32{ 0xFF0000FF, 0xFF0000FF, 0x00FF00FF, 0x00FF00FF };
    const block = pixelsToBlock(pixels);
    std.debug.print("\nTwo colors test: ch='{}' (expected '{}')\n", .{ block.ch, UPPER_HALF });
    std.debug.print("fg=0x{x:0>6}, bg=0x{x:0>6}\n", .{ block.fg, block.bg });
    try testing.expect(block.ch == UPPER_HALF);
}

test "pixelsToBlock quadrant patterns" {
    // Test upper left quadrant
    const ul = [4]u32{ 0xFFFFFFFF, 0x000000FF, 0x000000FF, 0x000000FF };
    const ul_block = pixelsToBlock(ul);
    try testing.expect(ul_block.ch == QUADRANTS[1]); // Upper left

    // Test diagonal
    const diag = [4]u32{ 0xFFFFFFFF, 0x000000FF, 0x000000FF, 0xFFFFFFFF };
    const diag_block = pixelsToBlock(diag);
    try testing.expect(diag_block.ch == QUADRANTS[9]); // Diagonal /
}