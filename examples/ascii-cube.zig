const std = @import("std");
const thermite = @import("thermite");

// ============================================================================
// Shape-Based ASCII Renderer
// Based on: https://alexharri.com/blog/ascii-rendering
// ============================================================================

/// 6D shape vector - represents how much "ink" is in each region of a character
/// Regions are arranged:
///   [0] [1]
///   [2] [3]
///   [4] [5]
const ShapeVector = struct {
    v: [6]f32,

    fn zero() ShapeVector {
        return .{ .v = .{ 0, 0, 0, 0, 0, 0 } };
    }

    fn distance(self: ShapeVector, other: ShapeVector) f32 {
        var sum: f32 = 0;
        for (0..6) |i| {
            const d = self.v[i] - other.v[i];
            sum += d * d;
        }
        return @sqrt(sum);
    }

    fn normalize(self: *ShapeVector) void {
        var max_val: f32 = 0.0001; // Avoid div by zero
        for (self.v) |val| {
            if (val > max_val) max_val = val;
        }
        for (&self.v) |*val| {
            val.* /= max_val;
        }
    }

    fn applyContrast(self: *ShapeVector, exponent: f32) void {
        var max_val: f32 = 0.0001;
        for (self.v) |val| {
            if (val > max_val) max_val = val;
        }
        for (&self.v) |*val| {
            const normalized = val.* / max_val;
            val.* = std.math.pow(f32, normalized, exponent) * max_val;
        }
    }
};

/// A character and its precomputed shape vector
const CharShape = struct {
    char: []const u8, // UTF-8 encoded character
    shape: ShapeVector,
};

/// Character sets for different rendering styles
const CharacterSet = struct {
    name: []const u8,
    chars: []const CharShape,
};

// Precomputed shape vectors for ASCII line-drawing characters
// These are manually tuned for line rendering (edges, not filled shapes)
const ascii_line_chars = [_]CharShape{
    // Empty/light
    .{ .char = " ", .shape = .{ .v = .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 } } },
    .{ .char = ".", .shape = .{ .v = .{ 0.0, 0.0, 0.0, 0.0, 0.3, 0.3 } } },
    .{ .char = "'", .shape = .{ .v = .{ 0.3, 0.3, 0.0, 0.0, 0.0, 0.0 } } },
    .{ .char = "`", .shape = .{ .v = .{ 0.4, 0.0, 0.0, 0.0, 0.0, 0.0 } } },

    // Horizontal
    .{ .char = "-", .shape = .{ .v = .{ 0.0, 0.0, 0.8, 0.8, 0.0, 0.0 } } },
    .{ .char = "=", .shape = .{ .v = .{ 0.3, 0.3, 0.8, 0.8, 0.3, 0.3 } } },
    .{ .char = "_", .shape = .{ .v = .{ 0.0, 0.0, 0.0, 0.0, 0.9, 0.9 } } },

    // Vertical
    .{ .char = "|", .shape = .{ .v = .{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 } } },
    .{ .char = "!", .shape = .{ .v = .{ 0.5, 0.5, 0.5, 0.5, 0.0, 0.3 } } },
    .{ .char = ":", .shape = .{ .v = .{ 0.3, 0.3, 0.0, 0.0, 0.3, 0.3 } } },

    // Diagonals
    .{ .char = "/", .shape = .{ .v = .{ 0.0, 0.5, 0.3, 0.3, 0.5, 0.0 } } },
    .{ .char = "\\", .shape = .{ .v = .{ 0.5, 0.0, 0.3, 0.3, 0.0, 0.5 } } },

    // Corners and joints
    .{ .char = "+", .shape = .{ .v = .{ 0.3, 0.3, 0.8, 0.8, 0.3, 0.3 } } },
    .{ .char = "L", .shape = .{ .v = .{ 0.5, 0.0, 0.5, 0.0, 0.5, 0.5 } } },
    .{ .char = "J", .shape = .{ .v = .{ 0.0, 0.5, 0.0, 0.5, 0.5, 0.5 } } },
    .{ .char = "r", .shape = .{ .v = .{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.0 } } },
    .{ .char = "7", .shape = .{ .v = .{ 0.5, 0.5, 0.0, 0.5, 0.0, 0.5 } } },

    // Dense/filled
    .{ .char = "#", .shape = .{ .v = .{ 0.7, 0.7, 0.7, 0.7, 0.7, 0.7 } } },
    .{ .char = "@", .shape = .{ .v = .{ 0.8, 0.8, 0.8, 0.8, 0.8, 0.8 } } },
    .{ .char = "*", .shape = .{ .v = .{ 0.4, 0.4, 0.6, 0.6, 0.4, 0.4 } } },
    .{ .char = "o", .shape = .{ .v = .{ 0.3, 0.3, 0.5, 0.5, 0.3, 0.3 } } },
    .{ .char = "O", .shape = .{ .v = .{ 0.5, 0.5, 0.6, 0.6, 0.5, 0.5 } } },
};

