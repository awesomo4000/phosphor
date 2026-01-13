const std = @import("std");
const blocks = @import("blocks.zig");

/// Fast pixel renderer with damage tracking
pub const FastPixelRenderer = struct {
    width: u32,  // Terminal width in cells
    height: u32, // Terminal height in cells
    ttyfd: i32,
    allocator: std.mem.Allocator,
    
    // Cell-level buffers for damage tracking
    current_cells: []Cell,
    last_cells: []Cell,
    
    // Output buffer
    output_buffer: std.ArrayList(u8),
    
    // First frame flag
    first_frame: bool = true,
    
    const Cell = struct {
        ch: u32,   // Unicode character
        fg: u32,   // Foreground RGB
        bg: u32,   // Background RGB
        
        fn eql(a: Cell, b: Cell) bool {
            return a.ch == b.ch and a.fg == b.fg and a.bg == b.bg;
        }
    };
    
    pub fn init(allocator: std.mem.Allocator, ttyfd: i32) !*FastPixelRenderer {
        var winsize: std.posix.winsize = undefined;
        const TIOCGWINSZ = if (@import("builtin").os.tag == .macos) @as(c_ulong, 0x40087468) else std.os.linux.T.IOCGWINSZ;
        _ = std.c.ioctl(ttyfd, TIOCGWINSZ, @intFromPtr(&winsize));
        
        const width = winsize.col;
        const height = winsize.row;
        
        const renderer = try allocator.create(FastPixelRenderer);
        errdefer allocator.destroy(renderer);
        
        const cell_count = width * height;
        const current_cells = try allocator.alloc(Cell, cell_count);
        errdefer allocator.free(current_cells);
        @memset(current_cells, Cell{ .ch = ' ', .fg = 0xFFFFFF, .bg = 0x000000 });
        
        const last_cells = try allocator.alloc(Cell, cell_count);
        errdefer allocator.free(last_cells);
        @memset(last_cells, Cell{ .ch = 0, .fg = 0, .bg = 0 }); // Force first render
        
        renderer.* = .{
            .width = width,
            .height = height,
            .ttyfd = ttyfd,
            .allocator = allocator,
            .current_cells = current_cells,
            .last_cells = last_cells,
            .output_buffer = std.ArrayList(u8){},
        };
        
        return renderer;
    }
    
    pub fn deinit(self: *FastPixelRenderer) void {
        self.allocator.free(self.current_cells);
        self.allocator.free(self.last_cells);
        self.output_buffer.deinit(allocator);
        self.allocator.destroy(self);
    }
    
    /// Convert pixels to cells efficiently
    pub fn setPixels(self: *FastPixelRenderer, pixels: []const u32, pix_width: u32, pix_height: u32) !void {
        // Each cell represents 2x2 pixels
        const cell_width = @min(self.width, (pix_width + 1) / 2);
        const cell_height = @min(self.height, (pix_height + 1) / 2);
        
        // Convert pixels to cells
        for (0..cell_height) |cy| {
            for (0..cell_width) |cx| {
                const px = cx * 2;
                const py = cy * 2;
                
                var block_pixels: [4]u32 = .{ 0, 0, 0, 0 };
                var count: u8 = 0;
                
                // Collect 2x2 pixel block
                if (py < pix_height and px < pix_width) {
                    block_pixels[0] = pixels[py * pix_width + px];
                    count += 1;
                }
                if (py < pix_height and px + 1 < pix_width) {
                    block_pixels[1] = pixels[py * pix_width + px + 1];
                    count += 1;
                }
                if (py + 1 < pix_height and px < pix_width) {
                    block_pixels[2] = pixels[(py + 1) * pix_width + px];
                    count += 1;
                }
                if (py + 1 < pix_height and px + 1 < pix_width) {
                    block_pixels[3] = pixels[(py + 1) * pix_width + px + 1];
                    count += 1;
                }
                
                const idx = cy * self.width + cx;
                
                if (count == 0) {
                    self.current_cells[idx] = Cell{ .ch = ' ', .fg = 0xFFFFFF, .bg = 0x000000 };
                } else if (count == 4) {
                    // Use full block mapping
                    const block = blocks.pixelsToBlock(block_pixels);
                    self.current_cells[idx] = Cell{
                        .ch = block.ch,
                        .fg = block.fg,
                        .bg = block.bg,
                    };
                } else {
                    // Partial block - use average color
                    var r_sum: u32 = 0;
                    var g_sum: u32 = 0;
                    var b_sum: u32 = 0;
                    for (0..count) |i| {
                        const p = block_pixels[i] >> 8;
                        r_sum += (p >> 16) & 0xFF;
                        g_sum += (p >> 8) & 0xFF;
                        b_sum += p & 0xFF;
                    }
                    const avg_color = ((r_sum / count) << 16) | ((g_sum / count) << 8) | (b_sum / count);
                    self.current_cells[idx] = Cell{
                        .ch = ' ',
                        .fg = 0xFFFFFF,
                        .bg = avg_color,
                    };
                }
            }
        }
        
        // Clear any remaining cells
        for (cell_height..self.height) |y| {
            for (0..self.width) |x| {
                const idx = y * self.width + x;
                self.current_cells[idx] = Cell{ .ch = ' ', .fg = 0xFFFFFF, .bg = 0x000000 };
            }
        }
    }
    
    /// Render with damage tracking
    pub fn render(self: *FastPixelRenderer) !void {
        self.output_buffer.clearRetainingCapacity();
        const writer = self.output_buffer.writer();
        
        // Setup
        if (self.first_frame) {
            try writer.writeAll("\x1b[2J\x1b[H\x1b[?25l"); // Clear, home, hide cursor
            self.first_frame = false;
        }
        
        var last_fg: ?u32 = null;
        var last_bg: ?u32 = null;
        var cells_changed: u32 = 0;
        var cells_skipped: u32 = 0;
        
        // Process each row
        for (0..self.height) |y| {
            var x: u32 = 0;
            
            while (x < self.width) {
                const idx = y * self.width + x;
                const current = self.current_cells[idx];
                const last = self.last_cells[idx];
                
                // Skip unchanged cells
                if (current.eql(last)) {
                    cells_skipped += 1;
                    x += 1;
                    continue;
                }
                
                // Find run of changed cells with same attributes
                const start_x = x;
                const run_fg = current.fg;
                const run_bg = current.bg;
                var run_chars = std.ArrayList(u8).init(self.allocator);
                defer run_chars.deinit();
                
                while (x < self.width) : (x += 1) {
                    const check_idx = y * self.width + x;
                    const check_current = self.current_cells[check_idx];
                    const check_last = self.last_cells[check_idx];
                    
                    // Stop if unchanged
                    if (check_current.eql(check_last)) break;
                    
                    // Stop if different colors
                    if (check_current.fg != run_fg or check_current.bg != run_bg) break;
                    
                    // Add character
                    if (check_current.ch <= 0x7F) {
                        try run_chars.append(@intCast(check_current.ch));
                    } else {
                        var buf: [4]u8 = undefined;
                        const len = try std.unicode.utf8Encode(@intCast(check_current.ch), &buf);
                        try run_chars.appendSlice(buf[0..len]);
                    }
                    
                    cells_changed += 1;
                }
                
                // Render the run
                if (run_chars.items.len > 0) {
                    // Position cursor
                    try writer.print("\x1b[{};{}H", .{ y + 1, start_x + 1 });
                    
                    // Set colors if needed
                    if (last_fg == null or last_fg.? != run_fg) {
                        const r = (run_fg >> 16) & 0xFF;
                        const g = (run_fg >> 8) & 0xFF;
                        const b = run_fg & 0xFF;
                        try writer.print("\x1b[38;2;{};{};{}m", .{ r, g, b });
                        last_fg = run_fg;
                    }
                    
                    if (last_bg == null or last_bg.? != run_bg) {
                        const r = (run_bg >> 16) & 0xFF;
                        const g = (run_bg >> 8) & 0xFF;
                        const b = run_bg & 0xFF;
                        try writer.print("\x1b[48;2;{};{};{}m", .{ r, g, b });
                        last_bg = run_bg;
                    }
                    
                    // Write characters
                    try writer.writeAll(run_chars.items);
                }
            }
        }
        
        // Write to terminal if there were changes
        if (self.output_buffer.items.len > 0) {
            _ = try std.posix.write(self.ttyfd, self.output_buffer.items);
        }
        
        // Swap buffers
        std.mem.swap([]Cell, &self.current_cells, &self.last_cells);
        
        // Debug stats (optional)
        if (cells_changed > 0 or cells_skipped > 0) {
            const total = cells_changed + cells_skipped;
            const percent = @as(f32, @floatFromInt(cells_changed)) / @as(f32, @floatFromInt(total)) * 100.0;
            std.debug.print("Changed: {} ({:.1}%), Skipped: {}\n", .{ cells_changed, percent, cells_skipped });
        }
    }
};