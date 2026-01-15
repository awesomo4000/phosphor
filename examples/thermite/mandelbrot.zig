const std = @import("std");
const lib = @import("thermite");
const terminal = lib.terminal;

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
        return 0x000000FF; // Black for inside the set
    }

    const t = @as(f32, @floatFromInt(iter)) / @as(f32, @floatFromInt(max_iter));
    const angle = t * std.math.pi * 4.0;

    const r = @as(u8, @intFromFloat((@sin(angle) + 1.0) * 127.5));
    const g = @as(u8, @intFromFloat((@sin(angle + 2.0 * std.math.pi / 3.0) + 1.0) * 127.5));
    const b = @as(u8, @intFromFloat((@sin(angle + 4.0 * std.math.pi / 3.0) + 1.0) * 127.5));

    return (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
}

// Zoom targets
const ZoomTarget = struct {
    center_real: f64,
    center_imag: f64,
    name: []const u8,
};

const zoom_targets = [_]ZoomTarget{
    .{ .center_real = -0.7436447860, .center_imag = 0.1318252536, .name = "Spiral" },
    .{ .center_real = -0.7453, .center_imag = 0.1127, .name = "Mini Mandelbrot" },
    .{ .center_real = -0.74529, .center_imag = 0.11307, .name = "Deep spiral" },
    .{ .center_real = -0.1607839, .center_imag = 1.0407268, .name = "Top spiral" },
    .{ .center_real = -1.25066, .center_imag = 0.02012, .name = "Seahorse valley" },
    .{ .center_real = -0.748, .center_imag = 0.1, .name = "Double spiral" },
    .{ .center_real = 0.360240443437, .center_imag = -0.641313061064, .name = "Valley spiral" },
    .{ .center_real = -1.99999911758738, .center_imag = 0.0, .name = "Needle" },
};

/// Draw status bar at bottom of screen
fn drawStatusBar(fd: i32, term_height: u32, term_width: u32, fps: u32, is_paused: bool, target_name: []const u8, zoom: f64) void {
    // Skip if terminal too small
    if (term_width < 20 or term_height < 5) return;

    var buf: [256]u8 = undefined;

    // Move to bottom row, set white on black
    const prefix = std.fmt.bufPrint(&buf, "\x1b[{};1H\x1b[0m\x1b[97;40m", .{term_height}) catch return;
    _ = std.posix.write(fd, prefix) catch {};

    // Build status text - use shorter format for narrow terminals
    // Fixed widths: FPS=3 digits, Zoom=9 chars (e.g. "1.23e-04")
    var status_buf: [200]u8 = undefined;
    const status = if (term_width >= 80)
        std.fmt.bufPrint(&status_buf, " {s: <7} | FPS:{d:>3} | {s: <16} | Zoom:{e:>9.2} | [SPC]=pause [Q]=quit ", .{
            if (is_paused) "PAUSED" else "RUNNING", fps, target_name, zoom,
        }) catch return
    else if (term_width >= 50)
        std.fmt.bufPrint(&status_buf, " {s: <5} FPS:{d:>3} {s} ", .{
            if (is_paused) "PAUSE" else "RUN", fps, target_name,
        }) catch return
    else
        std.fmt.bufPrint(&status_buf, " {s} {d:>3}", .{
            if (is_paused) "P" else "R", fps,
        }) catch return;

    // Truncate to terminal width and write
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

    // Initialize renderer
    const renderer = try lib.Renderer.init(allocator);
    defer renderer.deinit();

    // Install signal handlers for clean Ctrl+C exit
    terminal.installSignalHandlers(renderer.getTerminalFd());

    // Get resolution (reserve bottom row for status bar)
    const max_res = renderer.maxResolution();
    var term_width: u32 = max_res.width / 2; // Terminal chars
    var term_height: u32 = max_res.height / 2;
    var width: u32 = max_res.width;
    var height: u32 = max_res.height - 2; // Leave 1 row (2 pixels) for status

    var pixels = try allocator.alloc(u32, width * height);
    defer allocator.free(pixels);

    // Animation state
    var frame: u32 = 0;
    var zoom: f64 = 3.0;
    const zoom_speed: f64 = 0.95;
    var target_index: usize = 0;
    var current_target = zoom_targets[target_index];
    var max_iter: u32 = 32;
    var is_paused = false;

    // FPS tracking
    var fps: u32 = 0;
    var fps_frame_count: u32 = 0;
    var fps_last_time = std.time.milliTimestamp();


    const term_fd = renderer.getTerminalFd();

    // Initial clear
    renderer.clear();
    try renderer.present();

    // Main loop
    while (true) {
        // Check for keyboard input (non-blocking)
        if (terminal.readKey(term_fd)) |key| {
            if (key == 'q' or key == 3) break; // q or Ctrl+C
            if (key == ' ') is_paused = !is_paused;
        }

        // Check for terminal resize
        if (renderer.checkResize()) |new_res| {
            allocator.free(pixels);
            width = new_res.width;
            height = new_res.height - 2; // Leave room for status bar
            term_width = new_res.width / 2;
            term_height = new_res.height / 2;
            pixels = try allocator.alloc(u32, width * height);
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

        // If paused, update status bar (20Hz due to 50ms sleep) and continue
        if (is_paused) {
            drawStatusBar(term_fd, term_height, term_width, fps, is_paused, current_target.name, zoom);
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        }

        // Update status bar every 7 frames (~10 Hz at 70fps)
        if (frame % 7 == 0) {
            drawStatusBar(term_fd, term_height, term_width, fps, is_paused, current_target.name, zoom);
        }

        // Count this frame
        frame += 1;
        fps_frame_count += 1;

        // Calculate fractal bounds
        const aspect_ratio = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(height));
        const real_min = current_target.center_real - zoom * aspect_ratio * 0.5;
        const real_max = current_target.center_real + zoom * aspect_ratio * 0.5;
        const imag_min = current_target.center_imag - zoom * 0.5;
        const imag_max = current_target.center_imag + zoom * 0.5;

        // Render fractal
        var black_count: u32 = 0;
        for (0..height) |y| {
            for (0..width) |x| {
                const real = real_min + (@as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(width - 1))) * (real_max - real_min);
                const imag = imag_min + (@as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(height - 1))) * (imag_max - imag_min);

                const iter = mandelbrot(real, imag, max_iter);
                const color = iterToColor(iter, max_iter);
                pixels[y * width + x] = color;

                if (iter == max_iter) black_count += 1;
            }
        }

        // Display
        try renderer.setPixels(pixels, width, height);
        try renderer.presentOptimized();

        // Auto-advance if mostly black
        const black_pct = @as(f32, @floatFromInt(black_count)) / @as(f32, @floatFromInt(width * height));
        if (black_pct > 0.8 or zoom < 0.0001) {
            target_index = (target_index + 1) % zoom_targets.len;
            current_target = zoom_targets[target_index];
            zoom = 3.0;
            max_iter = 32;
            // Don't clear/present here - next frame will render the new target
        }

        // Update zoom
        zoom *= zoom_speed;
        if (frame % 20 == 0 and max_iter < 256) max_iter += 8;

        // Frame timing
        std.Thread.sleep(5 * std.time.ns_per_ms);

        // Exit after exploring all targets twice
        if (frame >= zoom_targets.len * 2 * 500) break;
    }

    // Clean exit
    renderer.clear();
    try renderer.present();
}