// Unicode box-drawing characters with shape vectors
const unicode_box_chars = [_]CharShape{
    // Light box drawing
    .{ .char = "─", .shape = .{ .v = .{ 0.0, 0.0, 1.0, 1.0, 0.0, 0.0 } } },
    .{ .char = "│", .shape = .{ .v = .{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 } } },
    .{ .char = "┌", .shape = .{ .v = .{ 0.0, 0.0, 0.5, 1.0, 0.5, 0.0 } } },
    .{ .char = "┐", .shape = .{ .v = .{ 0.0, 0.0, 1.0, 0.5, 0.0, 0.5 } } },
    .{ .char = "└", .shape = .{ .v = .{ 0.5, 0.0, 0.5, 1.0, 0.0, 0.0 } } },
    .{ .char = "┘", .shape = .{ .v = .{ 0.0, 0.5, 1.0, 0.5, 0.0, 0.0 } } },
    .{ .char = "├", .shape = .{ .v = .{ 0.5, 0.0, 0.5, 1.0, 0.5, 0.0 } } },
    .{ .char = "┤", .shape = .{ .v = .{ 0.0, 0.5, 1.0, 0.5, 0.0, 0.5 } } },
    .{ .char = "┬", .shape = .{ .v = .{ 0.0, 0.0, 1.0, 1.0, 0.5, 0.5 } } },
    .{ .char = "┴", .shape = .{ .v = .{ 0.5, 0.5, 1.0, 1.0, 0.0, 0.0 } } },
    .{ .char = "┼", .shape = .{ .v = .{ 0.5, 0.5, 1.0, 1.0, 0.5, 0.5 } } },

    // Diagonal lines (if terminal supports)
    .{ .char = "╱", .shape = .{ .v = .{ 0.0, 0.8, 0.4, 0.4, 0.8, 0.0 } } },
    .{ .char = "╲", .shape = .{ .v = .{ 0.8, 0.0, 0.4, 0.4, 0.0, 0.8 } } },
    .{ .char = "╳", .shape = .{ .v = .{ 0.6, 0.6, 0.6, 0.6, 0.6, 0.6 } } },
};

// Block elements for denser rendering
const unicode_block_chars = [_]CharShape{
    .{ .char = " ", .shape = .{ .v = .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 } } },
    .{ .char = "░", .shape = .{ .v = .{ 0.25, 0.25, 0.25, 0.25, 0.25, 0.25 } } },
    .{ .char = "▒", .shape = .{ .v = .{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 } } },
    .{ .char = "▓", .shape = .{ .v = .{ 0.75, 0.75, 0.75, 0.75, 0.75, 0.75 } } },
    .{ .char = "█", .shape = .{ .v = .{ 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 } } },
    .{ .char = "▀", .shape = .{ .v = .{ 1.0, 1.0, 0.5, 0.5, 0.0, 0.0 } } },
    .{ .char = "▄", .shape = .{ .v = .{ 0.0, 0.0, 0.5, 0.5, 1.0, 1.0 } } },
    .{ .char = "▌", .shape = .{ .v = .{ 1.0, 0.0, 1.0, 0.0, 1.0, 0.0 } } },
    .{ .char = "▐", .shape = .{ .v = .{ 0.0, 1.0, 0.0, 1.0, 0.0, 1.0 } } },
    .{ .char = "▖", .shape = .{ .v = .{ 0.0, 0.0, 0.0, 0.0, 1.0, 0.0 } } },
    .{ .char = "▗", .shape = .{ .v = .{ 0.0, 0.0, 0.0, 0.0, 0.0, 1.0 } } },
    .{ .char = "▘", .shape = .{ .v = .{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0 } } },
    .{ .char = "▝", .shape = .{ .v = .{ 0.0, 1.0, 0.0, 0.0, 0.0, 0.0 } } },
};

