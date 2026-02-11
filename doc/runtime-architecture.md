# Phosphor Runtime Architecture

## Overview

Phosphor follows an Elm/Lustre-inspired architecture with:
- **Model**: Application state
- **Msg**: All possible events (parameterized)
- **Effect(Msg)**: Declarative side effects returned from update
- **Subs(Msg)**: Subscriptions with wrapper functions
- **View**: Pure function returning a Node tree

## App Definition (User-land)

```zig
const std = @import("std");
const phosphor = @import("phosphor");

// 1. Model - your state
const Model = struct {
    repl: Repl,
    log: LogView,
    size: phosphor.Size,
};

// 2. Msg - all events
const Msg = union(enum) {
    // System events (from subscriptions)
    key: phosphor.Key,
    resize: phosphor.Size,
    tick: f32,

    // Widget events (from Effect.dispatch)
    repl_submit: []const u8,
    repl_cancel,
};

// 3. init - create initial model
pub fn init(allocator: Allocator) Model { ... }

// 4. update - returns Effect(Msg)
pub fn update(model: *Model, msg: Msg) phosphor.Effect(Msg) {
    switch (msg) {
        .key => |k| return model.repl.handleKey(k, Msg, .{
            .on_submit = wrap(.repl_submit),
            .on_cancel = wrapVoid(.repl_cancel),
        }),
        .repl_submit => |text| { ... },
        .resize => |size| model.size = size,
        .tick => |dt| { ... },
    }
    return .none;
}

// 5. view - returns a Node tree
pub fn view(model: *Model, ui: *phosphor.Ui) phosphor.Node {
    return ui.vbox(.{
        ui.text("Header"),
        ui.separator(),
        ui.widget(&model.log).grow(),
        ui.separator(),
        ui.widget(&model.repl).fit(),
    });
}

// 6. subs - wrapper functions declare how to wrap events
pub fn subs(model: *Model) phosphor.Subs(Msg) {
    return .{
        .keyboard = wrap(.key),
        .resize = wrap(.resize),
        .animation_frame = if (model.animating) wrap(.tick) else null,
    };
}

// Run it
pub fn main() !void {
    try phosphor.run(@This(), allocator, .{});
}
```

## Runtime Loop

```
┌─────────────────────────────────────────────────────────────┐
│                      RUNTIME LOOP                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. DRAIN MESSAGE QUEUE                                     │
│     ├─ Pop all pending Msg from queue                       │
│     └─ (Input thread pushes here via subscriptions)         │
│                                                             │
│  2. PROCESS MESSAGES                                        │
│     for each msg:                                           │
│       ├─ effect = update(model, msg)                        │
│       ├─ if effect == .quit → exit                          │
│       ├─ if effect == .dispatch → queue msg                 │
│       ├─ if effect == .after → defer to post-render         │
│       └─ if effect == .batch → recurse                      │
│                                                             │
│  3. BUILD VIEW TREE                                         │
│     ├─ node = view(model, ui)                               │
│     └─ Returns Node tree (not yet laid out)                 │
│                                                             │
│  4. LAYOUT PASS                                             │
│     ├─ Compute constraints (available width/height)         │
│     ├─ Walk tree: measure phase (intrinsic sizes)           │
│     ├─ Walk tree: layout phase (assign bounds)              │
│     └─ Output: Node tree with Rect bounds on each node      │
│                                                             │
│  5. RENDER PASS                                             │
│     ├─ Walk tree: generate DrawCommands                     │
│     │   ├─ Each widget renders at local (0,0)               │
│     │   └─ Commands include: text, color, cursor, etc.      │
│     ├─ Collect widget positions (for Effect.set_cursor)     │
│     └─ Output: []DrawCommand + []WidgetPosition             │
│                                                             │
│  6. PAINT                                                   │
│     ├─ Execute DrawCommands on back buffer                  │
│     ├─ Diff against front buffer                            │
│     ├─ Emit optimized ANSI sequences                        │
│     └─ Swap buffers                                         │
│                                                             │
│  7. POST-PAINT EFFECTS                                      │
│     ├─ Process deferred .after effects                      │
│     │   ├─ set_cursor: lookup widget pos, emit \e[row;colH  │
│     │   ├─ show_cursor: emit \e[?25h                        │
│     │   └─ etc.                                             │
│     └─ (Cursor MUST be after paint or it flickers)          │
│                                                             │
│  8. FRAME PACING                                            │
│     └─ Sleep to hit target FPS                              │
│                                                             │
│  9. LOOP                                                    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Input Thread

```
┌─────────────────────────────────────────────────────────────┐
│                    INPUT THREAD                             │
├─────────────────────────────────────────────────────────────┤
│  while running:                                             │
│    ├─ Block on terminal read                                │
│    ├─ Parse key/mouse/resize                                │
│    ├─ Look up subscription wrapper: fn(Key) Msg             │
│    ├─ msg = wrapper(event)                                  │
│    └─ queue.push(msg)                                       │
└─────────────────────────────────────────────────────────────┘
```

## Layout/Render Pipeline

```
VIEW TREE (from view())          LAYOUT TREE (after layout)       DRAW COMMANDS
─────────────────────           ──────────────────────────       ──────────────

