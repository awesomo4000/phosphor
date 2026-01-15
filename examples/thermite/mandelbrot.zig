const std = @import("std");
const lib = @import("thermite");

// Mandelbrot calculation
fn mandelbrot(c_real: f64, c_imag: f64, max_iter: u32) u32 {
    var z_real: f64 = 0;
    var z_imag: f64 = 0;
    var iter: u32 = 0;
    
    while (iter < max_iter) : (iter += 1) {
        const z_real_sq = z_real * z_real;
        const z_imag_sq = z_imag * z_imag;
        
        if (z_real_sq + z_imag_sq > 4.0) {
            break;
        }
        
        const new_real = z_real_sq - z_imag_sq + c_real;
        const new_imag = 2.0 * z_real * z_imag + c_imag;
        
        z_real = new_real;
        z_imag = new_imag;
    }
    
    return iter;
}

// Color palette for the fractal
fn iterToColor(iter: u32, max_iter: u32) u32 {
    if (iter == max_iter) {
        // Inside the set - black
        return 0x000000FF;
    }
    
    // Create a smooth gradient
    const t = @as(f32, @floatFromInt(iter)) / @as(f32, @floatFromInt(max_iter));
    const angle = t * std.math.pi * 4.0; // Multiple cycles for more color variation
    
    // Use sine waves offset by 120 degrees for RGB
    const r = @as(u8, @intFromFloat((@sin(angle) + 1.0) * 127.5));
    const g = @as(u8, @intFromFloat((@sin(angle + 2.0 * std.math.pi / 3.0) + 1.0) * 127.5));
    const b = @as(u8, @intFromFloat((@sin(angle + 4.0 * std.math.pi / 3.0) + 1.0) * 127.5));
    
    return (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
}

// Interesting zoom targets in the Mandelbrot set
const ZoomTarget = struct {
    center_real: f64,
    center_imag: f64,
    description: []const u8,
};

const zoom_targets = [_]ZoomTarget{
    .{ .center_real = -0.7436447860, .center_imag = 0.1318252536, .description = "Spiral" },
    .{ .center_real = -0.7453, .center_imag = 0.1127, .description = "Mini Mandelbrot" },
    .{ .center_real = -0.74529, .center_imag = 0.11307, .description = "Deep spiral" },
    .{ .center_real = -0.1607839, .center_imag = 1.0407268, .description = "Top spiral" },
    .{ .center_real = -1.25066, .center_imag = 0.02012, .description = "Seahorse valley" },
    .{ .center_real = -0.748, .center_imag = 0.1, .description = "Double spiral" },
    .{ .center_real = 0.360240443437, .center_imag = -0.641313061064, .description = "Valley spiral" },
    .{ .center_real = -1.99999911758738, .center_imag = 0.0, .description = "Needle" },
};

var should_quit = false;
var is_paused = false;

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
    std.debug.print("Mandelbrot Fractal Zoomer - Press Ctrl+C to exit, Space to pause/resume\n", .{});
    
    // Clear the terminal first
    renderer.clear();
    try renderer.present();

    // Use full terminal resolution
    const width: u32 = max_res.width;
    const height: u32 = max_res.height;
    const pixels = try allocator.alloc(u32, width * height);
    defer allocator.free(pixels);

    // Animation parameters
    var frame: u32 = 0;
    var zoom: f64 = 3.0;
    const zoom_speed: f64 = 0.95; // Zoom in by 5% each frame (faster zoom)
    var target_index: usize = 0;
    var current_target = zoom_targets[target_index];
    
    // Maximum iterations (start lower for faster initial rendering)
    var max_iter: u32 = 32;
    
    // Get terminal file descriptor for keyboard input
    const term_fd = renderer.getTerminalFd();

    // Main animation loop
    while (!should_quit) : (frame += 1) {
        // Check for keyboard input
        if (lib.terminal.readKey(term_fd)) |key| {
            if (key == ' ') {
                is_paused = !is_paused;
            }
        }
        
        // Skip processing if paused
        if (is_paused) {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        }
        // Calculate bounds
        const aspect_ratio = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(height));
        const real_min = current_target.center_real - zoom * aspect_ratio * 0.5;
        const real_max = current_target.center_real + zoom * aspect_ratio * 0.5;
        const imag_min = current_target.center_imag - zoom * 0.5;
        const imag_max = current_target.center_imag + zoom * 0.5;

        // Render the fractal and count black pixels
        var black_pixel_count: u32 = 0;
        for (0..height) |y| {
            for (0..width) |x| {
                const real = real_min + (@as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(width - 1))) * (real_max - real_min);
                const imag = imag_min + (@as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(height - 1))) * (imag_max - imag_min);
                
                const iter = mandelbrot(real, imag, max_iter);
                const color = iterToColor(iter, max_iter);
                pixels[y * width + x] = color;
                
                // Count black pixels (inside the set)
                if (iter == max_iter) {
                    black_pixel_count += 1;
                }
            }
        }

        // Display the fractal using optimized rendering
        try renderer.setPixels(pixels, width, height);
        try renderer.presentOptimized();

        // Check if screen is mostly black (boring)
        const total_pixels = width * height;
        const black_percentage = @as(f32, @floatFromInt(black_pixel_count)) / @as(f32, @floatFromInt(total_pixels));
        
        // If more than 80% of the screen is black, move to next target
        if (black_percentage > 0.8) {
            target_index = (target_index + 1) % zoom_targets.len;
            current_target = zoom_targets[target_index];
            zoom = 3.0;
            max_iter = 32;
            
            // Clear the screen to avoid artifacts
            renderer.clear();
            try renderer.present();
            
            // Silently switch without printing
            
            // Small delay to ensure clean transition
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        }

        // Update zoom
        zoom *= zoom_speed;
        
        // Increase detail as we zoom in (more aggressive scaling)
        if (frame % 20 == 0 and max_iter < 256) {
            max_iter += 8;
        }

        // When zoomed in too far, switch to next target
        if (zoom < 0.0001) {
            target_index = (target_index + 1) % zoom_targets.len;
            current_target = zoom_targets[target_index];
            zoom = 3.0;
            max_iter = 32;
            
            // Clear the screen to avoid artifacts
            renderer.clear();
            try renderer.present();
            
            // Silently switch without printing
            
            // Small delay to ensure clean transition
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }

        // ~200 FPS (5ms delay)
        std.Thread.sleep(5 * std.time.ns_per_ms);

        // Exit after exploring all targets twice
        if (frame >= zoom_targets.len * 2 * 500) break;
        
        // Check if we should quit
        if (should_quit) {
            break;
        }
    }

    // Clear screen before exit
    renderer.clear();
    try renderer.present();
}