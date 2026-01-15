const std = @import("std");
const lib = @import("thermite");
const terminal = lib.terminal;

/// Draw status bar at bottom of screen
fn drawStatusBar(fd: i32, term_height: u32, term_width: u32, fps: u32, angle: f32, is_paused: bool) void {
    if (term_width < 20 or term_height < 5) return;

    var buf: [256]u8 = undefined;

    // Move to bottom row, set white on black
    const prefix = std.fmt.bufPrint(&buf, "\x1b[{};1H\x1b[0m\x1b[97;40m", .{term_height}) catch return;
    _ = std.posix.write(fd, prefix) catch {};

    // Build status text
    var status_buf: [200]u8 = undefined;
    const status = if (term_width >= 70)
        std.fmt.bufPrint(&status_buf, " {s: <7} | 4D Tesseract | FPS:{d:>3} | Angle:{d:>6.2} | [SPC]=pause [Q]=quit ", .{
            if (is_paused) "PAUSED" else "RUNNING", fps, angle,
        }) catch return
    else if (term_width >= 50)
        std.fmt.bufPrint(&status_buf, " {s: <5} | FPS:{d:>3} | [SPC] [Q] ", .{
            if (is_paused) "PAUSE" else "RUN", fps,
        }) catch return
    else
        std.fmt.bufPrint(&status_buf, " {s} {d:>3}", .{
            if (is_paused) "P" else "R", fps,
        }) catch return;

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

/// 4D vertex
const Vec4 = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
};

/// 2D projected point
const Point2D = struct {
    x: f32,
    y: f32,
};

/// Generate the 16 vertices of a hypercube
fn generateVertices() [16]Vec4 {
    var vertices: [16]Vec4 = undefined;
    for (0..16) |i| {
        vertices[i] = .{
            .x = if (i & 1 != 0) 1.0 else -1.0,
            .y = if (i & 2 != 0) 1.0 else -1.0,
            .z = if (i & 4 != 0) 1.0 else -1.0,
            .w = if (i & 8 != 0) 1.0 else -1.0,
        };
    }
    return vertices;
}

/// Generate edges (vertices that differ in exactly one coordinate)
fn generateEdges() [32][2]u8 {
    var edges: [32][2]u8 = undefined;
    var edge_count: usize = 0;

    for (0..16) |i| {
        for ((i + 1)..16) |j| {
            // Count differing coordinates
            var diff: u32 = 0;
            if ((i & 1) != (j & 1)) diff += 1;
            if ((i & 2) != (j & 2)) diff += 1;
            if ((i & 4) != (j & 4)) diff += 1;
            if ((i & 8) != (j & 8)) diff += 1;

            if (diff == 1) {
                edges[edge_count] = .{ @intCast(i), @intCast(j) };
                edge_count += 1;
            }
        }
    }

    return edges;
}

/// Rotate a 4D point
fn rotate4D(point: Vec4, angle_xz: f32, angle_zw: f32) Vec4 {
    var p = point;

    // Rotate in XZ plane (front-to-back tumble)
    const cos_xz = @cos(angle_xz);
    const sin_xz = @sin(angle_xz);
    const new_x = p.x * cos_xz - p.z * sin_xz;
    const new_z = p.x * sin_xz + p.z * cos_xz;
    p.x = new_x;
    p.z = new_z;

    // Rotate in ZW plane (4D effect)
    const cos_zw = @cos(angle_zw);
    const sin_zw = @sin(angle_zw);
    const new_z2 = p.z * cos_zw - p.w * sin_zw;
    const new_w = p.z * sin_zw + p.w * cos_zw;
    p.z = new_z2;
    p.w = new_w;

    return p;
}

/// Project from 4D to 2D with perspective
fn project4Dto2D(point: Vec4, center_x: f32, center_y: f32, scale: f32) Point2D {
    // Project from 4D to 3D
    const distance_4d: f32 = 3.0;
    const scale_3d = distance_4d / (distance_4d - point.w);
    const x3 = point.x * scale_3d;
    const y3 = point.y * scale_3d;
    const z3 = point.z * scale_3d;

    // Project from 3D to 2D
    const distance_3d: f32 = 3.0;
    const scale_2d = distance_3d / (distance_3d - z3);
    const x2 = x3 * scale_2d;
    const y2 = y3 * scale_2d;

    return .{
        .x = center_x + x2 * scale,
        .y = center_y + y2 * scale * 0.7, // Smush vertically
    };
}

/// Convert HSL to RGB (simplified)
fn hslToRgb(hue: f32, sat: f32, light: f32) u32 {
    const h = @mod(hue, 360.0) / 60.0;
    const c = (1.0 - @abs(2.0 * light - 1.0)) * sat;
    const x = c * (1.0 - @abs(@mod(h, 2.0) - 1.0));
    const m = light - c / 2.0;

    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;

    if (h < 1) {
        r = c;
        g = x;
    } else if (h < 2) {
        r = x;
        g = c;
    } else if (h < 3) {
        g = c;
        b = x;
    } else if (h < 4) {
        g = x;
        b = c;
    } else if (h < 5) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }

    const ri = @as(u8, @intFromFloat((r + m) * 255));
    const gi = @as(u8, @intFromFloat((g + m) * 255));
    const bi = @as(u8, @intFromFloat((b + m) * 255));

    return (@as(u32, ri) << 24) | (@as(u32, gi) << 16) | (@as(u32, bi) << 8) | 0xFF;
}

