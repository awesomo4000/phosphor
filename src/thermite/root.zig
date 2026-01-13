//! Terminal Pixels - A lightweight terminal renderer for pixel buffers
//! Designed for retro emulator backends using Unicode block characters
const std = @import("std");
const testing = std.testing;

pub const Cell = @import("cell.zig").Cell;
pub const DEFAULT_COLOR = @import("cell.zig").DEFAULT_COLOR;
pub const Plane = @import("plane.zig").Plane;
pub const Renderer = @import("renderer.zig").Renderer;
pub const blocks = @import("blocks.zig");
pub const terminal = @import("terminal.zig");
pub const Sprite = @import("sprite.zig").Sprite;

// Re-export the main API
pub const TerminalPixels = @import("api.zig").TerminalPixels;

test {
    std.testing.refAllDecls(@This());
    _ = @import("mock_terminal.zig");
    _ = @import("test_render.zig");
    _ = @import("test_stray_char.zig");
}