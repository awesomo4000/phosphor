# Phosphor Architecture

## Overview

Phosphor uses an Elm-inspired architecture with a clear separation between pure and impure code:

- **Pure**: Widgets (state, update, view, subscriptions)
- **Impure**: Runtime (IO, timers, command handlers)

```
┌─────────────────────────────────────────────────────────────┐
│                         RUNTIME                             │
│                                                             │
│  ┌──────────┐    ┌──────────────┐    ┌──────────────────┐  │
│  │ Terminal │───▶│  Event Loop  │◀───│ Cmd Handlers     │  │
│  │ (input)  │    │              │    │ (registered)     │  │
│  └──────────┘    └──────┬───────┘    └──────────────────┘  │
│                         │                      ▲            │
│                         │ Msg                  │ Cmd        │
│                         ▼                      │            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                     WIDGETS                          │  │
│  │                                                      │  │
│  │   update(Msg) → { state changes, Cmd, AppMsg }      │  │
│  │   subscriptions() → [.keyboard, .tick_ms, ...]      │  │
│  │   view() → ?LayoutNode                               │  │
│  │                                                      │  │
│  └──────────────────────────────────────────────────────┘  │
│                         │                                   │
│                         │ LayoutNode tree                   │
│                         ▼                                   │
│  ┌──────────────────────────────────────────────────────┐  │
│  │   renderTree() → DrawCommands → Backend.execute()   │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Widget Interface

Widgets are mini Elm apps with four components:

```zig
const Widget = struct {
    // Internal state
    state: State,

    // Pure: handle messages, return commands
    pub fn update(self: *Widget, msg: Msg) UpdateResult {
        // Transform state, return effects
    }

    // Pure: declare what events we want
    pub fn subscriptions(self: *const Widget) []Sub {
        // Return based on current state
    }

    // Pure: describe what we look like
    pub fn view(self: *const Widget) ?LayoutNode {
        // Return layout tree, or null for invisible widgets
    }
};
```

### UpdateResult

```zig
const UpdateResult = struct {
    cmd: Cmd,           // Effect to perform (runtime handles)
    messages: []AppMsg, // Messages to parent/app
};
```

### Invisible Widgets

Widgets can return `null` from `view()` to be invisible. Useful for:

- Global hotkey handlers
- Auto-save timers
- Background tasks
- Idle detection

```zig
const HotkeyHandler = struct {
    pub fn update(self: *HotkeyHandler, msg: Msg) UpdateResult {
        switch (msg) {
            .key => |k| switch (k) {
                .ctrl_s => return .{ .cmd = .save_file },
                .ctrl_q => return .{ .cmd = .quit },
                else => return .{},
            },
            else => return .{},
        }
    }

    pub fn subscriptions(self: *const HotkeyHandler) []Sub {
        return &.{ .keyboard };
    }

    pub fn view(self: *const HotkeyHandler) ?LayoutNode {
        return null;  // No visual representation
    }
};
```

## Subscriptions

Widgets declare what events they want. Runtime only sends relevant events.

```zig
const Sub = union(enum) {
    keyboard,        // Key events
    tick_ms: u32,    // Timer ticks at interval
    focus,           // Focus gained/lost notifications
};
```

### Dynamic Subscriptions

Subscriptions are a function of state - they change as state changes:

```zig
pub fn subscriptions(self: *const TextInput) []Sub {
    if (self.focused) {
        // When focused: want keys and cursor blink
        return &.{ .keyboard, .focus, .{ .tick_ms = 530 } };
    } else {
        // When not focused: just want to know when we get focus
        return &.{ .focus };
    }
}
```

### Focus via Subscriptions

Focus is handled through the subscription system:

1. Widget subscribes to `.focus`
2. Runtime sends `.focus_gained` / `.focus_lost` messages
3. Widget updates internal `focused` state
4. Widget's `subscriptions()` changes (adds/removes `.keyboard`)
5. Runtime re-collects subscriptions
6. Keys now routed to newly focused widget

## Commands (Effects)

Widgets don't perform side effects. They return descriptions of effects.

```zig
const Cmd = union(enum) {
    none,
    quit,
    save_file: []const u8,
    load_file: []const u8,
    copy_to_clipboard: []const u8,
    http_get: []const u8,
    // ...
};
```

### Effect Handlers

App registers handlers at init. Runtime executes them.

```zig
// At app init
runtime.onCmd(.save_file, saveFileHandler);
runtime.onCmd(.quit, quitHandler);
runtime.onCmd(.copy_to_clipboard, clipboardHandler);

// Handlers are impure - actual IO happens here
fn saveFileHandler(filename: []const u8) !void {
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    try file.writeAll(data);
}
```

### Flow

```
Widget.update(msg)
    → returns Cmd (pure, just data)

Runtime receives Cmd
    → looks up registered handler
    → executes handler (impure)
    → handler may produce new Msg
    → Msg sent back to widgets
```

## Messages

```zig
const Msg = union(enum) {
    // From terminal
    key: Key,
    resize: Size,
    paste_start,
    paste_end,

    // From runtime
    tick: u64,
    focus_gained,
    focus_lost,

    // From commands (async results)
    file_loaded: []const u8,
    http_response: Response,
};
```

## Declarative View

Widgets return `LayoutNode` trees describing their appearance:

```zig
pub fn view(self: *const Repl) LayoutNode {
    return LayoutNode.hbox(&.{
        LayoutNode.text(self.prompt),
        LayoutNode.text(self.buffer.getText()),
        LayoutNode.cursorNode(),
    });
}
```

Runtime handles:
1. Layout calculation (flexbox-style)
2. Converting to DrawCommands
3. Differential rendering

## Animations

Animations are just state changes over time:

1. Widget subscribes to `.tick_ms`
2. Receives `Msg.tick` at interval
3. Updates animation state
4. Returns new view
5. Runtime renders

```zig
const Spinner = struct {
    frame: u8,

    pub fn update(self: *Spinner, msg: Msg) UpdateResult {
        switch (msg) {
            .tick => self.frame = (self.frame + 1) % 8,
            else => {},
        }
        return .{};
    }

    pub fn subscriptions(self: *const Spinner) []Sub {
        return &.{ .{ .tick_ms = 100 } };
    }

    pub fn view(self: *const Spinner) LayoutNode {
        const frames = "⣾⣽⣻⢿⡿⣟⣯⣷";
        return LayoutNode.text(frames[self.frame..self.frame+3]);
    }
};
```

## Summary

| Component | Pure/Impure | Responsibility |
|-----------|-------------|----------------|
| Widget.update | Pure | State transitions, return Cmd |
| Widget.subscriptions | Pure | Declare wanted events |
| Widget.view | Pure | Describe appearance |
| Runtime event loop | Impure | Poll input, dispatch Msg |
| Runtime cmd handlers | Impure | Execute side effects |
| Runtime renderer | Impure | Draw to terminal |
