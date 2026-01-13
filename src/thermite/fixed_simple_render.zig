const std = @import("std");

// Fixed simple renderer without screen clearing
pub fn fixedSimpleRender(allocator: std.mem.Allocator, ttyfd: i32, pixels: []const u32, width: u32, height: u32, clear_screen: bool) !void {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    const writer = buffer.writer(allocator);
    
    // Get actual terminal size
    var winsize: std.posix.winsize = undefined;
    const TIOCGWINSZ = if (@import("builtin").os.tag == .macos) @as(c_ulong, 0x40087468) else std.os.linux.T.IOCGWINSZ;
    _ = std.c.ioctl(ttyfd, TIOCGWINSZ, @intFromPtr(&winsize));
    
    const actual_term_width = winsize.col;
    const actual_term_height = winsize.row;
    
    // Only clear on first frame or when requested
    if (clear_screen) {
        try writer.writeAll("\x1b[2J");
    }
    
    // Always home cursor
    try writer.writeAll("\x1b[H");
    
    // Each character cell represents 2x2 pixels
    const pixel_width = width;
    const pixel_height = height;
    
    var last_color: u32 = 0xFFFFFFFF;
    
    // Render exactly the terminal size
    for (0..actual_term_height) |ty| {
        // For each row after the first, we need to either:
        // 1. Move down with newline
        // 2. Or position cursor absolutely
        if (ty > 0) {
            // Use absolute positioning to ensure we're at the right place
            try writer.print("\x1b[{};1H", .{ty + 1});
        }
        
        for (0..actual_term_width) |tx| {
            // Map terminal position to pixel position
            const px = tx * 2;
            const py = ty * 2;
            
            var r_sum: u32 = 0;
            var g_sum: u32 = 0;
            var b_sum: u32 = 0;
            var count: u32 = 0;
            
            // Sample all 4 pixels in the 2x2 block
            if (py < pixel_height and px < pixel_width) {
                const p = pixels[py * pixel_width + px] >> 8;
                r_sum += (p >> 16) & 0xFF;
                g_sum += (p >> 8) & 0xFF;
                b_sum += p & 0xFF;
                count += 1;
            }
            if (py < pixel_height and px + 1 < pixel_width) {
                const p = pixels[py * pixel_width + px + 1] >> 8;
                r_sum += (p >> 16) & 0xFF;
                g_sum += (p >> 8) & 0xFF;
                b_sum += p & 0xFF;
                count += 1;
            }
            if (py + 1 < pixel_height and px < pixel_width) {
                const p = pixels[(py + 1) * pixel_width + px] >> 8;
                r_sum += (p >> 16) & 0xFF;
                g_sum += (p >> 8) & 0xFF;
                b_sum += p & 0xFF;
                count += 1;
            }
            if (py + 1 < pixel_height and px + 1 < pixel_width) {
                const p = pixels[(py + 1) * pixel_width + px + 1] >> 8;
                r_sum += (p >> 16) & 0xFF;
                g_sum += (p >> 8) & 0xFF;
                b_sum += p & 0xFF;
                count += 1;
            }
            
            const r: u8 = if (count > 0) @intCast(r_sum / count) else 0;
            const g: u8 = if (count > 0) @intCast(g_sum / count) else 0;
            const b: u8 = if (count > 0) @intCast(b_sum / count) else 0;
            const rgb = (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
            
            if (rgb != last_color) {
                try writer.print("\x1b[48;2;{};{};{}m", .{ r, g, b });
                last_color = rgb;
            }
            
            try writer.writeByte(' ');
        }
    }
    
    // Reset at end
    try writer.writeAll("\x1b[0m");
    
    // Single write
    _ = try std.posix.write(ttyfd, buffer.items);
}