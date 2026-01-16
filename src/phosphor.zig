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
pub const ThermiteBackend = backend.ThermiteBackend;

// Runtime (event loop)
pub const runtime = @import("runtime.zig");
pub const Runtime = runtime.Runtime;
pub const Widget = runtime.Widget;

// Elm-style Application
pub const application = @import("application.zig");
pub const Application = application.Application;
pub const Sub = application.Sub;

// Effect system (Lustre-inspired)
pub const effect = @import("effect.zig");
pub const Effect = effect.Effect;

// Subscriptions
pub const subs_mod = @import("subs.zig");
pub const Subs = subs_mod.Subs;

// Layout system (flexbox-style)
pub const layout = @import("layout.zig");
pub const LayoutNode = layout.LayoutNode;
pub const Rect = layout.Rect;
pub const LayoutSize = layout.Size; // Widget size (w, h) - distinct from backend.Size (terminal size)
pub const Sizing = layout.Sizing;
pub const SizingAxis = layout.SizingAxis;
pub const Padding = layout.Padding;
pub const Direction = layout.Direction;
pub const WidgetVTable = layout.WidgetVTable;
pub const LocalWidgetVTable = layout.LocalWidgetVTable; // New: widgets draw at (0,0)
pub const renderTree = layout.renderTree;
pub const renderTreeWithPositions = layout.renderTreeWithPositions; // For Effect.after.set_cursor
pub const RenderResult = layout.RenderResult;
pub const WidgetPosition = layout.WidgetPosition;
pub const Text = layout.Text;
pub const LocalText = layout.LocalText; // New: example local widget
pub const Spacer = layout.Spacer;

// Terminal capabilities detection (re-exported from thermite)
const thermite_mod = @import("thermite");
pub const capabilities = thermite_mod.capabilities;
pub const Capabilities = thermite_mod.Capabilities;
pub const detectCapabilities = capabilities.detectFromEnv;

// Debug utilities
pub const startup_timer = @import("startup_timer");

// Version info
pub const version = "0.1.0";