// ============================================================================
// Render Buffer with Shape Sampling
// ============================================================================

const RenderBuffer = struct {
    // High-resolution buffer for line rasterization
    pixels: []f32,
    width: usize,
    height: usize,
    // Character cell dimensions
    cell_width: usize,
    cell_height: usize,
    // Output dimensions in characters
    char_width: usize,
    char_height: usize,

    allocator: std.mem.Allocator,

    const SUPERSAMPLE: usize = 4; // 4x4 supersampling per character cell

    fn init(allocator: std.mem.Allocator, char_width: usize, char_height: usize) !RenderBuffer {
        const cell_width = SUPERSAMPLE;
        const cell_height = SUPERSAMPLE * 2; // Characters are ~2:1 aspect ratio
        const pixel_width = char_width * cell_width;
        const pixel_height = char_height * cell_height;

        const pixels = try allocator.alloc(f32, pixel_width * pixel_height);
        @memset(pixels, 0);

        return .{
            .pixels = pixels,
            .width = pixel_width,
            .height = pixel_height,
            .cell_width = cell_width,
            .cell_height = cell_height,
            .char_width = char_width,
            .char_height = char_height,
            .allocator = allocator,
        };
    }

    fn deinit(self: *RenderBuffer) void {
        self.allocator.free(self.pixels);
    }

    fn clear(self: *RenderBuffer) void {
        @memset(self.pixels, 0);
    }

    fn setPixel(self: *RenderBuffer, x: isize, y: isize, value: f32) void {
        if (x < 0 or y < 0) return;
        const ux: usize = @intCast(x);
        const uy: usize = @intCast(y);
        if (ux >= self.width or uy >= self.height) return;
        const idx = uy * self.width + ux;
        self.pixels[idx] = @max(self.pixels[idx], value);
    }

    fn getPixel(self: *const RenderBuffer, x: usize, y: usize) f32 {
        if (x >= self.width or y >= self.height) return 0;
        return self.pixels[y * self.width + x];
    }

    /// Draw an anti-aliased line using Xiaolin Wu's algorithm
    fn drawLine(self: *RenderBuffer, x0: f32, y0: f32, x1: f32, y1: f32) void {
        var xa = x0;
        var ya = y0;
        var xb = x1;
        var yb = y1;

        const steep = @abs(yb - ya) > @abs(xb - xa);

        if (steep) {
            std.mem.swap(f32, &xa, &ya);
            std.mem.swap(f32, &xb, &yb);
        }

        if (xa > xb) {
            std.mem.swap(f32, &xa, &xb);
            std.mem.swap(f32, &ya, &yb);
        }

        const dx = xb - xa;
        const dy = yb - ya;
        const gradient = if (dx < 0.0001) 1.0 else dy / dx;

        // First endpoint
        var xend = @round(xa);
        var yend = ya + gradient * (xend - xa);
        var xgap = 1.0 - (xa + 0.5 - @floor(xa + 0.5));
        const xpxl1: isize = @intFromFloat(xend);
        const ypxl1: isize = @intFromFloat(@floor(yend));

        if (steep) {
            self.setPixel(ypxl1, xpxl1, (1.0 - (yend - @floor(yend))) * xgap);
            self.setPixel(ypxl1 + 1, xpxl1, (yend - @floor(yend)) * xgap);
        } else {
            self.setPixel(xpxl1, ypxl1, (1.0 - (yend - @floor(yend))) * xgap);
            self.setPixel(xpxl1, ypxl1 + 1, (yend - @floor(yend)) * xgap);
        }

        var intery = yend + gradient;

        // Second endpoint
        xend = @round(xb);
        yend = yb + gradient * (xend - xb);
        xgap = xa + 0.5 - @floor(xa + 0.5);
        const xpxl2: isize = @intFromFloat(xend);
        const ypxl2: isize = @intFromFloat(@floor(yend));

        if (steep) {
            self.setPixel(ypxl2, xpxl2, (1.0 - (yend - @floor(yend))) * xgap);
            self.setPixel(ypxl2 + 1, xpxl2, (yend - @floor(yend)) * xgap);
        } else {
            self.setPixel(xpxl2, ypxl2, (1.0 - (yend - @floor(yend))) * xgap);
            self.setPixel(xpxl2, ypxl2 + 1, (yend - @floor(yend)) * xgap);
        }

        // Main loop
        var x = xpxl1 + 1;
        while (x < xpxl2) : (x += 1) {
            const iy: isize = @intFromFloat(@floor(intery));
            const frac = intery - @floor(intery);

            if (steep) {
                self.setPixel(iy, x, 1.0 - frac);
                self.setPixel(iy + 1, x, frac);
            } else {
                self.setPixel(x, iy, 1.0 - frac);
                self.setPixel(x, iy + 1, frac);
            }
            intery += gradient;
        }
    }

    /// Sample a cell and compute its 6D shape vector
    fn sampleCell(self: *const RenderBuffer, cx: usize, cy: usize) ShapeVector {
        var shape = ShapeVector.zero();

        const base_x = cx * self.cell_width;
        const base_y = cy * self.cell_height;

        // Sample 6 regions (2 columns x 3 rows)
        const region_w = self.cell_width / 2;
        const region_h = self.cell_height / 3;

        for (0..3) |row| {
            for (0..2) |col| {
                var sum: f32 = 0;
                var count: f32 = 0;

                const rx = base_x + col * region_w;
                const ry = base_y + row * region_h;

                for (0..region_h) |dy| {
                    for (0..region_w) |dx| {
                        sum += self.getPixel(rx + dx, ry + dy);
                        count += 1;
                    }
                }

                const idx = row * 2 + col;
                shape.v[idx] = if (count > 0) sum / count else 0;
            }
        }

        return shape;
    }

    /// Find the best matching character for a shape vector
    fn findBestChar(shape: ShapeVector, charset: []const CharShape) []const u8 {
        var best_char: []const u8 = " ";
        var best_dist: f32 = std.math.inf(f32);

        for (charset) |cs| {
            const dist = shape.distance(cs.shape);
            if (dist < best_dist) {
                best_dist = dist;
                best_char = cs.char;
            }
        }

        return best_char;
    }
};

