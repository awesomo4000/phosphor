const std = @import("std");
const lib = @import("thermite");
const terminal = lib.terminal;

/// Draw status bar at bottom of screen
fn drawStatusBar(fd: i32, term_height: u32, term_width: u32, fps: u32, is_paused: bool, use_aa: bool) void {
    if (term_width < 20 or term_height < 5) return;

    var buf: [256]u8 = undefined;

    // Move to bottom row, set white on black
    const prefix = std.fmt.bufPrint(&buf, "\x1b[{};1H\x1b[0m\x1b[97;40m", .{term_height}) catch return;
    _ = std.posix.write(fd, prefix) catch {};

    // Build status text
    var status_buf: [200]u8 = undefined;
    const status = if (term_width >= 80)
        std.fmt.bufPrint(&status_buf, " {s: <7} | 4D Tesseract | FPS:{d:>3} | {s: <2} | [SPC]=pause [A]=aa [Q]=quit ", .{
            if (is_paused) "PAUSED" else "RUNNING", fps, if (use_aa) "AA" else "  ",
        }) catch return
    else if (term_width >= 50)
        std.fmt.bufPrint(&status_buf, " {s: <5} | FPS:{d:>3} | {s} ", .{
            if (is_paused) "PAUSE" else "RUN", fps, if (use_aa) "AA" else "  ",
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

/// Downsample a buffer by 2x (average each 2x2 block)
fn downsample2x(src: []const u32, src_width: u32, src_height: u32, dst: []u32) void {
    const dst_width = src_width / 2;
    const dst_height = src_height / 2;

    for (0..dst_height) |dy| {
        for (0..dst_width) |dx| {
            const sx = dx * 2;
            const sy = dy * 2;

            // Get 4 source pixels
            const p00 = src[sy * src_width + sx];
            const p10 = src[sy * src_width + sx + 1];
            const p01 = src[(sy + 1) * src_width + sx];
            const p11 = src[(sy + 1) * src_width + sx + 1];

            // Average each channel
            const r = (@as(u32, (p00 >> 24) & 0xFF) + @as(u32, (p10 >> 24) & 0xFF) +
                @as(u32, (p01 >> 24) & 0xFF) + @as(u32, (p11 >> 24) & 0xFF)) / 4;
            const g = (@as(u32, (p00 >> 16) & 0xFF) + @as(u32, (p10 >> 16) & 0xFF) +
                @as(u32, (p01 >> 16) & 0xFF) + @as(u32, (p11 >> 16) & 0xFF)) / 4;
            const b = (@as(u32, (p00 >> 8) & 0xFF) + @as(u32, (p10 >> 8) & 0xFF) +
                @as(u32, (p01 >> 8) & 0xFF) + @as(u32, (p11 >> 8) & 0xFF)) / 4;

            dst[dy * dst_width + dx] = (r << 24) | (g << 16) | (b << 8) | 0xFF;
        }
    }
}

/// Blend a color onto a pixel with given alpha (0.0 = transparent, 1.0 = opaque)
/// Uses boosted alpha so AA pixels stay closer to the line color
fn blendPixel(pixels: []u32, width: u32, height: u32, x: i32, y: i32, color: u32, alpha: f32) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(width)) or y >= @as(i32, @intCast(height))) return;

    const idx = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
    const bg = pixels[idx];

    // Boost alpha so AA pixels don't fade too much into background
    // Maps 0.0-1.0 to 0.7-1.0 range
    const boosted_alpha = 0.7 + alpha * 0.3;

    // Extract color components (RGBA format)
    const fg_r = @as(f32, @floatFromInt((color >> 24) & 0xFF));
    const fg_g = @as(f32, @floatFromInt((color >> 16) & 0xFF));
    const fg_b = @as(f32, @floatFromInt((color >> 8) & 0xFF));

    const bg_r = @as(f32, @floatFromInt((bg >> 24) & 0xFF));
    const bg_g = @as(f32, @floatFromInt((bg >> 16) & 0xFF));
    const bg_b = @as(f32, @floatFromInt((bg >> 8) & 0xFF));

    // Blend with boosted alpha
    const r = @as(u8, @intFromFloat(bg_r + (fg_r - bg_r) * boosted_alpha));
    const g = @as(u8, @intFromFloat(bg_g + (fg_g - bg_g) * boosted_alpha));
    const b = @as(u8, @intFromFloat(bg_b + (fg_b - bg_b) * boosted_alpha));

    pixels[idx] = (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
}

/// Draw a thick anti-aliased line (3 pixels wide to avoid gaps in terminal blocks)
fn drawLineAA(pixels: []u32, width: u32, height: u32, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
    var fx0 = @as(f32, @floatFromInt(x0));
    var fy0 = @as(f32, @floatFromInt(y0));
    var fx1 = @as(f32, @floatFromInt(x1));
    var fy1 = @as(f32, @floatFromInt(y1));

    const steep = @abs(fy1 - fy0) > @abs(fx1 - fx0);

    if (steep) {
        std.mem.swap(f32, &fx0, &fy0);
        std.mem.swap(f32, &fx1, &fy1);
    }

    if (fx0 > fx1) {
        std.mem.swap(f32, &fx0, &fx1);
        std.mem.swap(f32, &fy0, &fy1);
    }

    const dx = fx1 - fx0;
    const dy = fy1 - fy0;
    const gradient = if (dx < 0.0001) 1.0 else dy / dx;

    // First endpoint
    var xend = @round(fx0);
    const yend = fy0 + gradient * (xend - fx0);
    const xpxl1 = @as(i32, @intFromFloat(xend));

    var intery = yend + gradient;

    // Second endpoint
    xend = @round(fx1);
    const xpxl2 = @as(i32, @intFromFloat(xend));

    // Main loop - draw 3 pixels per step for thickness
    var x = xpxl1;
    while (x <= xpxl2) : (x += 1) {
        const iy = @as(i32, @intFromFloat(@round(intery)));
        const frac = @abs(intery - @round(intery));

        if (steep) {
            // Draw center pixel at full, neighbors at partial
            blendPixel(pixels, width, height, iy, x, color, 1.0);
            blendPixel(pixels, width, height, iy - 1, x, color, 0.5 - frac * 0.5);
            blendPixel(pixels, width, height, iy + 1, x, color, 0.5 - frac * 0.5);
        } else {
            blendPixel(pixels, width, height, x, iy, color, 1.0);
            blendPixel(pixels, width, height, x, iy - 1, color, 0.5 - frac * 0.5);
            blendPixel(pixels, width, height, x, iy + 1, color, 0.5 - frac * 0.5);
        }

        if (x >= xpxl1 and x < xpxl2) {
            intery += gradient;
        }
    }
}

/// Draw an anti-aliased filled circle using distance-based blending
fn drawCircleAA(pixels: []u32, width: u32, height: u32, cx: i32, cy: i32, radius: i32, color: u32) void {
    const r = @as(f32, @floatFromInt(radius));
    const r_outer = r + 1.0; // AA extends 1 pixel beyond radius

    const r_outer_i = @as(i32, @intFromFloat(@ceil(r_outer)));

    var dy: i32 = -r_outer_i;
    while (dy <= r_outer_i) : (dy += 1) {
        var dx: i32 = -r_outer_i;
        while (dx <= r_outer_i) : (dx += 1) {
            const fdx = @as(f32, @floatFromInt(dx));
            const fdy = @as(f32, @floatFromInt(dy));
            const dist = @sqrt(fdx * fdx + fdy * fdy);

            if (dist <= r_outer) {
                // Calculate alpha based on distance from edge
                const alpha = if (dist <= r - 1.0)
                    1.0 // Fully inside
                else if (dist >= r)
                    @max(0.0, 1.0 - (dist - r)) // Outside edge, fade out
                else
                    1.0; // Near edge inside

                if (alpha > 0.0) {
                    blendPixel(pixels, width, height, cx + dx, cy + dy, color, alpha);
                }
            }
        }
    }
}

/// Set a pixel directly (no blending)
fn setPixel(pixels: []u32, width: u32, height: u32, x: i32, y: i32, color: u32) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(width)) or y >= @as(i32, @intCast(height))) return;
    const idx = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
    pixels[idx] = color;
}

