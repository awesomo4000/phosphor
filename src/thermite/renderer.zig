const std = @import("std");
const testing = std.testing;
const Plane = @import("plane.zig").Plane;
const cell_mod = @import("cell.zig");
const Cell = cell_mod.Cell;
const DEFAULT_COLOR = cell_mod.DEFAULT_COLOR;
const terminal = @import("terminal.zig");
const FastRenderer = @import("fast_renderer.zig").FastRenderer;
const capabilities = @import("capabilities.zig");
const Capabilities = capabilities.Capabilities;

/// Double-buffered terminal renderer
pub const Renderer = struct {
    front_plane: *Plane,
    back_plane: *Plane,
    ttyfd: i32,
    term_width: u32,
    term_height: u32,
    allocator: std.mem.Allocator,
    /// Buffer for collecting output before writing
    output_buffer: std.ArrayList(u8),
    /// First frame flag to force full render
    first_frame: bool = true,
    /// Skip differential comparison - render every cell (set during resize)
    force_full_render: bool = false,
    /// Detected terminal capabilities
    caps: Capabilities = .{},

    pub fn init(allocator: std.mem.Allocator) !*Renderer {
        const timer = @import("startup_timer");
        timer.mark("Renderer.init() entry");

        const renderer = try allocator.create(Renderer);
        errdefer allocator.destroy(renderer);
        timer.mark("Renderer struct allocated");

        // Get terminal info
        const tinfo = try terminal.getTerminalInfo();
        timer.mark("getTerminalInfo() done");

        // Create double buffers
        const front = try Plane.init(allocator, tinfo.width, tinfo.height);
        errdefer front.deinit();
        timer.mark("front Plane.init() done");

        const back = try Plane.init(allocator, tinfo.width, tinfo.height);
        errdefer back.deinit();
        timer.mark("back Plane.init() done");

        // Detect terminal capabilities
        const caps = capabilities.detectFromEnv();
        timer.mark("capabilities detected");

        renderer.* = .{
            .front_plane = front,
            .back_plane = back,
            .ttyfd = tinfo.fd,
            .term_width = tinfo.width,
            .term_height = tinfo.height,
            .allocator = allocator,
            .output_buffer = std.ArrayList(u8){},
            .caps = caps,
        };

        // Initialize terminal
        try terminal.enterRawMode(renderer.ttyfd);
        timer.mark("enterRawMode() done");

        try terminal.hideCursor(renderer.ttyfd);
        timer.mark("hideCursor() done");

        try terminal.clearScreen(renderer.ttyfd);
        timer.mark("clearScreen() done");

        // Initialize buffers - use explicit black for terminals that don't handle transparent
        if (caps.terminal == .apple_terminal or
            caps.terminal == .linux_console or
            caps.terminal == .unknown)
        {
            front.clearWithBg(0x000000);
            back.clearWithBg(0x000000);
        } else {
            front.clear();
            back.clear();
        }
        timer.mark("buffers cleared");

        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
        // Restore terminal state
        terminal.resetColors(self.ttyfd) catch {};
        terminal.showCursor(self.ttyfd) catch {};
        // Move cursor to bottom of screen so user's terminal isn't cluttered
        // Don't clear screen - user may want to see what was displayed
        var buf: [32]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[{};1H\n", .{self.term_height}) catch "";
        _ = std.posix.write(self.ttyfd, seq) catch {};
        terminal.exitRawMode(self.ttyfd) catch {};

        self.front_plane.deinit();
        self.back_plane.deinit();
        self.output_buffer.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Swap the front and back buffers
    pub fn swapBuffers(self: *Renderer) void {
        const temp = self.front_plane;
        self.front_plane = self.back_plane;
        self.back_plane = temp;
    }

    /// Clear the back buffer
    /// For terminals that don't support transparent backgrounds (like Terminal.app),
    /// this clears to explicit black instead of DEFAULT_COLOR
    pub fn clearBackBuffer(self: *Renderer) void {
        // Terminal.app and some others don't handle transparent backgrounds well
        // Use explicit black for these terminals
        if (self.caps.terminal == .apple_terminal or
            self.caps.terminal == .linux_console or
            self.caps.terminal == .unknown)
        {
            self.back_plane.clearWithBg(0x000000); // Explicit black
        } else {
            self.back_plane.clear();
        }
    }

    /// Alias for clearBackBuffer (backwards compatibility with TerminalPixels API)
    pub const clear = clearBackBuffer;

    /// Write foreground color escape sequence based on terminal capabilities
    fn writeFgColor(self: *Renderer, writer: anytype, color: u32) !void {
        const r: u8 = @intCast((color >> 16) & 0xFF);
        const g: u8 = @intCast((color >> 8) & 0xFF);
        const b: u8 = @intCast(color & 0xFF);

        switch (self.caps.color) {
            .truecolor => try writer.print("\x1b[38;2;{};{};{}m", .{ r, g, b }),
            .@"256" => {
                const idx = capabilities.rgbTo256(r, g, b);
                try writer.print("\x1b[38;5;{}m", .{idx});
            },
            .basic => {
                const idx = capabilities.rgbToBasic(r, g, b);
                try writer.print("\x1b[{}m", .{30 + idx});
            },
            .none => {},
        }
    }

    /// Write background color escape sequence based on terminal capabilities
    fn writeBgColor(self: *Renderer, writer: anytype, color: u32) !void {
        const r: u8 = @intCast((color >> 16) & 0xFF);
        const g: u8 = @intCast((color >> 8) & 0xFF);
        const b: u8 = @intCast(color & 0xFF);

        switch (self.caps.color) {
            .truecolor => try writer.print("\x1b[48;2;{};{};{}m", .{ r, g, b }),
            .@"256" => {
                const idx = capabilities.rgbTo256(r, g, b);
                try writer.print("\x1b[48;5;{}m", .{idx});
            },
            .basic => {
                const idx = capabilities.rgbToBasic(r, g, b);
                try writer.print("\x1b[{}m", .{40 + idx});
            },
            .none => {},
        }
    }

    /// Render the back buffer to the terminal
    pub fn render(self: *Renderer) !void {
        self.output_buffer.clearRetainingCapacity();
        const writer = self.output_buffer.writer(self.allocator);

        // Move cursor to home
        try writer.writeAll(terminal.CURSOR_HOME);

        // Track current colors to minimize escape sequences
        var current_fg: ?u32 = null;
        var current_bg: ?u32 = null;

        // Render each cell
        for (0..self.term_height) |y| {
            if (y > 0) {
                try writer.writeByte('\n');
            }

            for (0..self.term_width) |x| {
                const old_cell = self.front_plane.getCell(@intCast(x), @intCast(y));
                const new_cell = self.back_plane.getCell(@intCast(x), @intCast(y));

                // Skip if unchanged
                if (old_cell != null and new_cell != null and old_cell.?.eql(new_cell.?.*)) {
                    // Move cursor forward only if we're not writing spaces
                    if (new_cell.?.ch != ' ') {
                        try writer.print("\x1b[C", .{});
                    } else {
                        // Write a space to ensure we clear any existing content
                        try writer.writeByte(' ');
                    }
                    continue;
                }

                if (new_cell) |cell| {
                    // Update foreground color if changed
                    if (current_fg == null or current_fg.? != cell.fg) {
                        try self.writeFgColor(writer, cell.fg);
                        current_fg = cell.fg;
                    }

                    // Update background color if changed
                    if (current_bg == null or current_bg.? != cell.bg) {
                        try self.writeBgColor(writer, cell.bg);
                        current_bg = cell.bg;
                    }

                    // Write the character
                    if (cell.ch <= 0x7F) {
                        try writer.writeByte(@intCast(cell.ch));
                    } else {
                        // UTF-8 encode
                        var buf: [4]u8 = undefined;
                        const len = try std.unicode.utf8Encode(@intCast(cell.ch), &buf);
                        try writer.writeAll(buf[0..len]);
                    }
                }
            }
        }

        // Reset colors at end
        try writer.writeAll(terminal.RESET_ALL);

        // Write to terminal
        _ = try std.posix.write(self.ttyfd, self.output_buffer.items);

        // Swap buffers
        self.swapBuffers();
    }

    /// Render only the differences between front and back buffers
    pub fn renderDifferential(self: *Renderer) !void {
        self.output_buffer.clearRetainingCapacity();
        const writer = self.output_buffer.writer(self.allocator);

        // Begin synchronized output mode (reduces flicker) - only if supported
        if (self.caps.synchronized_output) {
            try writer.writeAll("\x1b[?2026h");
        }

        // Force full render on first frame
        const force_full = self.first_frame;
        if (self.first_frame) {
            // For terminals that don't handle alt screen well, fill entire screen with black
            if (self.caps.terminal == .apple_terminal or
                self.caps.terminal == .linux_console or
                self.caps.terminal == .unknown)
            {
                // Set black background, then fill screen with spaces
                try writer.writeAll("\x1b[0m\x1b[40m"); // Reset + black bg
                try writer.writeAll(terminal.CURSOR_HOME);
                // Fill every cell with space (black bg)
                for (0..self.term_height) |_| {
                    for (0..self.term_width) |_| {
                        try writer.writeByte(' ');
                    }
                }
                try writer.writeAll(terminal.CURSOR_HOME);
            } else {
                try writer.writeAll(terminal.CLEAR_SCREEN);
                try writer.writeAll(terminal.CURSOR_HOME);
            }
            self.first_frame = false;
        }

        var current_fg: ?u32 = null;
        var current_bg: ?u32 = null;
        var cursor_moved = false;

        for (0..self.term_height) |y| {
            for (0..self.term_width) |x| {
                const old_cell = self.front_plane.getCell(@intCast(x), @intCast(y));
                const new_cell = self.back_plane.getCell(@intCast(x), @intCast(y));

                // Skip unchanged cells (unless forcing full render)
                // On first frame (force_full), render everything to clear screen garbage
                if (!self.force_full_render and !force_full) {
                    if (old_cell != null and new_cell != null and old_cell.?.eql(new_cell.?.*)) {
                        cursor_moved = false;
                        continue;
                    }
                }

                // Skip blank cells on first frame ONLY for terminals with proper alt screen
                // For Terminal.app and others, we need to render every cell explicitly
                if (force_full and new_cell != null and new_cell.?.isDefault()) {
                    // Only skip default cells if terminal properly supports transparent bg
                    if (self.caps.terminal != .apple_terminal and
                        self.caps.terminal != .linux_console and
                        self.caps.terminal != .unknown)
                    {
                        cursor_moved = false;
                        continue;
                    }
                }

                if (new_cell) |cell| {
                    // Move cursor if needed
                    if (!cursor_moved) {
                        try writer.print("\x1b[{};{}H", .{ y + 1, x + 1 });
                        cursor_moved = true;
                    }

                    // Update colors - use terminal defaults for DEFAULT_COLOR
                    if (current_fg == null or current_fg.? != cell.fg) {
                        if (cell.fg == DEFAULT_COLOR) {
                            try writer.writeAll("\x1b[39m"); // Default fg
                        } else {
                            try self.writeFgColor(writer, cell.fg);
                        }
                        current_fg = cell.fg;
                    }

                    if (current_bg == null or current_bg.? != cell.bg) {
                        if (cell.bg == DEFAULT_COLOR) {
                            try writer.writeAll("\x1b[49m"); // Default bg (transparent)
                        } else {
                            try self.writeBgColor(writer, cell.bg);
                        }
                        current_bg = cell.bg;
                    }

                    // Write character
                    if (cell.ch <= 0x7F) {
                        try writer.writeByte(@intCast(cell.ch));
                    } else {
                        var buf: [4]u8 = undefined;
                        const len = try std.unicode.utf8Encode(@intCast(cell.ch), &buf);
                        try writer.writeAll(buf[0..len]);
                    }
                }
            }
        }

        // End synchronized output mode (tells terminal to display the frame)
        if (self.caps.synchronized_output) {
            try writer.writeAll("\x1b[?2026l");
        }

        // Write to terminal
        if (self.output_buffer.items.len > 0) {
            _ = try std.posix.write(self.ttyfd, self.output_buffer.items);
        }

        // Copy back buffer to front buffer
        self.front_plane.copyFrom(self.back_plane);

        // Reset force_full_render after use
        self.force_full_render = false;
    }

    /// Alias for renderDifferential (backwards compatibility with TerminalPixels API)
    pub const present = renderDifferential;

    /// Sync with terminal - blocks until terminal has actually rendered.
    /// Useful for measuring real display latency vs write latency.
    pub fn sync(self: *Renderer) !void {
        try terminal.sync(self.ttyfd);
    }

    /// Measure display latency in nanoseconds.
    pub fn measureDisplayLatency(self: *Renderer) !i128 {
        return terminal.measureDisplayLatency(self.ttyfd);
    }

    // =========================================================================
    // Pixel rendering mode - for graphics/visualization applications
    // Each terminal cell represents a 2x2 pixel block using Unicode block chars
    // =========================================================================

    /// Set pixels from a buffer and convert to terminal cells.
    /// pixels: Array of RGBA values (0xRRGGBBAA format)
    /// This converts 2x2 pixel blocks to Unicode block characters.
    pub fn setPixels(self: *Renderer, pixels: []const u32, width: u32, height: u32) !void {
        const blocks = @import("blocks.zig");

        // Convert pixels to block characters
        const block_mappings = try blocks.pixelBufferToBlocks(
            pixels,
            width,
            height,
            self.allocator,
        );
        defer self.allocator.free(block_mappings);

        // Clear back buffer
        self.clearBackBuffer();

        // Calculate dimensions
        const block_width = (width + 1) / 2;
        const block_height = (height + 1) / 2;

        // Render blocks to back buffer
        for (0..block_height) |y| {
            for (0..block_width) |x| {
                if (x >= self.term_width or y >= self.term_height) continue;

                const block = block_mappings[y * block_width + x];
                self.back_plane.setCell(@intCast(x), @intCast(y), .{
                    .ch = block.ch,
                    .fg = block.fg,
                    .bg = block.bg,
                });
            }
        }
    }

    /// Render using optimized batching (faster for pixel graphics).
    /// Batches consecutive cells with same colors to reduce escape sequences.
    pub fn presentOptimized(self: *Renderer) !void {
        const renderOptimized = @import("optimized_renderer.zig").renderOptimized;
        try renderOptimized(self);
    }

    /// Get the maximum pixel resolution based on terminal size.
    /// Each character cell represents 2x2 pixels.
    pub fn maxPixelResolution(self: *const Renderer) struct { width: u32, height: u32 } {
        return .{
            .width = self.term_width * 2,
            .height = self.term_height * 2,
        };
    }

    /// Alias for maxPixelResolution (backwards compatibility)
    pub const maxResolution = maxPixelResolution;

    /// Check for pending resize, returns new pixel resolution if resized.
    /// Call this in your main loop to handle terminal resize events.
    pub fn checkResize(self: *Renderer) ?struct { width: u32, height: u32 } {
        if (terminal.checkResize(self.ttyfd)) |new_size| {
            // Resize the planes
            self.resize(new_size.width, new_size.height) catch return null;
            // Return new pixel resolution (2x terminal chars for block characters)
            return .{
                .width = new_size.width * 2,
                .height = new_size.height * 2,
            };
        }
        return null;
    }

    /// Get the terminal file descriptor for keyboard input.
    pub fn getTerminalFd(self: *const Renderer) i32 {
        return self.ttyfd;
    }

    /// Resize the renderer to a new terminal size.
    /// Reallocates both planes and forces a full render on next frame.
    pub fn resize(self: *Renderer, new_width: u32, new_height: u32) !void {
        // Skip if size unchanged
        if (new_width == self.term_width and new_height == self.term_height) return;

        // Create new planes first (may fail)
        const new_front = try Plane.init(self.allocator, new_width, new_height);
        errdefer new_front.deinit();

        const new_back = try Plane.init(self.allocator, new_width, new_height);
        errdefer new_back.deinit();

        // Free old planes
        self.front_plane.deinit();
        self.back_plane.deinit();

        // Swap in new planes
        self.front_plane = new_front;
        self.back_plane = new_back;
        self.term_width = new_width;
        self.term_height = new_height;

        // Clear both planes - use explicit black for terminals that don't handle transparent
        if (self.caps.terminal == .apple_terminal or
            self.caps.terminal == .linux_console or
            self.caps.terminal == .unknown)
        {
            new_front.clearWithBg(0x000000);
            new_back.clearWithBg(0x000000);
        } else {
            new_front.clear();
            new_back.clear();
        }

        // Force full render on next frame
        self.first_frame = true;
        self.force_full_render = true;

        // Clear screen to avoid artifacts
        try terminal.clearScreen(self.ttyfd);
    }
};

test "Renderer double buffering" {
    // This is a mock test since we can't actually test terminal I/O in unit tests
    const allocator = testing.allocator;
    
    // We'll test the buffer swapping logic
    const front = try Plane.init(allocator, 10, 10);
    defer front.deinit();
    
    const back = try Plane.init(allocator, 10, 10);
    defer back.deinit();

    // Mark the planes differently
    front.setCell(0, 0, Cell{ .ch = 'F', .fg = 0xFF0000, .bg = 0x000000 });
    back.setCell(0, 0, Cell{ .ch = 'B', .fg = 0x00FF00, .bg = 0x000000 });

    // Simulate swap
    const temp = front;
    const new_front = back;
    const new_back = temp;

    // Verify swap worked
    try testing.expect(new_front.getCell(0, 0).?.ch == 'B');
    try testing.expect(new_back.getCell(0, 0).?.ch == 'F');
}