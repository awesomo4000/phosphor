const std = @import("std");

// Simplified fast render that just fills screen with spaces and background colors
pub fn simpleRender(allocator: std.mem.Allocator, ttyfd: i32, pixels: []const u32, width: u32, height: u32) !void {
    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(allocator);
    
    const writer = buffer.writer();
    
    // Get actual terminal size
    var winsize: std.posix.winsize = undefined;
    const TIOCGWINSZ = if (@import("builtin").os.tag == .macos) @as(c_ulong, 0x40087468) else std.os.linux.T.IOCGWINSZ;
    _ = std.c.ioctl(ttyfd, TIOCGWINSZ, @intFromPtr(&winsize));
    
    const actual_term_width = winsize.col;
    const actual_term_height = winsize.row;
    
    // Clear and home
    try writer.writeAll("\x1b[2J\x1b[H");
    
    // Each character cell represents 2x2 pixels
    // Use the full terminal size, not limited by pixel dimensions
    const term_width = actual_term_width;
    const term_height = actual_term_height;
    
    var last_color: u32 = 0xFFFFFFFF;
    
    for (0..term_height) |ty| {
        if (ty > 0) try writer.writeByte('\n');
        
        for (0..term_width) |tx| {
            // Average the 2x2 pixel block
            const px = tx * 2;
            const py = ty * 2;
            
            var r_sum: u32 = 0;
            var g_sum: u32 = 0;
            var b_sum: u32 = 0;
            var count: u32 = 0;
            
            // Sample all 4 pixels in the 2x2 block
            if (py < height and px < width) {
                const p = pixels[py * width + px] >> 8;
                r_sum += (p >> 16) & 0xFF;
                g_sum += (p >> 8) & 0xFF;
                b_sum += p & 0xFF;
                count += 1;
            }
            if (py < height and px + 1 < width) {
                const p = pixels[py * width + px + 1] >> 8;
                r_sum += (p >> 16) & 0xFF;
                g_sum += (p >> 8) & 0xFF;
                b_sum += p & 0xFF;
                count += 1;
            }
            if (py + 1 < height and px < width) {
                const p = pixels[(py + 1) * width + px] >> 8;
                r_sum += (p >> 16) & 0xFF;
                g_sum += (p >> 8) & 0xFF;
                b_sum += p & 0xFF;
                count += 1;
            }
            if (py + 1 < height and px + 1 < width) {
                const p = pixels[(py + 1) * width + px + 1] >> 8;
                r_sum += (p >> 16) & 0xFF;
                g_sum += (p >> 8) & 0xFF;
                b_sum += p & 0xFF;
                count += 1;
            }
            
            if (count > 0) {
                // Average the colors
                const r = @as(u8, @intCast(r_sum / count));
                const g = @as(u8, @intCast(g_sum / count));
                const b = @as(u8, @intCast(b_sum / count));
                const rgb = (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
                
                if (rgb != last_color) {
                    try writer.print("\x1b[48;2;{};{};{}m", .{ r, g, b });
                    last_color = rgb;
                }
            } else {
                // No pixels to sample - use black
                if (last_color != 0) {
                    try writer.writeAll("\x1b[48;2;0;0;0m");
                    last_color = 0;
                }
            }
            
            try writer.writeByte(' ');
        }
    }
    
    // Single write
    _ = try std.posix.write(ttyfd, buffer.items);
}