Node.vbox                       Node.vbox
  │                               │ bounds: {0,0,80,24}
  ├─ Node.text("Header")          ├─ Node.text                   move(0,0)
  │                               │   bounds: {0,0,80,1}         text("Header")
  │                               │
  ├─ Node.separator               ├─ Node.separator              move(0,1)
  │                               │   bounds: {0,1,80,1}         text("────────")
  │                               │
  ├─ Node.widget(log)             ├─ Node.widget(log)            move(0,2)
  │    .grow()                    │   bounds: {0,2,80,19}        [log renders]
  │                               │
  ├─ Node.separator               ├─ Node.separator              move(0,21)
  │                               │   bounds: {0,21,80,1}        text("────────")
  │                               │
  └─ Node.widget(repl)            └─ Node.widget(repl)           move(0,22)
       .fit()                         bounds: {0,22,80,2}        [repl renders]
                                      ↓                          show_cursor
                                  WidgetPosition {
                                    widget: &repl,
                                    bounds: {0,22,80,2}
                                  }
```

## Key Types

### Effect(Msg)

```zig
pub fn Effect(comptime Msg: type) type {
    return union(enum) {
        none,
        quit,
        dispatch: Msg,              // Queue message for next cycle
        batch: []const Effect(Msg),
        after: AfterPaint,          // Post-render effects

        pub const AfterPaint = union(enum) {
            set_cursor: struct { widget: *anyopaque, x: u16, y: u16 },
            show_cursor,
            hide_cursor,
        };
    };
}
```

### Subs(Msg)

```zig
pub fn Subs(comptime Msg: type) type {
    return struct {
        keyboard: ?*const fn (Key) Msg = null,
        resize: ?*const fn (Size) Msg = null,
        animation_frame: ?*const fn (f32) Msg = null,
        paste: ?*const fn ([]const u8) Msg = null,
    };
}
```

### Node

```zig
pub const Node = struct {
    content: Content,
    sizing: Sizing = .{},

    pub const Content = union(enum) {
        text: []const u8,
        widget: *const LocalWidgetVTable,
        vbox: []Node,
        hbox: []Node,
        canvas: CanvasRef,
    };

    pub const Sizing = struct {
        w: Constraint = .fit,
        h: Constraint = .fit,
    };

    pub const Constraint = union(enum) {
        fit,              // Use intrinsic size
        grow,             // Expand to fill
        fixed: u16,       // Exact size
    };
};
```

### Widget Protocol

```zig
pub const LocalWidgetVTable = struct {
    /// Measure intrinsic size given available space
    measure: *const fn (self: *anyopaque, available: Size) Size,

    /// Render to command buffer at local coordinates (0,0)
    render: *const fn (self: *anyopaque, bounds: Rect, cmds: *CommandBuffer) void,
};
```

## Migration TODO

### Phase 1: Effect System (isolated, low risk) ✓
1. [x] **Migrate update() return** - from `Cmd` to `Effect(Msg)` in app.zig runtime
2. [x] **Update repl_demo** - use Effect instead of Cmd
3. [x] **Update other demos** - mandelbrot, sprites, hypercube

### Phase 2: Subscriptions (isolated, low risk)
4. [ ] **Migrate subs() return** - from bool struct to `Subs(Msg)`
5. [ ] **Update runtime** - use wrapper functions to create messages
6. [ ] **Update demos** - new subs signature

### Phase 3: Node Unification (larger change)
7. [ ] **Add canvas to LayoutNode** - support pixel rendering in layout system
8. [ ] **Migrate Ui builder** - return LayoutNode instead of Node
9. [ ] **Update runtime** - work with LayoutNode directly
10. [ ] **Remove Node type** - eliminate app.zig Node

### Phase 4: Cleanup
11. [ ] **Remove legacy code** - old Application type, old runtime
12. [ ] **Widget position tracking** - for `Effect.set_cursor` resolution
13. [ ] **Documentation** - update examples and docs

## Design Principles

### From Lustre/Gleam

- Effects are data, not callbacks
- Subscriptions declare *how* to wrap events, not just *which* events
- Everything parameterized by Msg type
- Runtime handles all side effects

### Terminal-Specific

- Input runs on separate thread (blocking read)
- Message queue bridges input thread and main loop
- Cursor positioning MUST happen after paint (flicker prevention)
- Differential rendering for performance

### Widget Protocol

- Widgets render at local (0,0) coordinates
- Runtime translates to screen coordinates
- Widgets return Effects, not perform side effects
- Layout system handles sizing/positioning