/// Draw a line using Bresenham's algorithm
fn drawLine(pixels: []u32, width: u32, height: u32, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
    var px0 = x0;
    var py0 = y0;
    const px1 = x1;
    const py1 = y1;

    const dx: i32 = @intCast(@abs(px1 - px0));
    const dy: i32 = @intCast(@abs(py1 - py0));
    const sx: i32 = if (px0 < px1) 1 else -1;
    const sy: i32 = if (py0 < py1) 1 else -1;
    var err = dx - dy;

    while (true) {
        if (px0 >= 0 and py0 >= 0 and px0 < @as(i32, @intCast(width)) and py0 < @as(i32, @intCast(height))) {
            pixels[@intCast(@as(u32, @intCast(py0)) * width + @as(u32, @intCast(px0)))] = color;
        }

        if (px0 == px1 and py0 == py1) break;

        const e2 = 2 * err;
        if (e2 > -dy) {
            err -= dy;
            px0 += sx;
        }
        if (e2 < dx) {
            err += dx;
            py0 += sy;
        }
    }
}

/// Draw a filled circle
fn drawCircle(pixels: []u32, width: u32, height: u32, cx: i32, cy: i32, radius: i32, color: u32) void {
    for (0..@intCast(radius * 2 + 1)) |dy_u| {
        const dy = @as(i32, @intCast(dy_u)) - radius;
        for (0..@intCast(radius * 2 + 1)) |dx_u| {
            const dx = @as(i32, @intCast(dx_u)) - radius;
            if (dx * dx + dy * dy <= radius * radius) {
                const px = cx + dx;
                const py = cy + dy;
                if (px >= 0 and py >= 0 and px < @as(i32, @intCast(width)) and py < @as(i32, @intCast(height))) {
                    pixels[@intCast(@as(u32, @intCast(py)) * width + @as(u32, @intCast(px)))] = color;
                }
            }
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize terminal renderer
    const renderer = try lib.TerminalPixels.init(allocator);
    defer renderer.deinit();

    const term_fd = renderer.getTerminalFd();

    // Install signal handlers for clean Ctrl+C exit and resize
    terminal.installSignalHandlers(term_fd);

    // Get maximum resolution (reserve bottom row for status bar)
    const max_res = renderer.maxResolution();
    var term_width: u32 = max_res.width / 2;
    var term_height: u32 = max_res.height / 2;
    var width: u32 = max_res.width;
    var height: u32 = max_res.height - 2;

    var pixels = try allocator.alloc(u32, width * height);
    defer allocator.free(pixels);

    // Generate hypercube geometry
    const vertices = generateVertices();
    const edges = generateEdges();

    // Animation state
    var angle: f32 = 0;
    var frame: u32 = 0;
    var is_paused = false;

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
            if (key == 'q' or key == 3) break;
            if (key == ' ') is_paused = !is_paused;
        }

        // Check for terminal resize
        if (renderer.checkResize()) |new_res| {
            allocator.free(pixels);
            width = new_res.width;
            height = new_res.height - 2;
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

        // If paused, update status bar and continue
        if (is_paused) {
            drawStatusBar(term_fd, term_height, term_width, fps, angle, is_paused);
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        }

        // Update status bar every 4 frames
        if (frame % 4 == 0) {
            drawStatusBar(term_fd, term_height, term_width, fps, angle, is_paused);
        }

        // Count this frame
        frame += 1;
        fps_frame_count += 1;

        // Clear with dark background
        @memset(pixels, 0x101020FF);

        // Calculate projection parameters
        const center_x = @as(f32, @floatFromInt(width)) / 2.0;
        const center_y = @as(f32, @floatFromInt(height)) / 2.0;
        const scale = @min(center_x, center_y) * 0.25;

        // Rotate and project all vertices
        var projected: [16]Point2D = undefined;
        for (0..16) |i| {
            const rotated = rotate4D(vertices[i], angle, angle * 0.5);
            projected[i] = project4Dto2D(rotated, center_x, center_y, scale);
        }

        // Draw edges with colors based on angle
        for (edges, 0..) |edge, i| {
            const p1 = projected[edge[0]];
            const p2 = projected[edge[1]];

            // Color based on angle for psychedelic effect
            const hue = @mod(angle * 50.0 + @as(f32, @floatFromInt(i)) * 11.25, 360.0);
            const color = hslToRgb(hue, 0.7, 0.5);

            drawLine(
                pixels,
                width,
                height,
                @intFromFloat(p1.x),
                @intFromFloat(p1.y),
                @intFromFloat(p2.x),
                @intFromFloat(p2.y),
                color,
            );
        }

        // Draw vertices
        for (projected, 0..) |point, i| {
            const hue = @mod(angle * 50.0 + @as(f32, @floatFromInt(i)) * 22.5, 360.0);
            const color = hslToRgb(hue, 0.7, 0.6);
            drawCircle(pixels, width, height, @intFromFloat(point.x), @intFromFloat(point.y), 3, color);
        }

        // Render to terminal
        try renderer.setPixels(pixels, width, height);
        try renderer.presentOptimized();

        // Update angle
        angle += 0.02;

        // ~60 FPS
        std.Thread.sleep(16 * std.time.ns_per_ms);
    }

    // Clean exit
    renderer.clear();
    try renderer.present();
}
