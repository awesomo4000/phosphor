/// Phosphor - High-performance terminal UI framework for Zig
///
/// Architecture:
///   - Phosphor: High-level TUI framework (widgets, layout, events)
///   - Thermite: Low-level pixel rendering (RGBA buffers → Unicode blocks)

// Core terminal UI
pub const tui = @import("tui.zig");
pub const TerminalState = @import("terminal_state.zig").TerminalState;

// Render command system (functional core)
pub const render_commands = @import("render_commands.zig");
pub const DrawCommand = render_commands.DrawCommand;
pub const Color = render_commands.Color;

// Backend abstraction (imperative shell)
pub const backend = @import("backend.zig");
pub const Backend = backend.Backend;
pub const Event = backend.Event;
pub const Key = backend.Key;
pub const Size = backend.Size;
pub const TerminalBackend = backend.TerminalBackend;
pub const MemoryBackend = backend.MemoryBackend;

// Runtime (event loop)
pub const runtime = @import("runtime.zig");
pub const Runtime = runtime.Runtime;
pub const Widget = runtime.Widget;

// Layout system (flexbox-style)
pub const layout = @import("layout.zig");
pub const LayoutNode = layout.LayoutNode;
pub const Rect = layout.Rect;
pub const Sizing = layout.Sizing;
pub const SizingAxis = layout.SizingAxis;
pub const Padding = layout.Padding;
pub const Direction = layout.Direction;
pub const WidgetVTable = layout.WidgetVTable;
pub const renderTree = layout.renderTree;

// Version info
pub const version = "0.1.0";
