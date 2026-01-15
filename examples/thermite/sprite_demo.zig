const std = @import("std");
const lib = @import("thermite");
const Sprite = lib.Sprite;

var should_quit = false;

fn handleSignal(_: c_int) callconv(.c) void {
    should_quit = true;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Set up Ctrl+C handler
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = 0,
        .flags = 0,
    };
    _ = std.posix.sigaction(std.posix.SIG.INT, &act, null);

    // Initialize terminal renderer
    const renderer = try lib.TerminalPixels.init(allocator);
    defer renderer.deinit();

    // Get maximum resolution
    const max_res = renderer.maxResolution();
    std.debug.print("Terminal pixel resolution: {}x{}\n", .{ max_res.width, max_res.height });
    std.debug.print("Sprite Demo - Press Ctrl+C to exit\n", .{});
    
    // Clear the terminal first
    renderer.clear();
    try renderer.presentOptimized();

    // Create a framebuffer
    const width = max_res.width;
    const height = max_res.height;
    const framebuffer = try Sprite.initEmpty(allocator, width, height);
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
    
    // Draw a yellow star
    star.drawRect(5, 0, 2, 12, 0xFFFF00FF);  // Vertical
    star.drawRect(0, 5, 12, 2, 0xFFFF00FF);  // Horizontal
    star.drawRect(2, 2, 8, 8, 0xFFFF00FF);   // Center

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

    // Main animation loop
    while (!should_quit) : (frame += 1) {
        // Clear framebuffer with dark blue background
        framebuffer.fill(0x000040FF);

        // Draw a gradient background
        for (0..height) |y| {
            const intensity = @as(u8, @intFromFloat(@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height)) * 80));
            const color = (@as(u32, intensity) << 16) | (@as(u32, intensity / 2) << 8) | 0xFF;
            framebuffer.drawRect(0, @intCast(y), width, 1, color);
        }

        // Update and draw smiley
        smiley_x += smiley_vx;
        smiley_y += smiley_vy;
        
        if (smiley_x <= 0 or smiley_x >= @as(f32, @floatFromInt(width - smiley.width))) {
            smiley_vx = -smiley_vx;
        }
        if (smiley_y <= 0 or smiley_y >= @as(f32, @floatFromInt(height - smiley.height))) {
            smiley_vy = -smiley_vy;
        }
        
        framebuffer.blit(smiley, @intFromFloat(smiley_x), @intFromFloat(smiley_y));

        // Update and draw ball
        ball_x += ball_vx;
        ball_y += ball_vy;
        ball_vy += 0.2; // Gravity
        
        if (ball_x <= 0 or ball_x >= @as(f32, @floatFromInt(width - ball.width))) {
            ball_vx = -ball_vx * 0.9; // Some energy loss
        }
        if (ball_y >= @as(f32, @floatFromInt(height - ball.height))) {
            ball_y = @as(f32, @floatFromInt(height - ball.height));
            ball_vy = -ball_vy * 0.8; // Bounce with energy loss
        }
        
        framebuffer.blit(ball, @intFromFloat(ball_x), @intFromFloat(ball_y));

        // Update and draw rotating star
        star_angle += 0.05;
        star_x = @as(f32, @floatFromInt(width / 2)) + @cos(star_angle) * @as(f32, @floatFromInt(width / 3));
        star_y = @as(f32, @floatFromInt(height / 2)) + @sin(star_angle) * @as(f32, @floatFromInt(height / 3));
        
        framebuffer.blit(star, @intFromFloat(star_x), @intFromFloat(star_y));

        // Draw some particle effects
        const time = @as(f32, @floatFromInt(frame)) * 0.1;
        for (0..20) |i| {
            const particle_x = @as(u32, @intFromFloat(@as(f32, @floatFromInt(width / 2)) + @sin(time + @as(f32, @floatFromInt(i))) * 50));
            const particle_y = @as(u32, @intFromFloat(@as(f32, @floatFromInt(height / 2)) + @cos(time * 1.3 + @as(f32, @floatFromInt(i))) * 30));
            if (particle_x < width and particle_y < height) {
                framebuffer.setPixel(particle_x, particle_y, 0xFFFFFFFF);
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