const std = @import("std");
const lib = @import("termpixels_lib");
const NotcursesBlockRenderer = @import("notcurses_blocks.zig").NotcursesBlockRenderer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const tty_fd = try std.posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0);
    defer std.posix.close(tty_fd);
    
    var winsize: std.posix.winsize = undefined;
    const TIOCGWINSZ = if (@import("builtin").os.tag == .macos) @as(c_ulong, 0x40087468) else std.os.linux.T.IOCGWINSZ;
    _ = std.c.ioctl(tty_fd, TIOCGWINSZ, @intFromPtr(&winsize));
    
    const term_width = winsize.col;
    const term_height = winsize.row - 1;
    
    std.debug.print("Unicode Block Renderer Test - {}x{}\n", .{ term_width, term_height });
    std.debug.print("This should show clean edges on the yellow box!\n", .{});
    std.Thread.sleep(2 * std.time.ns_per_s);
    
    // Create block-based renderer
    const renderer = try NotcursesBlockRenderer.init(allocator, term_width, term_height, tty_fd);
    defer renderer.deinit();
    
    // Pixel dimensions
    const width = term_width * 2;
    const height = term_height * 2;
    const pixels = try allocator.alloc(u32, width * height);
    defer allocator.free(pixels);
    
    _ = try std.posix.write(tty_fd, "\x1b[2J\x1b[H\x1b[?25l");
    
    var frame: u32 = 0;
    var last_fps_time = std.time.nanoTimestamp();
    var fps: f32 = 0;
    
    while (frame < 1000) : (frame += 1) {
        // Background gradient
        for (0..height) |y| {
            for (0..width) |x| {
                const r = @as(u8, @intCast((x + frame / 10) % 256));
                const g = @as(u8, @intCast((y + frame / 10) % 256));
                const b = @as(u8, 64);
                pixels[y * width + x] = (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
            }
        }
        
        // Moving yellow box
        const box_x = @as(u32, @intCast((frame * 2) % (width - 40)));
        const box_y = @as(u32, @intCast(frame % (height - 20)));
        
        for (box_y..@min(box_y + 20, height)) |y| {
            for (box_x..@min(box_x + 40, width)) |x| {
                pixels[y * width + x] = 0xFFFF00FF; // Yellow
            }
        }
        
        // Render using block characters
        renderer.setPixels(pixels, width, height);
        try renderer.render();
        
        // Show FPS
        const info = try std.fmt.allocPrint(allocator, "\x1b[{};1H\x1b[48;2;0;0;0m\x1b[38;2;255;255;255mBlock Renderer - FPS: {d:.1}   \x1b[K", .{ winsize.row, fps });
        defer allocator.free(info);
        _ = try std.posix.write(tty_fd, info);
        
        // Calculate FPS
        if (frame % 30 == 0) {
            const now = std.time.nanoTimestamp();
            const elapsed = @as(f32, @floatFromInt(now - last_fps_time)) / 1_000_000_000.0;
            fps = 30.0 / elapsed;
            last_fps_time = now;
        }
        
        std.Thread.yield() catch {};
    }
    
    // Clear before exit
    _ = try std.posix.write(tty_fd, "\x1b[2J\x1b[H\x1b[?25h\x1b[0m");
}