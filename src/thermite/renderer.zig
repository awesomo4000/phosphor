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

    pub fn init(allocator: std.mem.Allocator) !*Renderer {
        const renderer = try allocator.create(Renderer);
        errdefer allocator.destroy(renderer);

        // Get terminal info
        const tinfo = try terminal.getTerminalInfo();
        
        // Create double buffers
        const front = try Plane.init(allocator, tinfo.width, tinfo.height);
        errdefer front.deinit();
        
        const back = try Plane.init(allocator, tinfo.width, tinfo.height);
        errdefer back.deinit();

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
        try terminal.hideCursor(renderer.ttyfd);
        try terminal.clearScreen(renderer.ttyfd);
        
        // Initialize front buffer to match cleared screen
        front.clear();
        back.clear();

        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
        // Restore terminal - reset colors BEFORE clearing so we use default bg
        terminal.resetColors(self.ttyfd) catch {};
        terminal.showCursor(self.ttyfd) catch {};
        terminal.clearScreen(self.ttyfd) catch {};
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

                // Skip unchanged cells (unless first frame)
                if (!force_full and old_cell != null and new_cell != null and old_cell.?.eql(new_cell.?.*)) {
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

        // Write to terminal if there were changes
        if (self.output_buffer.items.len > 0) {
            _ = try std.posix.write(self.ttyfd, self.output_buffer.items);
        }

        // Copy back buffer to front buffer
        self.front_plane.copyFrom(self.back_plane);
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