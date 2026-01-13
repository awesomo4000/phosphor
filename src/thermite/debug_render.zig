const std = @import("std");

pub fn main() !void {
    const tty_fd = try std.posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0);
    defer std.posix.close(tty_fd);
    
    // Get terminal size
    var winsize: std.posix.winsize = undefined;
    const TIOCGWINSZ = if (@import("builtin").os.tag == .macos) @as(c_ulong, 0x40087468) else std.os.linux.T.IOCGWINSZ;
    _ = std.c.ioctl(tty_fd, TIOCGWINSZ, @intFromPtr(&winsize));
    
    const term_width = winsize.col;
    const term_height = winsize.row;
    
    std.debug.print("Terminal: {}x{}\n", .{ term_width, term_height });
    std.debug.print("Press 1: Test simple fill\n", .{});
    std.debug.print("Press 2: Test pixel mapping (2x2 pixels per cell)\n", .{});
    std.debug.print("Press 3: Test moving box\n", .{});
    std.debug.print("Press q: Quit\n", .{});
    
    // Setup terminal
    _ = try std.posix.write(tty_fd, "\x1b[?25l"); // Hide cursor
    
    var buffer = std.ArrayList(u8).init(std.heap.page_allocator);
    defer buffer.deinit(allocator);
    
    while (true) {
        // Read key
        var key: [1]u8 = undefined;
        _ = try std.posix.read(tty_fd, &key);
        
        if (key[0] == 'q') break;
        
        switch (key[0]) {
            '1' => {
                // Test 1: Simple fill with solid color
                buffer.clearRetainingCapacity();
                const writer = buffer.writer();
                
                try writer.writeAll("\x1b[2J\x1b[H");
                try writer.writeAll("\x1b[48;2;255;0;0m"); // Red background
                
                for (0..term_height) |y| {
                    if (y > 0) try writer.writeByte('\n');
                    for (0..term_width) |_| {
                        try writer.writeByte(' ');
                    }
                }
                
                try writer.print("\x1b[H\x1b[38;2;255;255;255mTest 1: Should be solid red", .{});
                _ = try std.posix.write(tty_fd, buffer.items);
            },
            '2' => {
                // Test 2: Pixel mapping test
                buffer.clearRetainingCapacity();
                const writer = buffer.writer();
                
                try writer.writeAll("\x1b[2J\x1b[H");
                
                // Create a pattern where we alternate colors every cell
                for (0..term_height) |y| {
                    if (y > 0) try writer.writeByte('\n');
                    for (0..term_width) |x| {
                        const color = (x + y) % 2;
                        if (color == 0) {
                            try writer.writeAll("\x1b[48;2;255;0;0m"); // Red
                        } else {
                            try writer.writeAll("\x1b[48;2;0;0;255m"); // Blue
                        }
                        try writer.writeByte(' ');
                    }
                }
                
                try writer.print("\x1b[H\x1b[38;2;255;255;255mTest 2: Should be checkerboard", .{});
                _ = try std.posix.write(tty_fd, buffer.items);
            },
            '3' => {
                // Test 3: Moving box
                var frame: u32 = 0;
                while (frame < 100) : (frame += 1) {
                    buffer.clearRetainingCapacity();
                    const writer = buffer.writer();
                    
                    try writer.writeAll("\x1b[H"); // Home cursor
                    
                    // Background
                    try writer.writeAll("\x1b[48;2;0;50;0m"); // Dark green
                    
                    const box_x = frame % (term_width - 10);
                    const box_y = (frame / 2) % (term_height - 5);
                    
                    for (0..term_height) |y| {
                        if (y > 0) try writer.writeByte('\n');
                        for (0..term_width) |x| {
                            // Check if we're in the box
                            if (x >= box_x and x < box_x + 10 and
                                y >= box_y and y < box_y + 5) {
                                try writer.writeAll("\x1b[48;2;255;255;0m"); // Yellow
                                try writer.writeByte(' ');
                                try writer.writeAll("\x1b[48;2;0;50;0m"); // Back to green
                            } else {
                                try writer.writeByte(' ');
                            }
                        }
                    }
                    
                    try writer.print("\x1b[H\x1b[38;2;255;255;255mTest 3: Moving box frame {}", .{frame});
                    _ = try std.posix.write(tty_fd, buffer.items);
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                }
            },
            else => {},
        }
    }
    
    // Restore
    _ = try std.posix.write(tty_fd, "\x1b[2J\x1b[H\x1b[?25h\x1b[0m");
}