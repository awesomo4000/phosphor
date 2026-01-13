/// Phosphor - High-performance terminal UI framework for Zig
///
/// Architecture:
///   - Phosphor: High-level TUI framework (widgets, layout, events)
///   - Thermite: Low-level pixel rendering (RGBA buffers → Unicode blocks)

// Core terminal UI
pub const tui = @import("tui.zig");
pub const TerminalState = @import("terminal_state.zig").TerminalState;

// Version info
pub const version = "0.1.0";

// TODO: Add back when ready:
// pub const app = @import("app.zig");
// pub const runtime = @import("runtime.zig");
// pub const thermite = @import("thermite");
