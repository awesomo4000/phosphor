const std = @import("std");
const NotcursesFastRenderer = @import("notcurses_fast.zig").NotcursesFastRenderer;

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
    
    std.debug.print("Testing yellow box rendering - {}x{} cells\n", .{ term_width, term_height });
    std.Thread.sleep(2 * std.time.ns_per_s);
    
    const renderer = try NotcursesFastRenderer.init(allocator, term_width, term_height, tty_fd);
    defer renderer.deinit();
    
    // Pixel buffer - 2x2 pixels per cell
    const width = term_width * 2;
    const height = term_height * 2;
    const pixels = try allocator.alloc(u32, width * height);
    defer allocator.free(pixels);
    
    // Clear screen
    _ = try std.posix.write(tty_fd, "\x1b[2J\x1b[H\x1b[?25l");
    
    // Test 1: Solid yellow fill
    std.debug.print("\nTest 1: Solid yellow - should be uniform\n", .{});
    @memset(pixels, 0xFFFF00FF); // Yellow
    renderer.setPixels(pixels, width, height);
    try renderer.render();
    std.Thread.sleep(3 * std.time.ns_per_s);
    
    // Test 2: Alternating rows
    std.debug.print("\nTest 2: Alternating yellow/black rows\n", .{});
    for (0..height) |y| {
        const color: u32 = if (y % 2 == 0) 0xFFFF00FF else 0x000000FF; // Yellow or Black
        for (0..width) |x| {
            pixels[y * width + x] = color;
        }
    }
    renderer.setPixels(pixels, width, height);
    try renderer.render();
    std.Thread.sleep(3 * std.time.ns_per_s);
    
    // Test 3: Solid block in gradient
    std.debug.print("\nTest 3: Yellow box on gradient background\n", .{});
    // Gradient background
    for (0..height) |y| {
        for (0..width) |x| {
            const g = @as(u8, @intCast((y * 255) / height));
            pixels[y * width + x] = (@as(u32, 0) << 24) | (@as(u32, g) << 16) | (@as(u32, 0) << 8) | 0xFF;
        }
    }
    // Yellow box
    const box_x: u32 = 20;
    const box_y: u32 = 10;
    for (box_y..@min(box_y + 20, height)) |y| {
        for (box_x..@min(box_x + 40, width)) |x| {
            pixels[y * width + x] = 0xFFFF00FF; // Yellow
        }
    }
    renderer.setPixels(pixels, width, height);
    try renderer.render();
    std.Thread.sleep(3 * std.time.ns_per_s);
    
    // Clear before exit
    _ = try std.posix.write(tty_fd, "\x1b[2J\x1b[H\x1b[?25h\x1b[0m");
    std.debug.print("Done!\n", .{});
}