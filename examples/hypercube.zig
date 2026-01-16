const std = @import("std");
const app = @import("app");

// ============================================
// 4D Geometry
// ============================================

const Vec4 = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
};

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

    // Rotate in XZ plane
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
    const distance_4d: f32 = 3.0;
    const scale_3d = distance_4d / (distance_4d - point.w);
    const x3 = point.x * scale_3d;
    const y3 = point.y * scale_3d;
    const z3 = point.z * scale_3d;

    const distance_3d: f32 = 3.0;
    const scale_2d = distance_3d / (distance_3d - z3);
    const x2 = x3 * scale_2d;
    const y2 = y3 * scale_2d;

    return .{
        .x = center_x + x2 * scale,
        .y = center_y + y2 * scale * 0.7,
    };
}

/// Convert HSL to RGB
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

// ============================================
// Model
// ============================================

pub const Model = struct {
    canvas: app.Canvas(Model) = .{ .render_fn = render },

    // Hypercube geometry (computed once)
    vertices: [16]Vec4 = generateVertices(),
    edges: [32][2]u8 = generateEdges(),

    // Animation state
    angle: f32 = 0,
    frame: u32 = 0,
    is_paused: bool = false,
    use_aa: bool = true,

    // Supersampling buffer (2x resolution)
    render_pixels: ?[]u32 = null,
    render_width: u32 = 0,
    render_height: u32 = 0,

    // FPS tracking
    fps: u32 = 0,
    fps_frame_count: u32 = 0,
    fps_last_time: i64 = 0,

    // Status bar buffer
    status_buf: [128]u8 = undefined,
    status_len: usize = 0,

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        self.canvas.deinit(allocator);
        if (self.render_pixels) |rp| {
            allocator.free(rp);
        }
    }

    pub fn getStatusText(self: *Model) []const u8 {
        const status = if (self.is_paused) "PAUSED " else "RUNNING";
        const aa_status = if (self.use_aa) "ON " else "OFF";
        self.status_len = (std.fmt.bufPrint(&self.status_buf, " {s} | FPS:{d:>3} | AA:{s} | [SPC]=pause [A]=AA [Q]=quit ", .{
            status, self.fps, aa_status,
        }) catch &self.status_buf).len;
        return self.status_buf[0..self.status_len];
    }
};

// ============================================
// Messages
// ============================================

pub const Msg = union(enum) {
    tick: f32,
    key: app.Key,
    resize: app.Size,
};

// ============================================
// App functions
// ============================================

pub fn init() Model {
    return .{ .fps_last_time = std.time.milliTimestamp() };
}

pub fn update(model: *Model, msg: Msg, allocator: std.mem.Allocator) app.Cmd {
    switch (msg) {
        .tick => |_| {
            if (model.is_paused) return .none;
            if (model.canvas.width == 0 or model.canvas.height == 0) return .none;

            // Update FPS
            const now = std.time.milliTimestamp();
            if (now - model.fps_last_time >= 1000) {
                model.fps = model.fps_frame_count;
                model.fps_frame_count = 0;
                model.fps_last_time = now;
            }
            model.frame += 1;
            model.fps_frame_count += 1;

            // Update rotation angle
            model.angle += 0.02;
        },
        .key => |k| {
            switch (k) {
                .char => |c| {
                    if (c == 'q') return .quit;
                    if (c == ' ') model.is_paused = !model.is_paused;
                    if (c == 'a') model.use_aa = !model.use_aa;
                },
                .ctrl_c => return .quit,
                else => {},
            }
        },
        .resize => |size| {
            model.canvas.resize(allocator, size.w, size.h) catch {};

            // Resize supersampling buffer (2x resolution)
            if (model.render_pixels) |rp| {
                allocator.free(rp);
            }
            model.render_width = size.w * 2;
            model.render_height = size.h * 2;
            model.render_pixels = allocator.alloc(u32, model.render_width * model.render_height) catch null;
        },
    }
    return .none;
}

// Use wrap() to create key handler
const onKey = app.wrap(Msg, .key);

// ============================================
// Drawing helpers
// ============================================

fn setPixel(pixels: []u32, width: u32, height: u32, x: i32, y: i32, color: u32) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(width)) or y >= @as(i32, @intCast(height))) return;
    const idx = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
    pixels[idx] = color;
}

