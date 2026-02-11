// Runtime module - queue-based architecture for phosphor apps
//
// The runtime manages:
// - Message queue (MPSC)
// - Input thread (keyboard, mouse, resize)
// - Timer management (tick subscriptions)
// - The main loop: drain → update → view → render
//
// Designed for testability:
// - Inject messages directly via queue.pushSlice()
// - Mock time via RuntimeContext
// - Run without real terminal (headless mode)

pub const Queue = @import("queue.zig").Queue;

const runtime_mod = @import("runtime.zig");
pub const Runtime = runtime_mod.Runtime;
pub const Context = runtime_mod.Context;
pub const Size = runtime_mod.Size;
pub const Config = runtime_mod.Config;
pub const TimeSource = runtime_mod.TimeSource;
pub const Effect = runtime_mod.Effect;
pub const ViewResult = runtime_mod.ViewResult;

pub const input = @import("input.zig");
pub const Key = input.Key;
pub const InputSource = input.InputSource;
pub const TerminalInput = input.TerminalInput;

test {
    _ = @import("queue.zig");
    _ = @import("runtime.zig");
    _ = @import("input.zig");
    _ = @import("integration_test.zig");
}