// ============================================================================
// 3D Math
// ============================================================================

const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    fn rotateX(self: Vec3, angle: f32) Vec3 {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ .x = self.x, .y = self.y * c - self.z * s, .z = self.y * s + self.z * c };
    }

    fn rotateY(self: Vec3, angle: f32) Vec3 {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ .x = self.x * c + self.z * s, .y = self.y, .z = -self.x * s + self.z * c };
    }

    fn rotateZ(self: Vec3, angle: f32) Vec3 {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ .x = self.x * c - self.y * s, .y = self.x * s + self.y * c, .z = self.z };
    }
};

fn project(v: Vec3, buf: *const RenderBuffer, zoom: f32) struct { x: f32, y: f32 } {
    const distance: f32 = 5.0;
    const z = v.z + distance;
    const scale = zoom / z;

    const w: f32 = @floatFromInt(buf.width);
    const h: f32 = @floatFromInt(buf.height);

    return .{
        .x = v.x * scale * h / 2.0 + w / 2.0,
        .y = v.y * scale * h / 2.0 + h / 2.0,
    };
}

// ============================================================================
// Cube/Hypercube Geometry
// ============================================================================

const cube_vertices = [8]Vec3{
    .{ .x = -1, .y = -1, .z = -1 }, .{ .x = 1, .y = -1, .z = -1 },
    .{ .x = 1, .y = 1, .z = -1 },   .{ .x = -1, .y = 1, .z = -1 },
    .{ .x = -1, .y = -1, .z = 1 },  .{ .x = 1, .y = -1, .z = 1 },
    .{ .x = 1, .y = 1, .z = 1 },    .{ .x = -1, .y = 1, .z = 1 },
};

