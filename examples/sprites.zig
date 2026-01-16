const std = @import("std");
const app = @import("app");

// ============================================
// Model
// ============================================

pub const Model = struct {
    canvas: app.Canvas(Model) = .{ .render_fn = render },

    // Smiley animation
    smiley_x: f32 = 10,
    smiley_y: f32 = 10,
    smiley_vx: f32 = 2.5,
    smiley_vy: f32 = 1.8,

    // Ball animation (with gravity)
    ball_x: f32 = 100,
    ball_y: f32 = 20,
    ball_vx: f32 = -3.2,
    ball_vy: f32 = 2.1,

    // Star animation (orbital)
    star_angle: f32 = 0,

    // Frame counter
    frame: u32 = 0,

    // FPS tracking
    fps: u32 = 0,
    fps_frame_count: u32 = 0,
    fps_last_time: i64 = 0,

    // Status bar buffer
    status_buf: [128]u8 = undefined,
    status_len: usize = 0,

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        self.canvas.deinit(allocator);
    }

    pub fn getStatusText(self: *Model) []const u8 {
        self.status_len = (std.fmt.bufPrint(&self.status_buf, " Sprite Demo | FPS:{d:>3} | Frame:{d:>6} | [Q]=quit ", .{
            self.fps, self.frame,
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
            const width = model.canvas.width;
            const height = model.canvas.height;
            if (width == 0 or height == 0) return .none;

            // Update FPS
            const now = std.time.milliTimestamp();
            if (now - model.fps_last_time >= 1000) {
                model.fps = model.fps_frame_count;
                model.fps_frame_count = 0;
                model.fps_last_time = now;
            }
            model.frame += 1;
            model.fps_frame_count += 1;

            // Update smiley (16x16 sprite)
            if (width > 16 and height > 16) {
                model.smiley_x += model.smiley_vx;
                model.smiley_y += model.smiley_vy;

                const max_x = @as(f32, @floatFromInt(width - 16));
                const max_y = @as(f32, @floatFromInt(height - 16));

                if (model.smiley_x <= 0 or model.smiley_x >= max_x) {
                    model.smiley_vx = -model.smiley_vx;
                    model.smiley_x = std.math.clamp(model.smiley_x, 0, max_x);
                }
                if (model.smiley_y <= 0 or model.smiley_y >= max_y) {
                    model.smiley_vy = -model.smiley_vy;
                    model.smiley_y = std.math.clamp(model.smiley_y, 0, max_y);
                }
            }

            // Update ball (8x8 sprite with gravity)
            if (width > 8 and height > 8) {
                model.ball_x += model.ball_vx;
                model.ball_y += model.ball_vy;
                model.ball_vy += 0.2; // Gravity

                const max_x = @as(f32, @floatFromInt(width - 8));
                const max_y = @as(f32, @floatFromInt(height - 8));

                // Horizontal bounce
                if (model.ball_x <= 0) {
                    model.ball_x = 0;
                    model.ball_vx = -model.ball_vx * 0.9;
                } else if (model.ball_x >= max_x) {
                    model.ball_x = max_x;
                    model.ball_vx = -model.ball_vx * 0.9;
                }

                // Vertical bounce
                if (model.ball_y >= max_y) {
                    model.ball_y = max_y;
                    if (@abs(model.ball_vy) < 1.0) {
                        model.ball_vy = 0;
                        model.ball_vx *= 0.98;
                        if (@abs(model.ball_vx) < 0.1) model.ball_vx = 0;
                    } else {
                        model.ball_vy = -model.ball_vy * 0.8;
                    }
                }
            }

            // Update star orbit
            model.star_angle += 0.05;
        },
        .key => |k| {
            switch (k) {
                .char => |c| if (c == 'q') return .quit,
                .ctrl_c => return .quit,
                else => {},
            }
        },
        .resize => |size| {
            model.canvas.resize(allocator, size.w, size.h) catch {};
            // Reset ball position on resize
            model.ball_x = @as(f32, @floatFromInt(size.w)) - 20;
            model.ball_y = 20;
            model.ball_vx = -3.2;
            model.ball_vy = 2.1;
        },
    }
    return .none;
}

// Use wrap() to create key handler - no need for custom function
const onKey = app.wrap(Msg, .key);

fn render(model: *Model) void {
    const width = model.canvas.width;
    const height = model.canvas.height;
    if (width == 0 or height == 0) return;

    // Draw gradient background
    for (0..height) |y| {
        const intensity: u8 = @intFromFloat(@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height)) * 80);
        const color = (@as(u32, intensity) << 16) | (@as(u32, intensity / 2) << 8) | 0xFF;
        for (0..width) |x| {
            model.canvas.pixels[y * width + x] = color;
        }
    }

    // Draw smiley (16x16 yellow face)
    if (width > 16 and height > 16) {
        const sx: i32 = @intFromFloat(model.smiley_x);
        const sy: i32 = @intFromFloat(model.smiley_y);

        // Yellow background
        model.canvas.drawRect(sx, sy, 16, 16, 0xFFFF00FF);

        // Eyes (black)
        model.canvas.drawRect(sx + 4, sy + 4, 2, 2, 0x000000FF);
        model.canvas.drawRect(sx + 10, sy + 4, 2, 2, 0x000000FF);

        // Mouth
        var mx: i32 = 4;
        while (mx < 12) : (mx += 1) {
            const my = 10 + @divTrunc(@as(i32, @intCast(@abs(mx - 7))), 2);
            model.canvas.setPixel(sx + mx, sy + my, 0x000000FF);
        }
    }

    // Draw ball (8x8 red circle)
    if (width > 8 and height > 8) {
        const bx: i32 = @intFromFloat(model.ball_x);
        const by: i32 = @intFromFloat(model.ball_y);

        var dy: i32 = 0;
        while (dy < 8) : (dy += 1) {
            var dx: i32 = 0;
            while (dx < 8) : (dx += 1) {
                const fx = @as(f32, @floatFromInt(dx)) - 3.5;
                const fy = @as(f32, @floatFromInt(dy)) - 3.5;
                if (fx * fx + fy * fy <= 3.5 * 3.5) {
                    model.canvas.setPixel(bx + dx, by + dy, 0xFF0000FF);
                }
            }
        }
    }

    // Draw rotating star (12x12 purple)
    const star_x = @as(f32, @floatFromInt(width / 2)) + @cos(model.star_angle) * @as(f32, @floatFromInt(width / 3));
    const star_y = @as(f32, @floatFromInt(height / 2)) + @sin(model.star_angle) * @as(f32, @floatFromInt(height / 3));

    if (star_x >= 0 and star_y >= 0) {
        const stx: i32 = @intFromFloat(star_x);
        const sty: i32 = @intFromFloat(star_y);

        // Star shape
        model.canvas.drawRect(stx + 5, sty, 2, 12, 0xAA00FFFF); // Vertical
        model.canvas.drawRect(stx, sty + 5, 12, 2, 0xAA00FFFF); // Horizontal
        model.canvas.drawRect(stx + 2, sty + 2, 8, 8, 0xAA00FFFF); // Center
    }

    // Draw particles
    if (width > 100 and height > 60) {
        const time = @as(f32, @floatFromInt(model.frame)) * 0.1;
        for (0..20) |i| {
            const fi = @as(f32, @floatFromInt(i));
            const px = @as(f32, @floatFromInt(width / 2)) + @sin(time + fi) * 50;
            const py = @as(f32, @floatFromInt(height / 2)) + @cos(time * 1.3 + fi) * 30;
            if (px >= 0 and py >= 0) {
                model.canvas.setPixel(@intFromFloat(px), @intFromFloat(py), 0xFFFFFFFF);
            }
        }
    }
}

pub fn view(model: *Model, ui: *app.Ui) *app.Node {
    return ui.canvas(Model, Msg, .{
        .buffer = &model.canvas,
        .ctx = model,
        .on_key = onKey,
        .overlay_text = model.getStatusText(),
    });
}

pub fn subs(_: *Model) app.Subs {
    return .{
        .keyboard = true,
        .animation_frame = true,
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