/// Draw a simple line using Bresenham's algorithm (no AA)
fn drawLineSimple(pixels: []u32, width: u32, height: u32, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
    var px0 = x0;
    var py0 = y0;
    const px1 = x1;
    const py1 = y1;

    const dx: i32 = if (px1 > px0) px1 - px0 else px0 - px1;
    const dy: i32 = if (py1 > py0) py1 - py0 else py0 - py1;
    const sx: i32 = if (px0 < px1) 1 else -1;
    const sy: i32 = if (py0 < py1) 1 else -1;
    var err = dx - dy;

    while (true) {
        setPixel(pixels, width, height, px0, py0, color);
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

/// Draw a simple filled circle (no AA)
fn drawCircleSimple(pixels: []u32, width: u32, height: u32, cx: i32, cy: i32, radius: i32, color: u32) void {
    var dy: i32 = -radius;
    while (dy <= radius) : (dy += 1) {
        var dx: i32 = -radius;
        while (dx <= radius) : (dx += 1) {
            if (dx * dx + dy * dy <= radius * radius) {
                setPixel(pixels, width, height, cx + dx, cy + dy, color);
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

    // Output buffer (sent to renderer)
    var pixels = try allocator.alloc(u32, width * height);
    defer allocator.free(pixels);

    // Render buffer (2x resolution for supersampling)
    var render_width: u32 = width * 2;
    var render_height: u32 = height * 2;
    var render_pixels = try allocator.alloc(u32, render_width * render_height);
    defer allocator.free(render_pixels);

    // Generate hypercube geometry
    const vertices = generateVertices();
    const edges = generateEdges();

    // Animation state
    var angle: f32 = 0;
    var frame: u32 = 0;
    var is_paused = false;
    var use_aa = true; // Toggle anti-aliasing with 'a' key

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
            if (key == 'a') use_aa = !use_aa;
        }

        // Check for terminal resize
        if (renderer.checkResize()) |new_res| {
            allocator.free(pixels);
            allocator.free(render_pixels);
            width = new_res.width;
            height = new_res.height - 2;
            term_width = new_res.width / 2;
            term_height = new_res.height / 2;
            pixels = try allocator.alloc(u32, width * height);
            render_width = width * 2;
            render_height = height * 2;
            render_pixels = try allocator.alloc(u32, render_width * render_height);
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
            drawStatusBar(term_fd, term_height, term_width, fps, is_paused, use_aa);
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        }

        // Update status bar every 4 frames
        if (frame % 4 == 0) {
            drawStatusBar(term_fd, term_height, term_width, fps, is_paused, use_aa);
        }

        // Count this frame
        frame += 1;
        fps_frame_count += 1;

        // Clear render buffer (2x resolution) with dark background
        @memset(render_pixels, 0x101020FF);

        // Calculate projection parameters at 2x scale
        const center_x = @as(f32, @floatFromInt(render_width)) / 2.0;
        const center_y = @as(f32, @floatFromInt(render_height)) / 2.0;
        const scale = @min(center_x, center_y) * 0.25;

        // Rotate and project all vertices
        var projected: [16]Point2D = undefined;
        for (0..16) |i| {
            const rotated = rotate4D(vertices[i], angle, angle * 0.5);
            projected[i] = project4Dto2D(rotated, center_x, center_y, scale);
        }

        // Draw edges with full rainbow spread (to render buffer)
        for (edges, 0..) |edge, i| {
            const p1 = projected[edge[0]];
            const p2 = projected[edge[1]];

            // Full rainbow - each edge gets different hue
            const hue = @mod(angle * 50.0 + @as(f32, @floatFromInt(i)) * 11.25, 360.0);
            const color = hslToRgb(hue, 0.7, 0.5);

            if (use_aa) {
                drawLineAA(
                    render_pixels,
                    render_width,
                    render_height,
                    @intFromFloat(p1.x),
                    @intFromFloat(p1.y),
                    @intFromFloat(p2.x),
                    @intFromFloat(p2.y),
                    color,
                );
            } else {
                drawLineSimple(
                    render_pixels,
                    render_width,
                    render_height,
                    @intFromFloat(p1.x),
                    @intFromFloat(p1.y),
                    @intFromFloat(p2.x),
                    @intFromFloat(p2.y),
                    color,
                );
            }
        }

        // Draw vertices with full rainbow (to render buffer)
        for (projected, 0..) |point, i| {
            const hue = @mod(angle * 50.0 + @as(f32, @floatFromInt(i)) * 22.5, 360.0);
            const color = hslToRgb(hue, 0.7, 0.6);
            if (use_aa) {
                drawCircleAA(render_pixels, render_width, render_height, @intFromFloat(point.x), @intFromFloat(point.y), 6, color);
            } else {
                drawCircleSimple(render_pixels, render_width, render_height, @intFromFloat(point.x), @intFromFloat(point.y), 4, color);
            }
        }

        // Downsample 2x to output buffer
        downsample2x(render_pixels, render_width, render_height, pixels);

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