fn blendPixel(pixels: []u32, width: u32, height: u32, x: i32, y: i32, color: u32, alpha: f32) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(width)) or y >= @as(i32, @intCast(height))) return;

    const idx = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
    const bg = pixels[idx];

    const boosted_alpha = 0.7 + alpha * 0.3;

    const fg_r = @as(f32, @floatFromInt((color >> 24) & 0xFF));
    const fg_g = @as(f32, @floatFromInt((color >> 16) & 0xFF));
    const fg_b = @as(f32, @floatFromInt((color >> 8) & 0xFF));

    const bg_r = @as(f32, @floatFromInt((bg >> 24) & 0xFF));
    const bg_g = @as(f32, @floatFromInt((bg >> 16) & 0xFF));
    const bg_b = @as(f32, @floatFromInt((bg >> 8) & 0xFF));

    const r = @as(u8, @intFromFloat(bg_r + (fg_r - bg_r) * boosted_alpha));
    const g = @as(u8, @intFromFloat(bg_g + (fg_g - bg_g) * boosted_alpha));
    const b = @as(u8, @intFromFloat(bg_b + (fg_b - bg_b) * boosted_alpha));

    pixels[idx] = (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
}

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

    var xend = @round(fx0);
    const yend = fy0 + gradient * (xend - fx0);
    const xpxl1 = @as(i32, @intFromFloat(xend));

    var intery = yend + gradient;

    xend = @round(fx1);
    const xpxl2 = @as(i32, @intFromFloat(xend));

    var x = xpxl1;
    while (x <= xpxl2) : (x += 1) {
        const iy = @as(i32, @intFromFloat(@round(intery)));
        const frac = @abs(intery - @round(intery));

        if (steep) {
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

fn drawCircleAA(pixels: []u32, width: u32, height: u32, cx: i32, cy: i32, radius: i32, color: u32) void {
    const r = @as(f32, @floatFromInt(radius));
    const r_outer = r + 1.0;
    const r_outer_i = @as(i32, @intFromFloat(@ceil(r_outer)));

    var dy: i32 = -r_outer_i;
    while (dy <= r_outer_i) : (dy += 1) {
        var dx: i32 = -r_outer_i;
        while (dx <= r_outer_i) : (dx += 1) {
            const fdx = @as(f32, @floatFromInt(dx));
            const fdy = @as(f32, @floatFromInt(dy));
            const dist = @sqrt(fdx * fdx + fdy * fdy);

            if (dist <= r_outer) {
                const alpha = if (dist <= r - 1.0)
                    1.0
                else if (dist >= r)
                    @max(0.0, 1.0 - (dist - r))
                else
                    1.0;

                if (alpha > 0.0) {
                    blendPixel(pixels, width, height, cx + dx, cy + dy, color, alpha);
                }
            }
        }
    }
}

fn downsample2x(src: []const u32, src_width: u32, src_height: u32, dst: []u32) void {
    const dst_width = src_width / 2;
    const dst_height = src_height / 2;

    for (0..dst_height) |dy| {
        for (0..dst_width) |dx| {
            const sx = dx * 2;
            const sy = dy * 2;

            const p00 = src[sy * src_width + sx];
            const p10 = src[sy * src_width + sx + 1];
            const p01 = src[(sy + 1) * src_width + sx];
            const p11 = src[(sy + 1) * src_width + sx + 1];

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

// ============================================
// Render
// ============================================

fn render(model: *Model) void {
    const width = model.canvas.width;
    const height = model.canvas.height;
    if (width == 0 or height == 0) return;

    const render_pixels = model.render_pixels orelse return;
    const render_width = model.render_width;
    const render_height = model.render_height;

    // Clear render buffer with dark background
    @memset(render_pixels, 0x101020FF);

    // Calculate projection parameters at 2x scale
    const center_x = @as(f32, @floatFromInt(render_width)) / 2.0;
    const center_y = @as(f32, @floatFromInt(render_height)) / 2.0;
    const scale = @min(center_x, center_y) * 0.25;

    // Rotate and project all vertices
    var projected: [16]Point2D = undefined;
    for (0..16) |i| {
        const rotated = rotate4D(model.vertices[i], model.angle, model.angle * 0.5);
        projected[i] = project4Dto2D(rotated, center_x, center_y, scale);
    }

    // Draw edges with rainbow colors
    for (model.edges, 0..) |edge, i| {
        const p1 = projected[edge[0]];
        const p2 = projected[edge[1]];

        const hue = @mod(model.angle * 50.0 + @as(f32, @floatFromInt(i)) * 11.25, 360.0);
        const color = hslToRgb(hue, 0.7, 0.5);

        if (model.use_aa) {
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

    // Draw vertices with rainbow colors
    for (projected, 0..) |point, i| {
        const hue = @mod(model.angle * 50.0 + @as(f32, @floatFromInt(i)) * 22.5, 360.0);
        const color = hslToRgb(hue, 0.7, 0.6);
        if (model.use_aa) {
            drawCircleAA(render_pixels, render_width, render_height, @intFromFloat(point.x), @intFromFloat(point.y), 6, color);
        } else {
            drawCircleSimple(render_pixels, render_width, render_height, @intFromFloat(point.x), @intFromFloat(point.y), 4, color);
        }
    }

    // Downsample 2x to output buffer
    downsample2x(render_pixels, render_width, render_height, model.canvas.pixels);
}

pub fn view(model: *Model, ui: *app.Ui) *app.Node {
    return ui.canvas(Model, Msg, .{
        .buffer = &model.canvas,
        .ctx = model,
        .on_key = onKey,
        .overlay_text = model.getStatusText(),
    });
}

pub fn subs(model: *Model) app.Subs {
    return .{
        .keyboard = true,
        .animation_frame = !model.is_paused,
    };
}

// ============================================
// Main
// ============================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    try app.App(@This()).run(gpa.allocator(), .{ .backend = .thermite, .target_fps = 120 });
}
