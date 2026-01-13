const std = @import("std");
const Renderer = @import("renderer.zig").Renderer;
const blocks = @import("blocks.zig");
const Cell = @import("cell.zig").Cell;

/// Main API for terminal pixel rendering
pub const TerminalPixels = struct {
    renderer: *Renderer,
    allocator: std.mem.Allocator,
    scale: f32 = 1.0,
    offset_x: i32 = 0,
    offset_y: i32 = 0,

    /// Initialize the terminal pixel renderer
    pub fn init(allocator: std.mem.Allocator) !*TerminalPixels {
        const tp = try allocator.create(TerminalPixels);
        errdefer allocator.destroy(tp);

        const renderer = try Renderer.init(allocator);
        errdefer renderer.deinit();

        tp.* = .{
            .renderer = renderer,
            .allocator = allocator,
        };

        return tp;
    }

    /// Clean up and restore terminal
    pub fn deinit(self: *TerminalPixels) void {
        self.renderer.deinit();
        self.allocator.destroy(self);
    }

    /// Set the pixel buffer to render
    /// pixels: Array of RGBA values (0xRRGGBBAA format)
    pub fn setPixels(self: *TerminalPixels, pixels: []const u32, width: u32, height: u32) !void {
        // Convert pixels to block characters
        const block_mappings = try blocks.pixelBufferToBlocks(
            pixels,
            width,
            height,
            self.allocator,
        );
        defer self.allocator.free(block_mappings);

        // Clear back buffer
        self.renderer.clearBackBuffer();

        // Calculate dimensions
        const block_width = (width + 1) / 2;
        const block_height = (height + 1) / 2;

        // Apply scale and offset
        const scaled_width = @as(u32, @intFromFloat(@as(f32, @floatFromInt(block_width)) * self.scale));
        const scaled_height = @as(u32, @intFromFloat(@as(f32, @floatFromInt(block_height)) * self.scale));

        // Render blocks to back buffer
        for (0..scaled_height) |y| {
            for (0..scaled_width) |x| {
                const render_x = @as(i32, @intCast(x)) + self.offset_x;
                const render_y = @as(i32, @intCast(y)) + self.offset_y;

                // Check bounds
                if (render_x < 0 or render_y < 0) continue;
                if (render_x >= self.renderer.term_width or render_y >= self.renderer.term_height) continue;

                // Map scaled coordinates back to block coordinates
                const block_x = @as(u32, @intFromFloat(@as(f32, @floatFromInt(x)) / self.scale));
                const block_y = @as(u32, @intFromFloat(@as(f32, @floatFromInt(y)) / self.scale));

                if (block_x >= block_width or block_y >= block_height) continue;

                const block = block_mappings[block_y * block_width + block_x];
                const cell = Cell{
                    .ch = block.ch,
                    .fg = block.fg,
                    .bg = block.bg,
                };

                self.renderer.back_plane.setCell(@intCast(render_x), @intCast(render_y), cell);
            }
        }
    }

    /// Render the current frame to the terminal
    pub fn present(self: *TerminalPixels) !void {
        try self.renderer.renderDifferential();
    }
    
    /// Render using optimized batching (faster)
    pub fn presentOptimized(self: *TerminalPixels) !void {
        const renderOptimized = @import("optimized_renderer.zig").renderOptimized;
        try renderOptimized(self.renderer);
    }
    
    /// Ultra simple rendering - just background colors, no Unicode blocks
    pub fn presentSimple(self: *TerminalPixels, pixels: []const u32, width: u32, height: u32) !void {
        const fixedSimpleRender = @import("fixed_simple_render.zig").fixedSimpleRender;
        const should_clear = self.renderer.first_frame;
        self.renderer.first_frame = false;
        try fixedSimpleRender(self.allocator, self.renderer.ttyfd, pixels, width, height, should_clear);
    }

    /// Clear the display
    pub fn clear(self: *TerminalPixels) void {
        self.renderer.clearBackBuffer();
    }

    /// Set the scaling factor (1.0 = normal, 2.0 = double size, etc)
    pub fn setScale(self: *TerminalPixels, scale: f32) void {
        self.scale = scale;
    }

    /// Set the position offset for rendering
    pub fn setPosition(self: *TerminalPixels, x: i32, y: i32) void {
        self.offset_x = x;
        self.offset_y = y;
    }

    /// Get the maximum resolution based on terminal size
    pub fn maxResolution(self: *const TerminalPixels) struct { width: u32, height: u32 } {
        // Each character represents 2x2 pixels
        return .{
            .width = self.renderer.term_width * 2,
            .height = self.renderer.term_height * 2,
        };
    }

    /// Check if terminal supports 24-bit color
    pub fn supports24BitColor(self: *const TerminalPixels) bool {
        _ = self;
        // For now, assume true. Could check COLORTERM env var
        return true;
    }

    /// Get the terminal file descriptor for keyboard input
    pub fn getTerminalFd(self: *const TerminalPixels) i32 {
        return self.renderer.ttyfd;
    }
};