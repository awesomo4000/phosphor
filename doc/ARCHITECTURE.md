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

### Runtime Subscription Management

The runtime calls `subscriptions()` on each widget to build a routing table:

```zig
const SubscriptionManager = struct {
    keyboard_subscribers: std.ArrayList(*Widget),
    focus_subscribers: std.ArrayList(*Widget),
    tick_subscribers: std.ArrayList(TickSubscription),

    const TickSubscription = struct {
        widget: *Widget,
        interval_ms: u32,
        last_tick: i64,
    };

    /// Called after every update cycle to refresh subscriptions
    pub fn collect(self: *SubscriptionManager, widgets: []Widget) void {
        self.keyboard_subscribers.clearRetainingCapacity();
        self.focus_subscribers.clearRetainingCapacity();
        self.tick_subscribers.clearRetainingCapacity();

        for (widgets) |*widget| {
            for (widget.subscriptions()) |sub| {
                switch (sub) {
                    .keyboard => self.keyboard_subscribers.append(widget),
                    .focus => self.focus_subscribers.append(widget),
                    .tick_ms => |interval| self.tick_subscribers.append(.{
                        .widget = widget,
                        .interval_ms = interval,
                        .last_tick = std.time.milliTimestamp(),
                    }),
                }
            }
        }
    }

    /// Route an event to subscribed widgets
    pub fn route(self: *SubscriptionManager, msg: Msg) []const *Widget {
        return switch (msg) {
            .key => self.keyboard_subscribers.items,
            .focus_gained, .focus_lost => self.focus_subscribers.items,
            .tick => self.getTickTargets(),
            else => &.{},
        };
    }

    /// Check which widgets need tick messages
    fn getTickTargets(self: *SubscriptionManager) []*Widget {
        const now = std.time.milliTimestamp();
        var targets: std.ArrayList(*Widget) = .{};

        for (self.tick_subscribers.items) |*sub| {
            if (now - sub.last_tick >= sub.interval_ms) {
                targets.append(sub.widget);
                sub.last_tick = now;
            }
        }
        return targets.items;
    }
};
```

### Subscription Lifecycle

```
┌─────────────────────────────────────────────────────────────┐
│                    SUBSCRIPTION FLOW                         │
│                                                             │
│  1. App starts                                              │
│     └─▶ Runtime calls widget.subscriptions() for each       │
│         └─▶ Builds initial routing table                    │
│                                                             │
│  2. Event arrives (key press, timer, etc.)                  │
│     └─▶ Runtime looks up subscribers for event type         │
│         └─▶ Dispatches to each subscribed widget            │
│                                                             │
│  3. Widget.update() may change state                        │
│     └─▶ State change may affect subscriptions()             │
│         (e.g., focused widget now wants .keyboard)          │
│                                                             │
│  4. After update cycle                                      │
│     └─▶ Runtime re-collects subscriptions                   │
│         └─▶ Routing table updated for next event            │
└─────────────────────────────────────────────────────────────┘
```

### Multiple Subscribers

Multiple widgets can subscribe to the same event type:

```zig
// Both widgets receive every key event
const Editor = struct {
    pub fn subscriptions(self: *const Editor) []Sub {
        return &.{ .keyboard };
    }
};

const StatusBar = struct {
    pub fn subscriptions(self: *const StatusBar) []Sub {
        return &.{ .keyboard };  // Shows key in status
    }
};

// Runtime dispatches to both - order determined by widget tree
```

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

### Runtime Effect Management

The runtime maintains a registry of effect handlers:

```zig
const Runtime = struct {
    handlers: std.AutoHashMap(CmdTag, Handler),
    subscriptions: std.ArrayList(Subscription),
    widgets: []Widget,

    pub fn init(allocator: Allocator) Runtime {
        return .{
            .handlers = std.AutoHashMap(CmdTag, Handler).init(allocator),
            .subscriptions = std.ArrayList(Subscription).init(allocator),
            .widgets = &.{},
        };
    }

    /// Register a handler for a command type
    pub fn onCmd(self: *Runtime, cmd_tag: CmdTag, handler: Handler) void {
        self.handlers.put(cmd_tag, handler);
    }

    /// Process commands returned by widget updates
    pub fn processCmd(self: *Runtime, cmd: Cmd) ?Msg {
        const tag = std.meta.activeTag(cmd);
        if (self.handlers.get(tag)) |handler| {
            return handler.execute(cmd);
        }
        return null;
    }
};
```

