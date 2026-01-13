const std = @import("std");

/// Sprite structure for terminal pixel rendering
pub const Sprite = struct {
    width: u32,
    height: u32,
    pixels: []u32,  // RGBA format 0xRRGGBBAA
    allocator: std.mem.Allocator,

    /// Create a new sprite from pixel data
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, pixels: []const u32) !*Sprite {
        const sprite = try allocator.create(Sprite);
        errdefer allocator.destroy(sprite);

        const pixel_copy = try allocator.alloc(u32, pixels.len);
        errdefer allocator.free(pixel_copy);
        @memcpy(pixel_copy, pixels);

        sprite.* = .{
            .width = width,
            .height = height,
            .pixels = pixel_copy,
            .allocator = allocator,
        };

        return sprite;
    }

    /// Create an empty sprite
    pub fn initEmpty(allocator: std.mem.Allocator, width: u32, height: u32) !*Sprite {
        const sprite = try allocator.create(Sprite);
        errdefer allocator.destroy(sprite);

        const pixels = try allocator.alloc(u32, width * height);
        errdefer allocator.free(pixels);

        // Initialize to transparent
        @memset(pixels, 0x00000000);

        sprite.* = .{
            .width = width,
            .height = height,
            .pixels = pixels,
            .allocator = allocator,
        };

        return sprite;
    }

    pub fn deinit(self: *Sprite) void {
        self.allocator.free(self.pixels);
        self.allocator.destroy(self);
    }

    /// Get pixel at x,y (returns null if out of bounds)
    pub fn getPixel(self: *const Sprite, x: u32, y: u32) ?u32 {
        if (x >= self.width or y >= self.height) return null;
        return self.pixels[y * self.width + x];
    }

    /// Set pixel at x,y
    pub fn setPixel(self: *Sprite, x: u32, y: u32, color: u32) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[y * self.width + x] = color;
    }

    /// Fill the entire sprite with a color
    pub fn fill(self: *Sprite, color: u32) void {
        @memset(self.pixels, color);
    }

    /// Draw a rectangle
    pub fn drawRect(self: *Sprite, x: i32, y: i32, w: u32, h: u32, color: u32) void {
        const x_start = @max(0, x);
        const y_start = @max(0, y);
        const x_end = @min(self.width, @as(u32, @intCast(x + @as(i32, @intCast(w)))));
        const y_end = @min(self.height, @as(u32, @intCast(y + @as(i32, @intCast(h)))));

        for (@intCast(y_start)..@intCast(y_end)) |py| {
            for (@intCast(x_start)..@intCast(x_end)) |px| {
                self.setPixel(@intCast(px), @intCast(py), color);
            }
        }
    }

    /// Copy from another sprite with alpha blending
    pub fn blit(self: *Sprite, src: *const Sprite, dst_x: i32, dst_y: i32) void {
        
        for (0..src.height) |sy| {
            for (0..src.width) |sx| {
                const dx = dst_x + @as(i32, @intCast(sx));
                const dy = dst_y + @as(i32, @intCast(sy));
                
                if (dx < 0 or dy < 0) continue;
                if (dx >= self.width or dy >= self.height) continue;
                
                if (src.getPixel(@intCast(sx), @intCast(sy))) |src_pixel| {
                    const src_alpha = src_pixel & 0xFF;
                    if (src_alpha == 0) continue; // Fully transparent
                    
                    if (src_alpha == 0xFF) {
                        // Fully opaque - direct copy
                        self.setPixel(@intCast(dx), @intCast(dy), src_pixel);
                    } else {
                        // Alpha blend
                        if (self.getPixel(@intCast(dx), @intCast(dy))) |dst_pixel| {
                            const blended = alphaBlend(src_pixel, dst_pixel);
                            self.setPixel(@intCast(dx), @intCast(dy), blended);
                        }
                    }
                }
            }
        }
    }

    /// Flip sprite horizontally
    pub fn flipH(self: *Sprite) void {
        for (0..self.height) |y| {
            var x1: u32 = 0;
            var x2: u32 = self.width - 1;
            while (x1 < x2) : ({x1 += 1; x2 -= 1;}) {
                const idx1 = y * self.width + x1;
                const idx2 = y * self.width + x2;
                const temp = self.pixels[idx1];
                self.pixels[idx1] = self.pixels[idx2];
                self.pixels[idx2] = temp;
            }
        }
    }

    /// Flip sprite vertically
    pub fn flipV(self: *Sprite) void {
        var y1: u32 = 0;
        var y2: u32 = self.height - 1;
        while (y1 < y2) : ({y1 += 1; y2 -= 1;}) {
            for (0..self.width) |x| {
                const idx1 = y1 * self.width + x;
                const idx2 = y2 * self.width + x;
                const temp = self.pixels[idx1];
                self.pixels[idx1] = self.pixels[idx2];
                self.pixels[idx2] = temp;
            }
        }
    }
};

/// Alpha blend two RGBA colors
fn alphaBlend(src: u32, dst: u32) u32 {
    const src_a = @as(f32, @floatFromInt(src & 0xFF)) / 255.0;
    const dst_a = @as(f32, @floatFromInt(dst & 0xFF)) / 255.0;
    
    const src_r = @as(f32, @floatFromInt((src >> 24) & 0xFF));
    const src_g = @as(f32, @floatFromInt((src >> 16) & 0xFF));
    const src_b = @as(f32, @floatFromInt((src >> 8) & 0xFF));
    
    const dst_r = @as(f32, @floatFromInt((dst >> 24) & 0xFF));
    const dst_g = @as(f32, @floatFromInt((dst >> 16) & 0xFF));
    const dst_b = @as(f32, @floatFromInt((dst >> 8) & 0xFF));
    
    const out_a = src_a + dst_a * (1.0 - src_a);
    const out_r = (src_r * src_a + dst_r * dst_a * (1.0 - src_a)) / out_a;
    const out_g = (src_g * src_a + dst_g * dst_a * (1.0 - src_a)) / out_a;
    const out_b = (src_b * src_a + dst_b * dst_a * (1.0 - src_a)) / out_a;
    
    return (@as(u32, @intFromFloat(out_r)) << 24) |
           (@as(u32, @intFromFloat(out_g)) << 16) |
           (@as(u32, @intFromFloat(out_b)) << 8) |
           @as(u32, @intFromFloat(out_a * 255.0));
}

/// Create a simple test sprite (smiley face)
pub fn createTestSprite(allocator: std.mem.Allocator) !*Sprite {
    const sprite = try Sprite.initEmpty(allocator, 16, 16);
    
    // Yellow background
    sprite.fill(0xFFFF00FF);
    
    // Eyes (black)
    sprite.drawRect(4, 4, 2, 2, 0x000000FF);
    sprite.drawRect(10, 4, 2, 2, 0x000000FF);
    
    // Mouth (black arc - simplified as pixels)
    for (4..12) |x| {
        const y = 10 + @abs(@as(i32, @intCast(x)) - 7) / 2;
        sprite.setPixel(@intCast(x), @intCast(y), 0x000000FF);
    }
    
    return sprite;
}