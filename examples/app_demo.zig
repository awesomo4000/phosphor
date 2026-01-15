const std = @import("std");
const app = @import("app");

// ============================================
// Model - owns widget state (including canvas)
// ============================================

pub const Model = struct {
    canvas: app.Canvas(Model) = .{ .render_fn = render },
    box_x: f32 = 10,
    box_y: f32 = 10,
    vel_x: f32 = 60,
    vel_y: f32 = 40,
    is_paused: bool = false,

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        self.canvas.deinit(allocator);
    }
};

// ============================================
// Messages
// ============================================

pub const Msg = union(enum) {
    tick: f32,
    canvas_key: u8, // from onKey handler
    resize: app.Size,
};

// ============================================
// App functions
// ============================================

pub fn init() Model {
    return .{};
}

pub fn update(model: *Model, msg: Msg, allocator: std.mem.Allocator) app.Cmd {
    switch (msg) {
        .tick => |dt| {
            if (model.is_paused) return .none;
            if (model.canvas.width < 30 or model.canvas.height < 30) return .none;

            // Update position
            model.box_x += model.vel_x * dt;
            model.box_y += model.vel_y * dt;

            // Bounce off walls
            const max_x = @as(f32, @floatFromInt(model.canvas.width - 20));
            const max_y = @as(f32, @floatFromInt(model.canvas.height - 20));

            if (model.box_x <= 0 or model.box_x >= max_x) {
                model.vel_x = -model.vel_x;
                model.box_x = std.math.clamp(model.box_x, 0, max_x);
            }
            if (model.box_y <= 0 or model.box_y >= max_y) {
                model.vel_y = -model.vel_y;
                model.box_y = std.math.clamp(model.box_y, 0, max_y);
            }
        },
        // Key events come through onKey handler
        .canvas_key => |k| switch (k) {
            'q', 3 => return .quit,
            ' ' => model.is_paused = !model.is_paused,
            else => {},
        },
        .resize => |size| {
            // Resize canvas directly using runtime's allocator
            model.canvas.resize(allocator, size.w, size.h * 2) catch {};
        },
    }
    return .none;
}

/// Named key handler - converts raw key to Msg
fn onCanvasKey(key: u8) Msg {
    return .{ .canvas_key = key };
}

/// Render function - draws to canvas (called from view tree)
fn render(model: *Model) void {
    if (model.canvas.width == 0 or model.canvas.height == 0) return;

    // Clear with dark blue
    model.canvas.clear(0x102040FF);

    // Draw bouncing box
    const x: i32 = @intFromFloat(model.box_x);
    const y: i32 = @intFromFloat(model.box_y);
    model.canvas.drawRect(x, y, 20, 20, 0xFF8000FF); // Orange box

    // Draw border
    const w = model.canvas.width;
    const h = model.canvas.height;
    var i: u32 = 0;
    while (i < w) : (i += 1) {
        model.canvas.setPixel(@intCast(i), 0, 0xFFFFFFFF);
        model.canvas.setPixel(@intCast(i), @intCast(h - 1), 0xFFFFFFFF);
    }
    i = 0;
    while (i < h) : (i += 1) {
        model.canvas.setPixel(0, @intCast(i), 0xFFFFFFFF);
        model.canvas.setPixel(@intCast(w - 1), @intCast(i), 0xFFFFFFFF);
    }
}

pub fn view(model: *Model, ui: *app.Ui) *app.Node {
    return ui.canvas(Model, Msg, .{
        .buffer = &model.canvas,
        .ctx = model,
        .on_key = onCanvasKey,
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

    try app.App(@This()).run(gpa.allocator());
}