const cube_edges = [12][2]u8{
    .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 }, // Front
    .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 4 }, // Back
    .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 }, // Connecting
};

// 4D Hypercube (Tesseract)
const Vec4 = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    fn rotateXY(self: Vec4, angle: f32) Vec4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ .x = self.x * c - self.y * s, .y = self.x * s + self.y * c, .z = self.z, .w = self.w };
    }

    fn rotateXZ(self: Vec4, angle: f32) Vec4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ .x = self.x * c - self.z * s, .y = self.y, .z = self.x * s + self.z * c, .w = self.w };
    }

    fn rotateXW(self: Vec4, angle: f32) Vec4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ .x = self.x * c - self.w * s, .y = self.y, .z = self.z, .w = self.x * s + self.w * c };
    }

    fn rotateYZ(self: Vec4, angle: f32) Vec4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ .x = self.x, .y = self.y * c - self.z * s, .z = self.y * s + self.z * c, .w = self.w };
    }

    fn rotateYW(self: Vec4, angle: f32) Vec4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ .x = self.x, .y = self.y * c - self.w * s, .z = self.z, .w = self.y * s + self.w * c };
    }

    fn rotateZW(self: Vec4, angle: f32) Vec4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ .x = self.x, .y = self.y, .z = self.z * c - self.w * s, .w = self.z * s + self.w * c };
    }

    fn projectTo3D(self: Vec4, distance: f32) Vec3 {
        const w = self.w + distance;
        const scale = distance / w;
        return .{ .x = self.x * scale, .y = self.y * scale, .z = self.z * scale };
    }
};

// Generate hypercube vertices
fn generateHypercubeVertices() [16]Vec4 {
    var verts: [16]Vec4 = undefined;
    for (0..16) |i| {
        verts[i] = .{
            .x = if (i & 1 != 0) 1.0 else -1.0,
            .y = if (i & 2 != 0) 1.0 else -1.0,
            .z = if (i & 4 != 0) 1.0 else -1.0,
            .w = if (i & 8 != 0) 1.0 else -1.0,
        };
    }
    return verts;
}

// Generate hypercube edges (vertices differing in exactly one coordinate)
fn generateHypercubeEdges() [32][2]u8 {
    var edges: [32][2]u8 = undefined;
    var idx: usize = 0;
    for (0..16) |i| {
        for (0..4) |bit| {
            const j = i ^ (@as(usize, 1) << @intCast(bit));
            if (j > i) {
                edges[idx] = .{ @intCast(i), @intCast(j) };
                idx += 1;
            }
        }
    }
    return edges;
}

