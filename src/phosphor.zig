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

// Old runtime (event loop) - to be replaced
pub const runtime_old = @import("runtime.zig");
pub const RuntimeOld = runtime_old.Runtime;
pub const Widget = runtime_old.Widget;

// New runtime (queue-based architecture)
pub const runtime = @import("runtime/root.zig");

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
pub const JustifiedRow = layout.JustifiedRow; // Left/right text with right priority

// Widgets
pub const Separator = @import("widgets/separator.zig").Separator;

// Terminal capabilities detection (re-exported from thermite)
const thermite_mod = @import("thermite");
pub const capabilities = thermite_mod.capabilities;
pub const Capabilities = thermite_mod.Capabilities;
pub const detectCapabilities = capabilities.detectFromEnv;

// Unicode text utilities (display width calculation)
pub const unicode = @import("unicode");

/// Returns the display width of a string in terminal columns.
/// Handles grapheme clusters correctly (emoji ZWJ sequences, combining marks, CJK, etc.).
///
/// Examples:
///   unicodeWidth("Hello")        // 5
///   unicodeWidth("Hello 😊")     // 8  (emoji is width 2)
///   unicodeWidth("👨‍👩‍👧")           // 2  (family emoji ZWJ sequence)
///   unicodeWidth("你好")          // 4  (CJK, each char width 2)
///
/// Note: Automatically initialized by the runtime. If called before runtime init,
/// falls back to byte length (incorrect for non-ASCII, but won't crash).
pub const unicodeWidth = unicode.strWidth;

// Debug utilities
pub const startup_timer = @import("startup_timer");

// Version info
pub const version = "0.1.0";

test {
    // Pull in tests from submodules
    @import("std").testing.refAllDecls(@This());
    _ = runtime;
}
