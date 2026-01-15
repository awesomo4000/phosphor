//! Thermite - Low-level terminal rendering engine
//!
//! Provides two rendering modes:
//! - Cell mode: Direct character/color cell manipulation for text UIs
//! - Pixel mode: 2x2 pixel blocks using Unicode block characters for graphics
//!
//! Both modes use double-buffered differential rendering for optimal performance.
const std = @import("std");
const testing = std.testing;

// Core types
pub const Cell = @import("cell.zig").Cell;
pub const DEFAULT_COLOR = @import("cell.zig").DEFAULT_COLOR;
pub const Plane = @import("plane.zig").Plane;
pub const Renderer = @import("renderer.zig").Renderer;

// Utilities
pub const blocks = @import("blocks.zig");
pub const terminal = @import("terminal.zig");
pub const Sprite = @import("sprite.zig").Sprite;

test {
    std.testing.refAllDecls(@This());
    _ = @import("mock_terminal.zig");
    _ = @import("test_render.zig");
    _ = @import("test_stray_char.zig");
}