const hypercube_vertices = generateHypercubeVertices();
const hypercube_edges = generateHypercubeEdges();

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Terminal setup
    const term_info = try thermite.terminal.getTerminalInfo();
    const fd = term_info.fd;
    const width: usize = term_info.width;
    const height: usize = term_info.height - 2; // Leave room for status

    try thermite.terminal.enterRawMode(fd);
    defer thermite.terminal.exitRawMode(fd) catch {};
    try thermite.terminal.hideCursor(fd);
    defer thermite.terminal.showCursor(fd) catch {};

    // Create render buffer
    var buffer = try RenderBuffer.init(allocator, width, height);
    defer buffer.deinit();

    // Output buffer
    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);

    // Character set selection (cycle with 'c')
    const charsets = [_]struct { name: []const u8, chars: []const CharShape }{
        .{ .name = "ASCII", .chars = &ascii_line_chars },
        .{ .name = "Unicode Box", .chars = &unicode_box_chars },
        .{ .name = "Unicode Block", .chars = &unicode_block_chars },
    };
    var charset_idx: usize = 0;

    // Render mode (cube vs hypercube, toggle with 'h')
    var show_hypercube = true;

    // Contrast (adjust with +/-)
    var contrast: f32 = 2.0;

    // Zoom (adjust with a/z)
    var zoom: f32 = 2.0;

    // Pause
    var paused = false;

    var angle: f32 = 0;
    var angle4d: f32 = 0;

    while (true) {
        // Input handling
        if (thermite.terminal.readKey(fd)) |key| {
            switch (key) {
                'q', 3 => break, // q or Ctrl+C
                'c' => charset_idx = (charset_idx + 1) % charsets.len,
                'h' => show_hypercube = !show_hypercube,
                '+', '=' => contrast = @min(5.0, contrast + 0.25),
                '-', '_' => contrast = @max(0.5, contrast - 0.25),
                'a' => zoom = @min(10.0, zoom * 1.2),
                'z' => zoom = @max(0.5, zoom / 1.2),
                ' ' => paused = !paused,
                else => {},
            }
        }

        // Clear buffer
        buffer.clear();

        // Draw geometry
        if (show_hypercube) {
            // Rotate in 4D and project
            for (hypercube_edges) |edge| {
                var v0 = hypercube_vertices[edge[0]];
                var v1 = hypercube_vertices[edge[1]];

                // 4D rotations
                v0 = v0.rotateXW(angle4d).rotateYZ(angle4d * 0.7).rotateZW(angle4d * 0.3);
                v1 = v1.rotateXW(angle4d).rotateYZ(angle4d * 0.7).rotateZW(angle4d * 0.3);

                // Project 4D -> 3D
                const v0_3d = v0.projectTo3D(3.0);
                const v1_3d = v1.projectTo3D(3.0);

                // 3D rotation
                const r0 = v0_3d.rotateY(angle * 0.5).rotateX(angle * 0.3);
                const r1 = v1_3d.rotateY(angle * 0.5).rotateX(angle * 0.3);

                // Project 3D -> 2D
                const p0 = project(r0, &buffer, zoom);
                const p1 = project(r1, &buffer, zoom);

                buffer.drawLine(p0.x, p0.y, p1.x, p1.y);
            }
        } else {
            // Simple cube
            for (cube_edges) |edge| {
                var v0 = cube_vertices[edge[0]];
                var v1 = cube_vertices[edge[1]];

                v0 = v0.rotateY(angle).rotateX(angle * 0.7).rotateZ(angle * 0.3);
                v1 = v1.rotateY(angle).rotateX(angle * 0.7).rotateZ(angle * 0.3);

                const p0 = project(v0, &buffer, zoom);
                const p1 = project(v1, &buffer, zoom);

                buffer.drawLine(p0.x, p0.y, p1.x, p1.y);
            }
        }

        // Render to characters
        output.clearRetainingCapacity();
        try output.appendSlice(allocator, "\x1b[H"); // Home

        const charset = charsets[charset_idx];

        for (0..buffer.char_height) |cy| {
            for (0..buffer.char_width) |cx| {
                var shape = buffer.sampleCell(cx, cy);
                shape.applyContrast(contrast);
                const char = RenderBuffer.findBestChar(shape, charset.chars);
                try output.appendSlice(allocator, char);
            }
            try output.appendSlice(allocator, "\r\n");
        }

        // Status line
        const mode = if (show_hypercube) "Hypercube" else "Cube";
        const status = try std.fmt.allocPrint(allocator, "\x1b[K[q]uit [c]harset:{s} [h]:{s} [+/-]contrast:{d:.1} [a/z]zoom:{d:.1}", .{ charset.name, mode, contrast, zoom });
        defer allocator.free(status);
        try output.appendSlice(allocator, status);

        _ = try std.posix.write(fd, output.items);

        // Update rotation
        if (!paused) {
            angle += 0.02;
            angle4d += 0.015;
        }

        std.Thread.sleep(25 * std.time.ns_per_ms);
    }

    try thermite.terminal.clearScreen(fd);
}
