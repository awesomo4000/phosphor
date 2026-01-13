const std = @import("std");

/// Ultra-fast pixel rendering using pre-computed escape sequences
pub const UltraFastRenderer = struct {
    width: u32,
    height: u32,
    ttyfd: i32,
    allocator: std.mem.Allocator,
    
    // Pre-allocated buffers
    output_buffer: []u8,
    buffer_pos: usize,
    
    // Lookup table for escape sequences
    fg_escape_cache: std.AutoHashMap(u32, []const u8),
    bg_escape_cache: std.AutoHashMap(u32, []const u8),
    
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, ttyfd: i32) !*UltraFastRenderer {
        const renderer = try allocator.create(UltraFastRenderer);
        errdefer allocator.destroy(renderer);
        
        // Pre-allocate a large buffer for output
        // Worst case: every cell has different colors
        // Per cell: cursor move (10) + fg color (20) + bg color (20) + char (4) = ~54 bytes
        const buffer_size = width * height * 64;
        const output_buffer = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(output_buffer);
        
        renderer.* = .{
            .width = width,
            .height = height,
            .ttyfd = ttyfd,
            .allocator = allocator,
            .output_buffer = output_buffer,
            .buffer_pos = 0,
            .fg_escape_cache = std.AutoHashMap(u32, []const u8).init(allocator),
            .bg_escape_cache = std.AutoHashMap(u32, []const u8).init(allocator),
        };
        
        return renderer;
    }
    
    pub fn deinit(self: *UltraFastRenderer) void {
        // Free cached escape sequences
        var fg_iter = self.fg_escape_cache.iterator();
        while (fg_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.fg_escape_cache.deinit();
        
        var bg_iter = self.bg_escape_cache.iterator();
        while (bg_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.bg_escape_cache.deinit();
        
        self.allocator.free(self.output_buffer);
        self.allocator.destroy(self);
    }
    
    fn writeBytes(self: *UltraFastRenderer, bytes: []const u8) void {
        if (self.buffer_pos + bytes.len > self.output_buffer.len) return;
        @memcpy(self.output_buffer[self.buffer_pos..][0..bytes.len], bytes);
        self.buffer_pos += bytes.len;
    }
    
    fn writeByte(self: *UltraFastRenderer, byte: u8) void {
        if (self.buffer_pos >= self.output_buffer.len) return;
        self.output_buffer[self.buffer_pos] = byte;
        self.buffer_pos += 1;
    }
    
    fn getFgEscape(self: *UltraFastRenderer, color: u32) ![]const u8 {
        if (self.fg_escape_cache.get(color)) |cached| {
            return cached;
        }
        
        const r = (color >> 16) & 0xFF;
        const g = (color >> 8) & 0xFF;
        const b = color & 0xFF;
        
        const escape = try std.fmt.allocPrint(self.allocator, "\x1b[38;2;{};{};{}m", .{ r, g, b });
        try self.fg_escape_cache.put(color, escape);
        return escape;
    }
    
    fn getBgEscape(self: *UltraFastRenderer, color: u32) ![]const u8 {
        if (self.bg_escape_cache.get(color)) |cached| {
            return cached;
        }
        
        const r = (color >> 16) & 0xFF;
        const g = (color >> 8) & 0xFF;
        const b = color & 0xFF;
        
        const escape = try std.fmt.allocPrint(self.allocator, "\x1b[48;2;{};{};{}m", .{ r, g, b });
        try self.bg_escape_cache.put(color, escape);
        return escape;
    }
    
    pub fn renderPixels(self: *UltraFastRenderer, pixels: []const u32, width: u32, height: u32) !void {
        self.buffer_pos = 0;
        
        // Clear screen and home cursor
        self.writeBytes("\x1b[2J\x1b[H");
        
        // Convert pixels to blocks
        const block_width = (width + 1) / 2;
        const block_height = (height + 1) / 2;
        
        var last_bg: u32 = 0xFFFFFFFF;
        
        for (0..block_height) |by| {
            if (by > 0) {
                self.writeByte('\n');
            }
            
            for (0..block_width) |bx| {
                // Get 2x2 pixel block
                const px = bx * 2;
                const py = by * 2;
                
                var block_pixels: [4]u32 = .{ 0, 0, 0, 0 };
                var count: u8 = 0;
                
                // Collect pixels
                if (py < height and px < width) {
                    block_pixels[0] = pixels[py * width + px];
                    count += 1;
                }
                if (py < height and px + 1 < width) {
                    block_pixels[1] = pixels[py * width + px + 1];
                    count += 1;
                }
                if (py + 1 < height and px < width) {
                    block_pixels[2] = pixels[(py + 1) * width + px];
                    count += 1;
                }
                if (py + 1 < height and px + 1 < width) {
                    block_pixels[3] = pixels[(py + 1) * width + px + 1];
                    count += 1;
                }
                
                if (count == 0) continue;
                
                // Fast path: all pixels same color
                const first = block_pixels[0] >> 8; // RGB only
                var all_same = true;
                for (1..count) |i| {
                    if ((block_pixels[i] >> 8) != first) {
                        all_same = false;
                        break;
                    }
                }
                
                if (all_same) {
                    // Just use a space with background color
                    const color = first;
                    if (color != last_bg) {
                        const escape = try self.getBgEscape(color);
                        self.writeBytes(escape);
                        last_bg = color;
                    }
                    self.writeByte(' ');
                } else {
                    // Simple approach: just use background color of most common pixel
                    var color_counts = std.AutoHashMap(u32, u8).init(self.allocator);
                    defer color_counts.deinit();
                    
                    for (0..count) |i| {
                        const rgb = block_pixels[i] >> 8;
                        const current = color_counts.get(rgb) orelse 0;
                        color_counts.put(rgb, current + 1) catch {};
                    }
                    
                    var best_color: u32 = block_pixels[0] >> 8;
                    var best_count: u8 = 0;
                    var iter = color_counts.iterator();
                    while (iter.next()) |entry| {
                        if (entry.value_ptr.* > best_count) {
                            best_count = entry.value_ptr.*;
                            best_color = entry.key_ptr.*;
                        }
                    }
                    
                    if (best_color != last_bg) {
                        const escape = try self.getBgEscape(best_color);
                        self.writeBytes(escape);
                        last_bg = best_color;
                    }
                    self.writeByte(' ');
                }
            }
        }
        
        // Single write to terminal
        _ = try std.posix.write(self.ttyfd, self.output_buffer[0..self.buffer_pos]);
    }
};