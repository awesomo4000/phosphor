const std = @import("std");
const app = @import("app");

// ============================================
// Mandelbrot calculation
// ============================================

fn mandelbrot(c_real: f64, c_imag: f64, max_iter: u32) u32 {
    var z_real: f64 = 0;
    var z_imag: f64 = 0;
    var iter: u32 = 0;

    while (iter < max_iter) : (iter += 1) {
        const z_real_sq = z_real * z_real;
        const z_imag_sq = z_imag * z_imag;

        if (z_real_sq + z_imag_sq > 4.0) break;

        const new_real = z_real_sq - z_imag_sq + c_real;
        const new_imag = 2.0 * z_real * z_imag + c_imag;

        z_real = new_real;
        z_imag = new_imag;
    }

    return iter;
}

fn iterToColor(iter: u32, max_iter: u32) u32 {
    if (iter == max_iter) {
        return 0x000000FF; // Black for inside the set
    }

    const t = @as(f32, @floatFromInt(iter)) / @as(f32, @floatFromInt(max_iter));
    const angle = t * std.math.pi * 4.0;

    const r: u8 = @intFromFloat((@sin(angle) + 1.0) * 127.5);
    const g: u8 = @intFromFloat((@sin(angle + 2.0 * std.math.pi / 3.0) + 1.0) * 127.5);
    const b: u8 = @intFromFloat((@sin(angle + 4.0 * std.math.pi / 3.0) + 1.0) * 127.5);

    return (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
}

// ============================================
// Zoom targets
// ============================================

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

// ============================================
// Model
// ============================================

pub const Model = struct {
    canvas: app.Canvas(Model) = .{ .render_fn = render },

    // Zoom state
    zoom: f64 = 3.0,
    target_index: usize = 0,
    max_iter: u32 = 32,

    // Animation
    frame: u32 = 0,
    is_paused: bool = false,
    last_black_pct: f32 = 0,

    // FPS tracking
    fps: u32 = 0,
    fps_frame_count: u32 = 0,
    fps_last_time: i64 = 0,

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        self.canvas.deinit(allocator);
    }

    pub fn currentTarget(self: *const Model) ZoomTarget {
        return zoom_targets[self.target_index];
    }
};

// ============================================
// Messages
// ============================================

pub const Msg = union(enum) {
    tick: f32,
    key: u8,
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

            // Update FPS
            const now = std.time.milliTimestamp();
            if (now - model.fps_last_time >= 1000) {
                model.fps = model.fps_frame_count;
                model.fps_frame_count = 0;
                model.fps_last_time = now;
            }

            model.frame += 1;
            model.fps_frame_count += 1;

            // Update zoom
            model.zoom *= 0.95;
            if (model.frame % 20 == 0 and model.max_iter < 256) {
                model.max_iter += 8;
            }

            // Auto-advance if mostly black or zoomed too far
            if (model.last_black_pct > 0.8 or model.zoom < 0.0001) {
                model.target_index = (model.target_index + 1) % zoom_targets.len;
                model.zoom = 3.0;
                model.max_iter = 32;
            }

            // Exit after exploring all targets twice
            if (model.frame >= zoom_targets.len * 2 * 500) {
                return .quit;
            }
        },
        .key => |k| {
            if (k == 'q' or k == 3) return .quit;
            if (k == ' ') model.is_paused = !model.is_paused;
        },
        .resize => |size| {
            model.canvas.resize(allocator, size.w, size.h) catch {};
        },
    }
    return .none;
}

fn onKey(key: u8) Msg {
    return .{ .key = key };
}

fn render(model: *Model) void {
    const width = model.canvas.width;
    const height = model.canvas.height;
    if (width == 0 or height == 0) return;

    const target = model.currentTarget();
    const aspect_ratio = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(height));
    const real_min = target.center_real - model.zoom * aspect_ratio * 0.5;
    const real_max = target.center_real + model.zoom * aspect_ratio * 0.5;
    const imag_min = target.center_imag - model.zoom * 0.5;
    const imag_max = target.center_imag + model.zoom * 0.5;

    var black_count: u32 = 0;

    for (0..height) |y| {
        for (0..width) |x| {
            const real = real_min + (@as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(width - 1))) * (real_max - real_min);
            const imag = imag_min + (@as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(height - 1))) * (imag_max - imag_min);

            const iter = mandelbrot(real, imag, model.max_iter);
            const color = iterToColor(iter, model.max_iter);
            model.canvas.pixels[y * width + x] = color;

            if (iter == model.max_iter) black_count += 1;
        }
    }

    model.last_black_pct = @as(f32, @floatFromInt(black_count)) / @as(f32, @floatFromInt(width * height));
}

pub fn view(model: *Model, ui: *app.Ui) *app.Node {
    return ui.canvas(Model, Msg, .{
        .buffer = &model.canvas,
        .ctx = model,
        .on_key = onKey,
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

    try app.App(@This()).run(gpa.allocator(), .{ .backend = .thermite });
}