### Async Results

Commands that perform async operations (file IO, network requests) return results as messages:

```zig
// Handler produces a message when work completes
fn loadFileHandler(ctx: *Runtime, filename: []const u8) ?Msg {
    const contents = std.fs.cwd().readFileAlloc(ctx.allocator, filename, 1024 * 1024) catch |err| {
        return .{ .file_error = err };
    };
    return .{ .file_loaded = .{ .filename = filename, .contents = contents } };
}

// Widget receives the result in next update cycle
pub fn update(self: *Editor, msg: Msg) UpdateResult {
    switch (msg) {
        .file_loaded => |data| {
            self.buffer.setText(data.contents);
            return .{};
        },
        .file_error => |err| {
            self.status = .{ .error = err };
            return .{};
        },
        // ...
    }
}
```

### Batch Commands

Widgets can return multiple commands using `Cmd.batch`:

```zig
pub fn update(self: *App, msg: Msg) UpdateResult {
    switch (msg) {
        .save_all => {
            // Return multiple effects
            return .{
                .cmd = Cmd.batch(&.{
                    .{ .save_file = "file1.txt" },
                    .{ .save_file = "file2.txt" },
                    .{ .log = "Saving all files..." },
                }),
            };
        },
        // ...
    }
}
```

### Command Categories

Commands typically fall into these categories:

| Category | Examples | Returns Msg? |
|----------|----------|--------------|
| Navigation | `.quit`, `.push_screen` | No |
| File IO | `.save_file`, `.load_file` | Yes (async result) |
| Clipboard | `.copy`, `.paste` | Paste returns Msg |
| Network | `.http_get`, `.http_post` | Yes (async result) |
| System | `.set_title`, `.bell` | No |
| App-specific | `.add_todo`, `.delete_item` | Depends |

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

## The Event Loop

The runtime event loop ties everything together:

```zig
pub fn run(self: *Runtime) !void {
    // Initial render
    try self.render();

    while (self.running) {
        // 1. Poll for input events
        const event = try self.backend.readEvent();
        if (event == null) continue;

        // 2. Convert to Msg
        const msg = eventToMsg(event.?);

        // 3. Collect subscriptions (determines who gets the event)
        const subs = self.collectSubscriptions();

        // 4. Dispatch to subscribed widgets
        var cmds: std.ArrayList(Cmd) = .{};
        var app_msgs: std.ArrayList(AppMsg) = .{};

        for (self.widgets) |*widget| {
            if (widget.isSubscribed(subs, msg)) {
                const result = widget.update(msg);
                if (result.cmd != .none) try cmds.append(result.cmd);
                try app_msgs.appendSlice(result.messages);
            }
        }

        // 5. Process commands (side effects)
        for (cmds.items) |cmd| {
            if (self.processCmd(cmd)) |result_msg| {
                // Handler produced a message - queue for next cycle
                try self.message_queue.append(result_msg);
            }
        }

        // 6. Send app messages to app update function
        for (app_msgs.items) |app_msg| {
            try self.app_update(app_msg);
        }

        // 7. Re-render
        try self.render();
    }
}

fn render(self: *Runtime) !void {
    // Collect views from all widgets
    var nodes: std.ArrayList(LayoutNode) = .{};
    for (self.widgets) |widget| {
        if (widget.view()) |node| {
            try nodes.append(node);
        }
    }

    // Layout pass
    const tree = buildLayoutTree(nodes.items);
    const bounds = Rect{ .x = 0, .y = 0, .w = self.size.cols, .h = self.size.rows };

    // Render pass
    const commands = try renderTree(tree, bounds, self.frame_allocator);

    // Execute on backend (differential rendering)
    self.backend.execute(commands);

    // Clear frame allocator for next frame
    self.frame_arena.reset();
}
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

## Design Principles

1. **Widgets are pure** - They only transform state and return descriptions of effects
2. **Runtime is impure** - All IO, timers, and side effects happen here
3. **Subscriptions are dynamic** - What events a widget wants depends on its state
4. **Commands are data** - Effects are described, not performed
5. **Handlers are registered** - App controls what effects are available
6. **Messages flow one way** - Events → Widgets → Commands → Handlers → Messages
