const std = @import("std");
const Renderer = @import("renderer.zig").Renderer;
const terminal = @import("terminal.zig");
const capabilities = @import("capabilities.zig");

/// Render with optimizations: batch consecutive cells with same colors
pub fn renderOptimized(self: *Renderer) !void {
    self.output_buffer.clearRetainingCapacity();
    const writer = self.output_buffer.writer(self.allocator);

    const force_full = self.first_frame;

    // First frame setup
    if (self.first_frame) {
        // For terminals that don't handle alt screen well, fill entire screen with black
        if (self.caps.terminal == .apple_terminal or
            self.caps.terminal == .linux_console or
            self.caps.terminal == .unknown)
        {
            // Set black background, then fill screen with spaces
            try writer.writeAll("\x1b[0m\x1b[40m"); // Reset + black bg
            try writer.writeAll(terminal.CURSOR_HOME);
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

    // Use a temporary buffer to batch characters
    var char_buffer: [256]u8 = undefined;
    var char_count: usize = 0;

    for (0..self.term_height) |y| {
        var x: u32 = 0;
        var row_has_changes = force_full; // On first frame, process all rows

        // Check if this row has any changes (skip check on first frame)
        if (!force_full) {
            for (0..self.term_width) |check_x| {
                const old_cell = self.front_plane.getCell(@intCast(check_x), @intCast(y));
                const new_cell = self.back_plane.getCell(@intCast(check_x), @intCast(y));

                if (old_cell == null and new_cell != null) {
                    row_has_changes = true;
                    break;
                }
                if (old_cell != null and new_cell == null) {
                    row_has_changes = true;
                    break;
                }
                if (old_cell != null and new_cell != null and !old_cell.?.eql(new_cell.?.*)) {
                    row_has_changes = true;
                    break;
                }
            }
        }

        if (!row_has_changes) continue;
        
        // Process the row
        while (x < self.term_width) {
            const old_cell = self.front_plane.getCell(@intCast(x), @intCast(y));
            const new_cell = self.back_plane.getCell(@intCast(x), @intCast(y));

            // Skip unchanged cells (but not on first frame)
            if (!force_full and old_cell != null and new_cell != null and old_cell.?.eql(new_cell.?.*)) {
                x += 1;
                continue;
            }

            if (new_cell) |start_cell| {
                // Move cursor
                try writer.print("\x1b[{};{}H", .{ y + 1, x + 1 });

                // Batch cells with same colors
                const batch_fg = start_cell.fg;
                const batch_bg = start_cell.bg;
                char_count = 0;

                // Update colors if needed - use appropriate color mode
                if (current_fg == null or current_fg.? != batch_fg) {
                    try writeFgColor(writer, batch_fg, self.caps.color);
                    current_fg = batch_fg;
                }

                if (current_bg == null or current_bg.? != batch_bg) {
                    try writeBgColor(writer, batch_bg, self.caps.color);
                    current_bg = batch_bg;
                }

                // Collect all consecutive cells with same colors
                while (x < self.term_width) {
                    const check_old = self.front_plane.getCell(@intCast(x), @intCast(y));
                    const check_new = self.back_plane.getCell(@intCast(x), @intCast(y));

                    // Stop if unchanged (but not on first frame)
                    if (!force_full and check_old != null and check_new != null and check_old.?.eql(check_new.?.*)) break;
                    
                    // Stop if no cell or different colors
                    if (check_new == null) break;
                    if (check_new.?.fg != batch_fg or check_new.?.bg != batch_bg) break;
                    
                    // Add character to buffer
                    if (check_new.?.ch <= 0x7F) {
                        if (char_count < char_buffer.len) {
                            char_buffer[char_count] = @intCast(check_new.?.ch);
                            char_count += 1;
                        }
                    } else {
                        // For Unicode, write buffer and handle separately
                        if (char_count > 0) {
                            try writer.writeAll(char_buffer[0..char_count]);
                            char_count = 0;
                        }
                        var buf: [4]u8 = undefined;
                        const len = try std.unicode.utf8Encode(@intCast(check_new.?.ch), &buf);
                        try writer.writeAll(buf[0..len]);
                    }
                    
                    x += 1;
                }
                
                // Write any remaining buffered characters
                if (char_count > 0) {
                    try writer.writeAll(char_buffer[0..char_count]);
                }
            } else {
                x += 1;
            }
        }
    }

    // Write to terminal
    if (self.output_buffer.items.len > 0) {
        _ = try std.posix.write(self.ttyfd, self.output_buffer.items);
    }

    // Copy back buffer to front
    self.front_plane.copyFrom(self.back_plane);
}

/// Write foreground color using appropriate escape sequence for color tier
fn writeFgColor(writer: anytype, color: u32, color_tier: capabilities.Capabilities.ColorTier) !void {
    const r: u8 = @intCast((color >> 16) & 0xFF);
    const g: u8 = @intCast((color >> 8) & 0xFF);
    const b: u8 = @intCast(color & 0xFF);

    switch (color_tier) {
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

/// Write background color using appropriate escape sequence for color tier
fn writeBgColor(writer: anytype, color: u32, color_tier: capabilities.Capabilities.ColorTier) !void {
    const r: u8 = @intCast((color >> 16) & 0xFF);
    const g: u8 = @intCast((color >> 8) & 0xFF);
    const b: u8 = @intCast(color & 0xFF);

    switch (color_tier) {
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