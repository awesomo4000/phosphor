const std = @import("std");
const Cell = @import("cell.zig").Cell;
const Plane = @import("plane.zig").Plane;
const terminal = @import("terminal.zig");

/// Optimized renderer using run-length encoding and batching
pub const FastRenderer = struct {
    front_plane: *Plane,
    back_plane: *Plane,
    ttyfd: i32,
    term_width: u32,
    term_height: u32,
    allocator: std.mem.Allocator,
    output_buffer: std.ArrayList(u8),
    first_frame: bool = true,
    
    // Optimization: track if entire regions are unchanged
    dirty_rows: []bool,
    
    const Run = struct {
        start_x: u32,
        end_x: u32,
        y: u32,
        fg: u32,
        bg: u32,
        cells: std.ArrayList(u32),
    };

    pub fn init(allocator: std.mem.Allocator, front: *Plane, back: *Plane, ttyfd: i32, width: u32, height: u32) !*FastRenderer {
        const renderer = try allocator.create(FastRenderer);
        errdefer allocator.destroy(renderer);
        
        const dirty_rows = try allocator.alloc(bool, height);
        errdefer allocator.free(dirty_rows);
        @memset(dirty_rows, true);

        renderer.* = .{
            .front_plane = front,
            .back_plane = back,
            .ttyfd = ttyfd,
            .term_width = width,
            .term_height = height,
            .allocator = allocator,
            .output_buffer = std.ArrayList(u8){},
            .dirty_rows = dirty_rows,
        };

        return renderer;
    }

    pub fn deinit(self: *FastRenderer) void {
        self.output_buffer.deinit(self.allocator);
        self.allocator.free(self.dirty_rows);
        self.allocator.destroy(self);
    }

    /// Check if a row has any changes
    fn isRowDirty(self: *FastRenderer, y: u32) bool {
        for (0..self.term_width) |x| {
            const old_cell = self.front_plane.getCell(@intCast(x), @intCast(y));
            const new_cell = self.back_plane.getCell(@intCast(x), @intCast(y));
            
            if (old_cell == null and new_cell == null) continue;
            if (old_cell == null or new_cell == null) return true;
            if (!old_cell.?.eql(new_cell.?.*)) return true;
        }
        return false;
    }

    /// Render using optimized batching
    pub fn render(self: *FastRenderer) !void {
        self.output_buffer.clearRetainingCapacity();
        const writer = self.output_buffer.writer();

        // First frame setup
        if (self.first_frame) {
            try writer.writeAll(terminal.CLEAR_SCREEN);
            try writer.writeAll(terminal.CURSOR_HOME);
            self.first_frame = false;
            @memset(self.dirty_rows, true);
        } else {
            // Check which rows are dirty
            for (0..self.term_height) |y| {
                self.dirty_rows[y] = self.isRowDirty(@intCast(y));
            }
        }

        var current_fg: ?u32 = null;
        var current_bg: ?u32 = null;
        var last_x: u32 = 0;
        var last_y: u32 = 0;

        // Process only dirty rows
        for (0..self.term_height) |y| {
            if (!self.dirty_rows[y]) continue;

            var x: u32 = 0;
            while (x < self.term_width) {
                const old_cell = self.front_plane.getCell(@intCast(x), @intCast(y));
                const new_cell = self.back_plane.getCell(@intCast(x), @intCast(y));

                // Skip unchanged cells
                if (old_cell != null and new_cell != null and old_cell.?.eql(new_cell.?.*)) {
                    x += 1;
                    continue;
                }

                if (new_cell) |cell| {
                    // Find run of cells with same colors
                    const run_fg = cell.fg;
                    const run_bg = cell.bg;
                    const run_start = x;
                    
                    var chars = std.ArrayList(u8).init(self.allocator);
                    defer chars.deinit();

                    // Collect consecutive cells with same colors
                    while (x < self.term_width) : (x += 1) {
                        const check_old = self.front_plane.getCell(@intCast(x), @intCast(y));
                        const check_new = self.back_plane.getCell(@intCast(x), @intCast(y));
                        
                        if (check_old != null and check_new != null and check_old.?.eql(check_new.?.*)) break;
                        if (check_new == null) break;
                        if (check_new.?.fg != run_fg or check_new.?.bg != run_bg) break;
                        
                        // Add character to run
                        if (check_new.?.ch <= 0x7F) {
                            try chars.append(@intCast(check_new.?.ch));
                        } else {
                            var buf: [4]u8 = undefined;
                            const len = try std.unicode.utf8Encode(@intCast(check_new.?.ch), &buf);
                            try chars.appendSlice(buf[0..len]);
                        }
                    }

                    // Emit the run
                    if (chars.items.len > 0) {
                        // Move cursor only if necessary
                        if (last_y != y or last_x != run_start) {
                            try writer.print("\x1b[{};{}H", .{ y + 1, run_start + 1 });
                        }

                        // Update colors only if changed
                        if (current_fg == null or current_fg.? != run_fg) {
                            const r = (run_fg >> 16) & 0xFF;
                            const g = (run_fg >> 8) & 0xFF;
                            const b = run_fg & 0xFF;
                            try writer.print("\x1b[38;2;{};{};{}m", .{ r, g, b });
                            current_fg = run_fg;
                        }

                        if (current_bg == null or current_bg.? != run_bg) {
                            const r = (run_bg >> 16) & 0xFF;
                            const g = (run_bg >> 8) & 0xFF;
                            const b = run_bg & 0xFF;
                            try writer.print("\x1b[48;2;{};{};{}m", .{ r, g, b });
                            current_bg = run_bg;
                        }

                        // Write all characters at once
                        try writer.writeAll(chars.items);
                        
                        last_x = x;
                        last_y = @intCast(y);
                    }
                } else {
                    x += 1;
                }
            }
        }

        // Write to terminal if there were changes
        if (self.output_buffer.items.len > 0) {
            _ = try std.posix.write(self.ttyfd, self.output_buffer.items);
        }

        // Copy back buffer to front
        self.front_plane.copyFrom(self.back_plane);
    }
};