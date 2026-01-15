const std = @import("std");
const posix = std.posix;
const capabilities = @import("capabilities.zig");

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = posix.write(1, msg) catch {};
}

fn printRaw(s: []const u8) void {
    _ = posix.write(1, s) catch {};
}

pub fn main() void {
    const caps = capabilities.detectFromEnv();

    print("\n=== Phosphor Terminal Capabilities ===\n\n", .{});
    print("Detected terminal: {s}\n", .{@tagName(caps.terminal)});
    print("Color support:     {s}\n", .{@tagName(caps.color)});
    print("Sync output:       {}\n", .{caps.synchronized_output});
    print("Kitty keyboard:    {}\n", .{caps.kitty_keyboard});
    print("Kitty graphics:    {}\n", .{caps.kitty_graphics});
    print("Hyperlinks:        {}\n", .{caps.hyperlinks});

    print("\n--- Environment Variables ---\n", .{});
    print("TERM_PROGRAM: {s}\n", .{posix.getenv("TERM_PROGRAM") orelse "(not set)"});
    print("TERM:         {s}\n", .{posix.getenv("TERM") orelse "(not set)"});
    print("COLORTERM:    {s}\n", .{posix.getenv("COLORTERM") orelse "(not set)"});
    print("KITTY_WINDOW_ID: {s}\n", .{posix.getenv("KITTY_WINDOW_ID") orelse "(not set)"});
    print("WT_SESSION:   {s}\n", .{posix.getenv("WT_SESSION") orelse "(not set)"});

    print("\n--- Color Test ---\n", .{});
    print("Testing color output for detected mode ({s}):\n\n", .{@tagName(caps.color)});

    switch (caps.color) {
        .truecolor => {
            // True color test
            printRaw("  \x1b[48;2;255;0;0m RED \x1b[0m");
            printRaw("  \x1b[48;2;0;255;0m GRN \x1b[0m");
            printRaw("  \x1b[48;2;0;0;255m BLU \x1b[0m");
            printRaw("  \x1b[48;2;128;0;128m PUR \x1b[0m\n");
        },
        .@"256" => {
            // 256 color test
            printRaw("  \x1b[48;5;196m RED \x1b[0m"); // 196 = bright red
            printRaw("  \x1b[48;5;46m GRN \x1b[0m"); // 46 = bright green
            printRaw("  \x1b[48;5;21m BLU \x1b[0m"); // 21 = bright blue
            printRaw("  \x1b[48;5;129m PUR \x1b[0m\n"); // 129 = purple
        },
        .basic => {
            // Basic 8 color test
            printRaw("  \x1b[41m RED \x1b[0m");
            printRaw("  \x1b[42m GRN \x1b[0m");
            printRaw("  \x1b[44m BLU \x1b[0m");
            printRaw("  \x1b[45m MAG \x1b[0m\n");
        },
        .none => {
            printRaw("  (no color support detected)\n");
        },
    }

    print("\nIf colors look wrong, try: PHOSPHOR_COLOR=256 ./caps-check\n", .{});
    print("==========================================\n\n", .{});
}
