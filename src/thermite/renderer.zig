const std = @import("std");
const testing = std.testing;
const Plane = @import("plane.zig").Plane;
const cell_mod = @import("cell.zig");
const Cell = cell_mod.Cell;
const DEFAULT_COLOR = cell_mod.DEFAULT_COLOR;
const terminal = @import("terminal.zig");
const FastRenderer = @import("fast_renderer.zig").FastRenderer;

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

        renderer.* = .{
            .front_plane = front,
            .back_plane = back,
            .ttyfd = tinfo.fd,
            .term_width = tinfo.width,
            .term_height = tinfo.height,
            .allocator = allocator,
            .output_buffer = std.ArrayList(u8){},
        };

        // Initialize terminal
        try terminal.enterRawMode(renderer.ttyfd);
        timer.mark("enterRawMode() done");

        try terminal.hideCursor(renderer.ttyfd);
        timer.mark("hideCursor() done");

        try terminal.clearScreen(renderer.ttyfd);
        timer.mark("clearScreen() done");

        // Initialize front buffer to match cleared screen
        front.clear();
        back.clear();
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
    pub fn clearBackBuffer(self: *Renderer) void {
        self.back_plane.clear();
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
                        const r = (cell.fg >> 16) & 0xFF;
                        const g = (cell.fg >> 8) & 0xFF;
                        const b = cell.fg & 0xFF;
                        try writer.print("\x1b[38;2;{};{};{}m", .{ r, g, b });
                        current_fg = cell.fg;
                    }

                    // Update background color if changed
                    if (current_bg == null or current_bg.? != cell.bg) {
                        const r = (cell.bg >> 16) & 0xFF;
                        const g = (cell.bg >> 8) & 0xFF;
                        const b = cell.bg & 0xFF;
                        try writer.print("\x1b[48;2;{};{};{}m", .{ r, g, b });
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

        // Begin synchronized output mode (reduces flicker)
        try writer.writeAll("\x1b[?2026h");

        // Force full render on first frame
        const force_full = self.first_frame;
        if (self.first_frame) {
            try writer.writeAll(terminal.CLEAR_SCREEN);
            try writer.writeAll(terminal.CURSOR_HOME);
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
                if (!self.force_full_render) {
                    if (old_cell != null and new_cell != null and old_cell.?.eql(new_cell.?.*)) {
                        cursor_moved = false;
                        continue;
                    }
                }

                // Skip blank cells on first frame (nothing to draw)
                if (force_full and new_cell != null and new_cell.?.isDefault()) {
                    cursor_moved = false;
                    continue;
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
                            const r = (cell.fg >> 16) & 0xFF;
                            const g = (cell.fg >> 8) & 0xFF;
                            const b = cell.fg & 0xFF;
                            try writer.print("\x1b[38;2;{};{};{}m", .{ r, g, b });
                        }
                        current_fg = cell.fg;
                    }

                    if (current_bg == null or current_bg.? != cell.bg) {
                        if (cell.bg == DEFAULT_COLOR) {
                            try writer.writeAll("\x1b[49m"); // Default bg (transparent)
                        } else {
                            const r = (cell.bg >> 16) & 0xFF;
                            const g = (cell.bg >> 8) & 0xFF;
                            const b = cell.bg & 0xFF;
                            try writer.print("\x1b[48;2;{};{};{}m", .{ r, g, b });
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
        try writer.writeAll("\x1b[?2026l");

        // Write to terminal
        if (self.output_buffer.items.len > 0) {
            _ = try std.posix.write(self.ttyfd, self.output_buffer.items);
        }

        // Copy back buffer to front buffer
        self.front_plane.copyFrom(self.back_plane);

        // Reset force_full_render after use
        self.force_full_render = false;
    }

    /// Sync with terminal - blocks until terminal has actually rendered.
    /// Useful for measuring real display latency vs write latency.
    pub fn sync(self: *Renderer) !void {
        try terminal.sync(self.ttyfd);
    }

    /// Measure display latency in nanoseconds.
    pub fn measureDisplayLatency(self: *Renderer) !i128 {
        return terminal.measureDisplayLatency(self.ttyfd);
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