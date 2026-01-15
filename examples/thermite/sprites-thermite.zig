const std = @import("std");
const lib = @import("thermite");
const terminal = lib.terminal;
const Sprite = lib.Sprite;

/// Draw status bar at bottom of screen
fn drawStatusBar(fd: i32, term_height: u32, term_width: u32, fps: u32, frame: u32) void {
    if (term_width < 20 or term_height < 5) return;

    var buf: [256]u8 = undefined;

    // Move to bottom row, set white on black
    const prefix = std.fmt.bufPrint(&buf, "\x1b[{};1H\x1b[0m\x1b[97;40m", .{term_height}) catch return;
    _ = std.posix.write(fd, prefix) catch {};

    // Build status text
    var status_buf: [200]u8 = undefined;
    const status = if (term_width >= 60)
        std.fmt.bufPrint(&status_buf, " Sprite Demo | FPS:{d:>3} | Frame:{d:>6} | [Q]=quit ", .{ fps, frame }) catch return
    else
        std.fmt.bufPrint(&status_buf, " FPS:{d:>3} [Q]=quit ", .{fps}) catch return;

    const write_len = @min(status.len, term_width);
    _ = std.posix.write(fd, status[0..write_len]) catch {};

    // Fill rest of line with spaces
    if (term_width > write_len) {
        var spaces: [200]u8 = undefined;
        const fill_len = @min(term_width - @as(u32, @intCast(write_len)), 200);
        @memset(spaces[0..fill_len], ' ');
        _ = std.posix.write(fd, spaces[0..fill_len]) catch {};
    }

    // Reset colors
    _ = std.posix.write(fd, "\x1b[0m") catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize terminal renderer
    const renderer = try lib.Renderer.init(allocator);
    defer renderer.deinit();

    const term_fd = renderer.getTerminalFd();

    // Install signal handlers for clean Ctrl+C exit and resize
    terminal.installSignalHandlers(term_fd);

    // Get maximum resolution (reserve bottom row for status bar)
    const max_res = renderer.maxResolution();
    var term_width: u32 = max_res.width / 2;
    var term_height: u32 = max_res.height / 2;
    var width: u32 = max_res.width;
    var height: u32 = max_res.height - 2; // Leave 1 row (2 pixels) for status
    var framebuffer = try Sprite.initEmpty(allocator, width, height);
    defer framebuffer.deinit();

    // Create a smiley sprite
    const smiley = try Sprite.initEmpty(allocator, 16, 16);
    defer smiley.deinit();
    
    // Yellow background
    smiley.fill(0xFFFF00FF);
    
    // Eyes (black)
    smiley.drawRect(4, 4, 2, 2, 0x000000FF);
    smiley.drawRect(10, 4, 2, 2, 0x000000FF);
    
    // Mouth (black arc - simplified as pixels)
    for (4..12) |x| {
        const y = 10 + @abs(@as(i32, @intCast(x)) - 7) / 2;
        smiley.setPixel(@intCast(x), @intCast(y), 0x000000FF);
    }

    // Create a ball sprite
    const ball = try Sprite.initEmpty(allocator, 8, 8);
    defer ball.deinit();
    
    // Draw a red ball
    for (0..8) |y| {
        for (0..8) |x| {
            const dx = @as(f32, @floatFromInt(x)) - 3.5;
            const dy = @as(f32, @floatFromInt(y)) - 3.5;
            if (dx * dx + dy * dy <= 3.5 * 3.5) {
                ball.setPixel(@intCast(x), @intCast(y), 0xFF0000FF);
            }
        }
    }

    // Create a star sprite
    const star = try Sprite.initEmpty(allocator, 12, 12);
    defer star.deinit();
    
    // Draw a purple star
    star.drawRect(5, 0, 2, 12, 0xAA00FFFF);  // Vertical
    star.drawRect(0, 5, 12, 2, 0xAA00FFFF);  // Horizontal
    star.drawRect(2, 2, 8, 8, 0xAA00FFFF);   // Center

    // Animation variables
    var frame: u32 = 0;
    var smiley_x: f32 = 10;
    var smiley_y: f32 = 10;
    var smiley_vx: f32 = 2.5;
    var smiley_vy: f32 = 1.8;

    var ball_x: f32 = @as(f32, @floatFromInt(width - 20));
    var ball_y: f32 = 20;
    var ball_vx: f32 = -3.2;
    var ball_vy: f32 = 2.1;

    var star_x: f32 = @as(f32, @floatFromInt(width / 2));
    var star_y: f32 = @as(f32, @floatFromInt(height / 2));
    var star_angle: f32 = 0;

    // FPS tracking
    var fps: u32 = 0;
    var fps_frame_count: u32 = 0;
    var fps_last_time = std.time.milliTimestamp();

    // Initial clear
    renderer.clear();
    try renderer.present();

    // Main animation loop
    while (true) {
        // Check for keyboard input (non-blocking)
        if (terminal.readKey(term_fd)) |key| {
            if (key == 'q' or key == 3) break; // q or Ctrl+C
        }

        // Check for terminal resize
        if (renderer.checkResize()) |new_res| {
            // Reallocate framebuffer
            framebuffer.deinit();
            width = new_res.width;
            height = new_res.height - 2;
            term_width = new_res.width / 2;
            term_height = new_res.height / 2;
            framebuffer = try Sprite.initEmpty(allocator, width, height);
            renderer.clear();
            try renderer.present();
        }

        // Update FPS counter
        const now = std.time.milliTimestamp();
        if (now - fps_last_time >= 1000) {
            fps = fps_frame_count;
            fps_frame_count = 0;
            fps_last_time = now;
        }

        // Update status bar every 4 frames (~15 Hz at 60fps)
        if (frame % 4 == 0) {
            drawStatusBar(term_fd, term_height, term_width, fps, frame);
        }

        // Count this frame
        frame += 1;
        fps_frame_count += 1;

        // Clear framebuffer with dark blue background
        framebuffer.fill(0x000040FF);

        // Draw a gradient background
        for (0..height) |y| {
            const intensity = @as(u8, @intFromFloat(@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height)) * 80));
            const color = (@as(u32, intensity) << 16) | (@as(u32, intensity / 2) << 8) | 0xFF;
            framebuffer.drawRect(0, @intCast(y), width, 1, color);
        }

        // Update and draw smiley (skip if terminal too small)
        if (width > smiley.width and height > smiley.height) {
            smiley_x += smiley_vx;
            smiley_y += smiley_vy;

            const max_x = @as(f32, @floatFromInt(width - smiley.width));
            const max_y = @as(f32, @floatFromInt(height - smiley.height));

            if (smiley_x <= 0) {
                smiley_x = 0;
                smiley_vx = -smiley_vx;
            } else if (smiley_x >= max_x) {
                smiley_x = max_x;
                smiley_vx = -smiley_vx;
            }
            if (smiley_y <= 0) {
                smiley_y = 0;
                smiley_vy = -smiley_vy;
            } else if (smiley_y >= max_y) {
                smiley_y = max_y;
                smiley_vy = -smiley_vy;
            }

            framebuffer.blit(smiley, @intFromFloat(smiley_x), @intFromFloat(smiley_y));
        }

        // Update and draw ball (skip if terminal too small)
        if (width > ball.width and height > ball.height) {
            const max_x = @as(f32, @floatFromInt(width - ball.width));
            const max_y = @as(f32, @floatFromInt(height - ball.height));

            ball_x += ball_vx;
            ball_y += ball_vy;
            ball_vy += 0.2; // Gravity

            // Horizontal bounce
            if (ball_x <= 0) {
                ball_x = 0;
                ball_vx = -ball_vx * 0.9;
            } else if (ball_x >= max_x) {
                ball_x = max_x;
                ball_vx = -ball_vx * 0.9;
            }

            // Vertical bounce - stop if velocity very low
            if (ball_y >= max_y) {
                ball_y = max_y;
                if (@abs(ball_vy) < 1.0) {
                    ball_vy = 0;
                    // Friction when resting
                    ball_vx *= 0.98;
                    if (@abs(ball_vx) < 0.1) ball_vx = 0;
                } else {
                    ball_vy = -ball_vy * 0.8;
                }
            }

            framebuffer.blit(ball, @intFromFloat(ball_x), @intFromFloat(ball_y));
        }

        // Update and draw rotating star (clamp to bounds)
        star_angle += 0.05;
        star_x = @as(f32, @floatFromInt(width / 2)) + @cos(star_angle) * @as(f32, @floatFromInt(width / 3));
        star_y = @as(f32, @floatFromInt(height / 2)) + @sin(star_angle) * @as(f32, @floatFromInt(height / 3));

        if (star_x >= 0 and star_y >= 0) {
            const sx = @as(u32, @intFromFloat(star_x));
            const sy = @as(u32, @intFromFloat(star_y));
            if (sx + star.width <= width and sy + star.height <= height) {
                framebuffer.blit(star, @intCast(sx), @intCast(sy));
            }
        }

        // Draw some particle effects (skip if terminal too small)
        if (width > 100 and height > 60) {
            const time = @as(f32, @floatFromInt(frame)) * 0.1;
            for (0..20) |i| {
                const px = @as(f32, @floatFromInt(width / 2)) + @sin(time + @as(f32, @floatFromInt(i))) * 50;
                const py = @as(f32, @floatFromInt(height / 2)) + @cos(time * 1.3 + @as(f32, @floatFromInt(i))) * 30;
                if (px >= 0 and py >= 0) {
                    const particle_x = @as(u32, @intFromFloat(px));
                    const particle_y = @as(u32, @intFromFloat(py));
                    if (particle_x < width and particle_y < height) {
                        framebuffer.setPixel(particle_x, particle_y, 0xFFFFFFFF);
                    }
                }
            }
        }

        // Render framebuffer to terminal
        try renderer.setPixels(framebuffer.pixels, width, height);
        try renderer.presentOptimized();

        // ~60 FPS
        std.Thread.sleep(16 * std.time.ns_per_ms);
    }

    // Clear screen before exit
    renderer.clear();
    try renderer.presentOptimized();
}