const std = @import("std");
const Allocator = std.mem.Allocator;
const thermite = @import("thermite");
const phosphor = @import("phosphor");

// Re-export phosphor types for text-based apps
pub const DrawCommand = phosphor.DrawCommand;
pub const LayoutNode = phosphor.LayoutNode;
pub const Rect = phosphor.Rect;
pub const renderTree = phosphor.renderTree;
pub const renderTreeWithPositions = phosphor.renderTreeWithPositions;
pub const RenderResult = phosphor.RenderResult;
pub const WidgetPosition = phosphor.WidgetPosition;

// Re-export Key type for input handling
pub const Key = thermite.terminal.Key;

/// Backend selection for rendering
pub const Backend = enum {
    simple,
    thermite,
};

/// Options for App.run()
pub const RunOptions = struct {
    backend: Backend = .simple,
    /// Target frames per second. 0 = unlimited (just yields between frames)
    target_fps: u32 = 120,
};

/// New Subs type - parameterized by Msg, wraps events in messages
pub const SubsNew = phosphor.Subs;

/// Legacy Subscriptions - what events the app wants
/// TODO: Migrate to SubsNew after updating all apps
pub const Subs = struct {
    keyboard: bool = false,
    mouse: bool = false,
    animation_frame: bool = false,
    paste: bool = false,
};

/// Terminal size
pub const Size = struct {
    w: u32,
    h: u32,
};

/// Create a function that wraps a value into a tagged union variant.
/// This enables Elm-style child-to-parent message passing.
///
/// Example:
/// ```zig
/// const Msg = union(enum) {
///     got_submit: []const u8,
///     got_change: []const u8,
///     tick: f32,
/// };
///
/// // Create wrapper functions
/// const on_submit = wrap(Msg, .got_submit);  // fn([]const u8) Msg
/// const on_change = wrap(Msg, .got_change);  // fn([]const u8) Msg
///
/// // Use in widget configuration
/// repl(&model.repl_state, .{
///     .on_submit = on_submit,
///     .on_change = on_change,
/// });
/// ```
pub fn wrap(comptime Msg: type, comptime tag: std.meta.Tag(Msg)) WrapFn(Msg, tag) {
    const Payload = std.meta.TagPayload(Msg, tag);
    return struct {
        fn f(payload: Payload) Msg {
            return @unionInit(Msg, @tagName(tag), payload);
        }
    }.f;
}

/// Return type for wrap() - a function from payload to message
fn WrapFn(comptime Msg: type, comptime tag: std.meta.Tag(Msg)) type {
    const Payload = std.meta.TagPayload(Msg, tag);
    return *const fn (Payload) Msg;
}

/// Create a function that transforms a value before wrapping into a tagged union.
/// Use this when you need to add extra context or transform the payload.
///
/// Example:
/// ```zig
/// const Msg = union(enum) {
///     key_event: struct { key: u8, source: []const u8 },
/// };
///
/// // Transform u8 key into struct with extra context
/// const on_key = wrapWith(Msg, .key_event, struct {
///     fn f(key: u8) struct { key: u8, source: []const u8 } {
///         return .{ .key = key, .source = "repl" };
///     }
/// }.f);
/// ```
pub fn wrapWith(
    comptime Msg: type,
    comptime tag: std.meta.Tag(Msg),
    comptime transformer: anytype,
) WrapWithFn(@TypeOf(transformer), Msg) {
    const TransformFn = @TypeOf(transformer);
    const Input = @typeInfo(TransformFn).@"fn".params[0].type.?;

    return struct {
        fn f(input: Input) Msg {
            const payload = transformer(input);
            return @unionInit(Msg, @tagName(tag), payload);
        }
    }.f;
}

/// Return type for wrapWith()
fn WrapWithFn(comptime TransformFn: type, comptime Msg: type) type {
    const Input = @typeInfo(TransformFn).@"fn".params[0].type.?;
    return *const fn (Input) Msg;
}

/// Configuration for mapping child widget messages to parent messages.
/// Use with `mapChildMsg` to translate widget events to your app's Msg type.
///
/// Example:
/// ```zig
/// const MsgMap = app.MsgMapper(Msg, Repl.ReplMsg){
///     .submitted = wrap(Msg, .got_submit),
///     .cancelled = wrapVoid(Msg, .cancelled),
///     .eof = wrapVoid(Msg, .quit),
/// };
///
/// if (model.repl.update(event) catch null) |child_msg| {
///     if (MsgMap.map(child_msg)) |msg| {
///         // Handle msg...
///     }
/// }
/// ```
pub fn MsgMapper(comptime ParentMsg: type, comptime ChildMsg: type) type {
    const child_fields = @typeInfo(ChildMsg).@"union".fields;

    // Build struct fields for each child message variant
    var fields: [child_fields.len]std.builtin.Type.StructField = undefined;
    for (child_fields, 0..) |field, i| {
        const MapperFn = if (field.type == void)
            ?*const fn () ParentMsg
        else
            ?*const fn (field.type) ParentMsg;

        fields[i] = .{
            .name = field.name,
            .type = MapperFn,
            .default_value_ptr = @ptrCast(&@as(MapperFn, null)),
            .is_comptime = false,
            .alignment = @alignOf(MapperFn),
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

/// Wrap a void variant - creates a function that takes nothing and returns the message.
/// Use for child message variants that have no payload (like .cancelled, .eof).
///
/// Example:
/// ```zig
/// const Msg = union(enum) { quit, cancelled };
/// const on_eof = wrapVoid(Msg, .quit);  // fn() Msg
/// ```
pub fn wrapVoid(comptime Msg: type, comptime tag: std.meta.Tag(Msg)) *const fn () Msg {
    return struct {
        fn f() Msg {
            return @unionInit(Msg, @tagName(tag), {});
        }
    }.f;
}

/// Effect - declarative side effects returned from update
/// Re-exported from phosphor, parameterized by Msg type
pub const Effect = phosphor.Effect;

/// Legacy Cmd alias for backwards compatibility
/// TODO: Remove after migrating all apps to Effect
pub const Cmd = union(enum) {
    /// No side effect
    none,
    /// Exit the application
    quit,
    /// Run multiple commands
    batch: []const Cmd,
    // Future:
    // set_title: []const u8,
    // copy_clipboard: []const u8,
};

/// Canvas buffer for pixel rendering - generic over context type
pub fn Canvas(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        pixels: []u32 = &.{},
        width: u32 = 0,
        height: u32 = 0,
        render_fn: ?*const fn (*Ctx) void = null,

        pub fn resize(self: *Self, allocator: Allocator, w: u32, h: u32) !void {
            if (self.width == w and self.height == h) return;
            if (self.pixels.len > 0) allocator.free(self.pixels);
            self.pixels = try allocator.alloc(u32, w * h);
            self.width = w;
            self.height = h;
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            if (self.pixels.len > 0) allocator.free(self.pixels);
            self.* = .{};
        }

        /// Call the render function with context
        pub fn render(self: *Self, ctx: *Ctx) void {
            if (self.render_fn) |f| f(ctx);
        }

        pub fn clear(self: *Self, color: u32) void {
            @memset(self.pixels, color);
        }

        pub fn setPixel(self: *Self, x: i32, y: i32, color: u32) void {
            if (x < 0 or y < 0) return;
            const ux: u32 = @intCast(x);
            const uy: u32 = @intCast(y);
            if (ux >= self.width or uy >= self.height) return;
            self.pixels[uy * self.width + ux] = color;
        }

        pub fn drawLine(self: *Self, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
            var px0 = x0;
            var py0 = y0;
            const px1 = x1;
            const py1 = y1;

            const dx: i32 = if (px1 > px0) px1 - px0 else px0 - px1;
            const dy: i32 = if (py1 > py0) py1 - py0 else py0 - py1;
            const sx: i32 = if (px0 < px1) 1 else -1;
            const sy: i32 = if (py0 < py1) 1 else -1;
            var err = dx - dy;

            while (true) {
                self.setPixel(px0, py0, color);
                if (px0 == px1 and py0 == py1) break;
                const e2 = 2 * err;
                if (e2 > -dy) {
                    err -= dy;
                    px0 += sx;
                }
                if (e2 < dx) {
                    err += dx;
                    py0 += sy;
                }
            }
        }

        pub fn drawCircle(self: *Self, cx: i32, cy: i32, radius: i32, color: u32) void {
            var dy: i32 = -radius;
            while (dy <= radius) : (dy += 1) {
                var dx: i32 = -radius;
                while (dx <= radius) : (dx += 1) {
                    if (dx * dx + dy * dy <= radius * radius) {
                        self.setPixel(cx + dx, cy + dy, color);
                    }
                }
            }
        }

        pub fn drawRect(self: *Self, x: i32, y: i32, w: u32, h: u32, color: u32) void {
            var py: i32 = y;
            const end_y = y + @as(i32, @intCast(h));
            while (py < end_y) : (py += 1) {
                var px: i32 = x;
                const end_x = x + @as(i32, @intCast(w));
                while (px < end_x) : (px += 1) {
                    self.setPixel(px, py, color);
                }
            }
        }
    };
}

/// UI node types
pub const Node = struct {
    data: Data,
    // Event handlers (type-erased, cast in App runtime)
    on_key: ?*const anyopaque = null, // fn(Key) Msg
    on_click: ?*const anyopaque = null, // fn() Msg

    pub const Data = union(enum) {
        text: []const u8,
        canvas: CanvasRef,
        column: []*Node,
        row: []*Node,
        flex: Flex,
        fixed: Fixed,
        /// Phosphor layout node - for text-based UIs
        layout: LayoutRef,
    };

    /// Reference to a phosphor LayoutNode tree
    pub const LayoutRef = struct {
        node: *const LayoutNode,
        cursor_x: ?u16 = null,
        cursor_y: ?u16 = null,
    };

    /// Type-erased canvas reference (for generic Canvas(Ctx))
    pub const CanvasRef = struct {
        pixels: *[]u32,
        width: *u32,
        height: *u32,
        render_fn: ?*const fn (*anyopaque) void,
        render_ctx: *anyopaque,
        overlay_text: ?[]const u8 = null,
    };

    pub const Flex = struct {
        factor: u8,
        child: *Node,
    };

    pub const Fixed = struct {
        size: u16,
        child: *Node,
    };
};

/// Canvas options generator - creates typed options struct for canvas()
pub fn CanvasOptions(comptime Ctx: type, comptime Msg: type) type {
    return struct {
        buffer: *Canvas(Ctx),
        ctx: *Ctx,
        on_key: ?*const fn (Key) Msg = null,
        on_click: ?*const fn () Msg = null,
        on_mouse: ?*const fn (u16, u16) Msg = null, // x, y
        overlay_text: ?[]const u8 = null, // status bar text drawn at bottom
    };
}

/// UI builder - holds allocator, provides node constructors
pub const Ui = struct {
    ally: Allocator,

    // ─────────────────────────────────────────────────────────────
    // Layout builders (return LayoutNode for text-based UIs)
    // ─────────────────────────────────────────────────────────────

    /// Create a vertical box layout
    pub fn vbox(self: *Ui, children: anytype) LayoutNode {
        return self.boxImpl(.vertical, children);
    }

    /// Create a horizontal box layout
    pub fn hbox(self: *Ui, children: anytype) LayoutNode {
        return self.boxImpl(.horizontal, children);
    }

    fn boxImpl(self: *Ui, direction: phosphor.Direction, children: anytype) LayoutNode {
        const ChildType = @TypeOf(children);
        const child_info = @typeInfo(ChildType);

        if (child_info == .@"struct" and child_info.@"struct".is_tuple) {
            // Tuple of LayoutNodes
            const fields = child_info.@"struct".fields;
            const nodes = self.ally.alloc(LayoutNode, fields.len) catch @panic("OOM");
            inline for (fields, 0..) |field, i| {
                nodes[i] = @field(children, field.name);
            }
            return .{ .direction = direction, .content = .{ .children = nodes } };
        } else {
            // Slice of LayoutNodes
            const nodes = self.ally.dupe(LayoutNode, children) catch @panic("OOM");
            return .{ .direction = direction, .content = .{ .children = nodes } };
        }
    }

    /// Create a spacer that grows to fill available space
    pub fn spacer(_: *Ui) LayoutNode {
        return phosphor.Spacer.node();
    }

    /// Create a text layout node
    pub fn ltext(_: *Ui, str: []const u8) LayoutNode {
        return LayoutNode.text(str);
    }

    /// Create a justified row with left and right text.
    /// Right text has priority - if space is limited, left text is truncated first.
    /// Useful for headers like "Title ... 80x24" where the size should always be visible.
    pub fn justified(self: *Ui, left: []const u8, right: []const u8) LayoutNode {
        const justified_row = self.ally.create(phosphor.JustifiedRow) catch @panic("OOM");
        justified_row.* = phosphor.JustifiedRow.init(left, right);
        return justified_row.node();
    }

    /// Create a horizontal separator line (fills available width)
    pub fn separator(_: *Ui) LayoutNode {
        return phosphor.Separator.node();
    }

    /// Create a layout node from any widget with localWidget() method.
    /// Uses fit sizing for height (asks widget for preferred height).
    pub fn widget(_: *Ui, w: anytype) LayoutNode {
        var node = LayoutNode.localWidget(w.localWidget());
        node.sizing.h = .{ .fit = .{} };  // Ask widget for preferred height
        return node;
    }

    /// Create a widget node with explicit sizing
    pub fn widgetSized(_: *Ui, w: anytype, sizing: phosphor.Sizing) LayoutNode {
        return LayoutNode.localWidgetSized(w.localWidget(), sizing);
    }

    /// Create a widget that grows to fill available space
    pub fn widgetGrow(_: *Ui, w: anytype) LayoutNode {
        var node = LayoutNode.localWidget(w.localWidget());
        node.sizing.h = .{ .grow = .{} };
        return node;
    }

    /// Create a widget with fixed height
    pub fn widgetFixed(_: *Ui, w: anytype, height: u16) LayoutNode {
        var node = LayoutNode.localWidget(w.localWidget());
        node.sizing.h = .{ .fixed = height };
        return node;
    }

    // ─────────────────────────────────────────────────────────────
    // Legacy Node builders (for canvas-based UIs)
    // ─────────────────────────────────────────────────────────────

    pub fn text(self: *Ui, str: []const u8) *Node {
        const node = self.ally.create(Node) catch @panic("OOM");
        node.* = .{ .data = .{ .text = str } };
        return node;
    }

    pub fn textFmt(self: *Ui, comptime fmt: []const u8, args: anytype) *Node {
        const node = self.ally.create(Node) catch @panic("OOM");
        const str = std.fmt.allocPrint(self.ally, fmt, args) catch @panic("OOM");
        node.* = .{ .data = .{ .text = str } };
        return node;
    }

    /// Create canvas node with optional handlers
    pub fn canvas(
        self: *Ui,
        comptime Ctx: type,
        comptime Msg: type,
        opts: CanvasOptions(Ctx, Msg),
    ) *Node {
        const node = self.ally.create(Node) catch @panic("OOM");
        node.* = .{
            .data = .{ .canvas = .{
                .pixels = &opts.buffer.pixels,
                .width = &opts.buffer.width,
                .height = &opts.buffer.height,
                .render_fn = if (opts.buffer.render_fn) |f| @ptrCast(f) else null,
                .render_ctx = opts.ctx,
                .overlay_text = opts.overlay_text,
            } },
            .on_key = if (opts.on_key) |h| @ptrCast(h) else null,
            .on_click = if (opts.on_click) |h| @ptrCast(h) else null,
        };
        return node;
    }

    pub fn column(self: *Ui, children: []const *Node) *Node {
        const node = self.ally.create(Node) catch @panic("OOM");
        const owned = self.ally.dupe(*Node, children) catch @panic("OOM");
        node.* = .{ .data = .{ .column = owned } };
        return node;
    }

    pub fn row(self: *Ui, children: []const *Node) *Node {
        const node = self.ally.create(Node) catch @panic("OOM");
        const owned = self.ally.dupe(*Node, children) catch @panic("OOM");
        node.* = .{ .data = .{ .row = owned } };
        return node;
    }

    pub fn flex(self: *Ui, factor: u8, child: *Node) *Node {
        const node = self.ally.create(Node) catch @panic("OOM");
        node.* = .{ .data = .{ .flex = .{ .factor = factor, .child = child } } };
        return node;
    }

    pub fn fixed(self: *Ui, size: u16, child: *Node) *Node {
        const node = self.ally.create(Node) catch @panic("OOM");
        node.* = .{ .data = .{ .fixed = .{ .size = size, .child = child } } };
        return node;
    }

    /// Create a layout node wrapping a phosphor LayoutNode tree
    pub fn layout(self: *Ui, layout_node: *const LayoutNode) *Node {
        const node = self.ally.create(Node) catch @panic("OOM");
        node.* = .{ .data = .{ .layout = .{ .node = layout_node } } };
        return node;
    }

    /// Create a layout node with cursor position
    pub fn layoutWithCursor(self: *Ui, layout_node: *const LayoutNode, cursor_x: u16, cursor_y: u16) *Node {
        const node = self.ally.create(Node) catch @panic("OOM");
        node.* = .{ .data = .{ .layout = .{
            .node = layout_node,
            .cursor_x = cursor_x,
            .cursor_y = cursor_y,
        } } };
        return node;
    }
};

/// App factory - takes a module type, returns runnable app
pub fn App(comptime Module: type) type {
    // Infer Model from init() return type
    const InitFn = @TypeOf(Module.init);
    const init_info = @typeInfo(InitFn).@"fn";
    const init_params = init_info.params;
    const init_takes_allocator = init_params.len > 0 and init_params[0].type.? == Allocator;
    const Model = init_info.return_type.?;

    // Infer Msg from update() second param
    const UpdateFn = @TypeOf(Module.update);
    const update_params = @typeInfo(UpdateFn).@"fn".params;
    const Msg = update_params[1].type.?;

    return struct {
        /// Run the app with options
        pub fn run(allocator: Allocator, options: RunOptions) !void {
            var model = if (init_takes_allocator)
                Module.init(allocator)
            else
                Module.init();

            defer if (@hasDecl(Model, "deinit")) {
                // Check if deinit takes allocator
                const DeinitFn = @TypeOf(Model.deinit);
                const deinit_params = @typeInfo(DeinitFn).@"fn".params;
                if (deinit_params.len > 1 and deinit_params[1].type.? == Allocator) {
                    model.deinit(allocator);
                } else {
                    model.deinit();
                }
            };

            return switch (options.backend) {
                .simple => runSimple(allocator, &model, options),
                .thermite => runThermite(allocator, &model, options),
            };
        }

        /// Run with simple backend (half-block rendering)
        fn runSimple(allocator: Allocator, model: *Model, options: RunOptions) !void {
            // Frame arena for view nodes
            var frame_arena = std.heap.ArenaAllocator.init(allocator);
            defer frame_arena.deinit();

            // Terminal setup
            var term = try Terminal.init();
            defer term.deinit();

            // Screen buffer for rendering
            var screen = try ScreenBuffer.init(allocator, term.width, term.height);
            defer screen.deinit(allocator);

            // UI builder using frame arena
            var ui = Ui{ .ally = frame_arena.allocator() };

            // Timing
            var last_frame = std.time.milliTimestamp();

            // Send initial resize
            if (executeCmd(Module.update(model, msgFromResize(Msg, term.width, term.height), allocator))) return;

            // Build initial view
            var root = Module.view(model, &ui);

            // Event loop
            while (true) {
                const subs = Module.subs(model);

                // Block if not animating - saves CPU
                if (!subs.animation_frame) {
                    term.waitForEvent();
                }

                // Check for terminal resize (SIGWINCH)
                if (term.checkResize()) |resize_event| {
                    // Resize screen buffer
                    screen.resize(allocator, resize_event.resize.w, resize_event.resize.h) catch {};
                    // Send resize message to model
                    if (msgFromEvent(Msg, resize_event)) |msg| {
                        if (executeCmd(Module.update(model, msg, allocator))) return;
                    }
                }

                // Process all pending input events
                while (term.pollEvent()) |event| {
                    switch (event) {
                        .key => |key| {
                            // Check view tree for on_key handler first
                            if (findKeyHandler(root)) |handler| {
                                const typed_handler: *const fn (Key) Msg = @ptrCast(@alignCast(handler));
                                const msg = typed_handler(key);
                                if (executeCmd(Module.update(model, msg, allocator))) return;
                            } else if (msgFromEvent(Msg, event)) |msg| {
                                // Fall back to direct event
                                if (executeCmd(Module.update(model, msg, allocator))) return;
                            }
                        },
                        else => {
                            if (msgFromEvent(Msg, event)) |msg| {
                                if (executeCmd(Module.update(model, msg, allocator))) return;
                            }
                        },
                    }
                }

                // Update timing (always, to avoid jumps after pause)
                const now = std.time.milliTimestamp();
                const dt = @as(f32, @floatFromInt(now - last_frame)) / 1000.0;
                last_frame = now;

                // Send tick if animating
                if (subs.animation_frame) {
                    if (msgFromTick(Msg, dt)) |msg| {
                        if (executeCmd(Module.update(model, msg, allocator))) return;
                    }
                }

                // Reset frame arena, rebuild view
                _ = frame_arena.reset(.retain_capacity);
                ui.ally = frame_arena.allocator();

                root = Module.view(model, &ui);

                // Clear screen buffer and render
                screen.clear();
                renderToScreen(&screen, root, term.width, term.height);

                // Present
                try term.present(&screen);

                // Frame pacing
                if (subs.animation_frame) {
                    const frame_time = std.time.milliTimestamp() - last_frame;
                    const target: i64 = if (options.target_fps == 0) 1 else @divFloor(1000, options.target_fps);
                    if (frame_time < target) {
                        std.Thread.sleep(@intCast((target - frame_time) * std.time.ns_per_ms));
                    }
                }
            }
        }

        /// Run with thermite backend (optimized 2x2 block rendering)
        fn runThermite(allocator: Allocator, model: *Model, options: RunOptions) !void {
            // Frame arena for view nodes
            var frame_arena = std.heap.ArenaAllocator.init(allocator);
            defer frame_arena.deinit();

            // Initialize thermite renderer
            const renderer = try thermite.Renderer.init(allocator);
            defer renderer.deinit();

            // Install signal handlers (SIGINT cleanup + SIGWINCH resize)
            thermite.terminal.installSignalHandlers(renderer.getTerminalFd());

            // UI builder using frame arena
            var ui = Ui{ .ally = frame_arena.allocator() };

            // Timing
            var last_frame = std.time.milliTimestamp();

            // Build initial view to detect type (layout vs canvas)
            var root = Module.view(model, &ui);

            // Send initial resize with appropriate dimensions based on view type
            // Layout nodes use cell dimensions, canvas nodes use pixel dimensions
            const is_layout = findLayoutRef(root) != null;
            const initial_width: u32 = if (is_layout) renderer.term_width else renderer.term_width * 2;
            const initial_height: u32 = if (is_layout) renderer.term_height else renderer.term_height * 2;
            if (executeCmd(Module.update(model, msgFromResize(Msg, initial_width, initial_height), allocator))) return;

            // Rebuild view with correct dimensions
            _ = frame_arena.reset(.retain_capacity);
            ui.ally = frame_arena.allocator();
            root = Module.view(model, &ui);

            const term_fd = renderer.getTerminalFd();

            // Event loop
            while (true) {
                const subs = Module.subs(model);

                // Input handling
                if (subs.animation_frame) {
                    // Non-blocking key check when animating
                    if (thermite.terminal.readKeyEvent(term_fd)) |key| {
                        if (findKeyHandler(root)) |handler| {
                            const typed_handler: *const fn (Key) Msg = @ptrCast(@alignCast(handler));
                            if (executeCmd(Module.update(model, typed_handler(key), allocator))) return;
                        } else if (@hasField(Msg, "key")) {
                            if (executeCmd(Module.update(model, @unionInit(Msg, "key", key), allocator))) return;
                        }
                    }
                } else {
                    // Blocking poll when not animating
                    switch (thermite.terminal.pollInput(term_fd, 100) catch .timeout) {
                        .ready => {
                            if (thermite.terminal.readKeyEvent(term_fd)) |key| {
                                if (findKeyHandler(root)) |handler| {
                                    const typed_handler: *const fn (Key) Msg = @ptrCast(@alignCast(handler));
                                    if (executeCmd(Module.update(model, typed_handler(key), allocator))) return;
                                } else if (@hasField(Msg, "key")) {
                                    if (executeCmd(Module.update(model, @unionInit(Msg, "key", key), allocator))) return;
                                }
                            }
                        },
                        .resize, .timeout => {},
                    }
                }

                // Check for terminal resize - use ioctl to get actual size, not just signal
                // This handles coalesced SIGWINCH signals during slow resizing
                const actual_size = thermite.terminal.getCurrentSize(renderer.ttyfd);
                const size_changed = if (actual_size) |actual|
                    actual.width != renderer.term_width or actual.height != renderer.term_height
                else
                    renderer.checkResize() != null;

                if (size_changed) {
                    if (actual_size) |actual| {
                        renderer.resize(actual.width, actual.height) catch {};
                    }
                    // Send resize with appropriate dimensions based on view type
                    if (@hasField(Msg, "resize")) {
                        const new_width: u32 = if (is_layout) renderer.term_width else renderer.term_width * 2;
                        const new_height: u32 = if (is_layout) renderer.term_height else renderer.term_height * 2;
                        const msg = @unionInit(Msg, "resize", Size{ .w = new_width, .h = new_height });
                        if (executeCmd(Module.update(model, msg, allocator))) return;
                    }
                }

                // Update timing
                const now = std.time.milliTimestamp();
                const dt = @as(f32, @floatFromInt(now - last_frame)) / 1000.0;
                last_frame = now;

                // Send tick if animating
                if (subs.animation_frame) {
                    if (msgFromTick(Msg, dt)) |msg| {
                        if (executeCmd(Module.update(model, msg, allocator))) return;
                    }
                }

                // Reset frame arena, rebuild view
                _ = frame_arena.reset(.retain_capacity);
                ui.ally = frame_arena.allocator();

                root = Module.view(model, &ui);

                // Render based on node type
                if (findCanvasRef(root)) |ref| {
                    // Canvas: render pixels
                    if (ref.render_fn) |render_fn| {
                        render_fn(ref.render_ctx);
                    }
                    try renderer.setPixels(ref.pixels.*, ref.width.*, ref.height.*);
                    try renderer.presentOptimized();

                    if (ref.overlay_text) |text| {
                        drawOverlayText(renderer.ttyfd, renderer.term_width, renderer.term_height, text);
                    }
                } else if (findLayoutRef(root)) |ref| {
                    // Layout: render text via draw commands
                    // Clear back buffer first to remove stale content
                    renderer.clearBackBuffer();

                    const bounds = Rect{
                        .x = 0,
                        .y = 0,
                        .w = @intCast(renderer.term_width),
                        .h = @intCast(renderer.term_height),
                    };

                    // Use renderTreeWithPositions to track widget locations
                    // This enables Effect.after.set_cursor to resolve absolute positions
                    const render_result = try renderTreeWithPositions(ref.node, bounds, frame_arena.allocator());
                    executeDrawCommands(renderer, render_result.commands);

                    // Skip output if terminal size changed during layout/drawing
                    // Query actual size right before output to catch late resizes
                    if (thermite.terminal.getCurrentSize(renderer.ttyfd)) |current| {
                        if (current.width != renderer.term_width or current.height != renderer.term_height) {
                            continue; // Size changed, let next frame handle it
                        }
                    }

                    try renderer.renderDifferential();

                    // Position and show cursor AFTER render
                    // First check for cursor from draw commands (widgets can emit show_cursor)
                    if (findCursorInCommands(render_result.commands)) |cursor| {
                        var pos_buf: [32]u8 = undefined;
                        const pos_seq = std.fmt.bufPrint(&pos_buf, "\x1b[{};{}H\x1b[?25h", .{ cursor.y + 1, cursor.x + 1 }) catch continue;
                        _ = std.posix.write(renderer.ttyfd, pos_seq) catch {};
                    } else if (ref.cursor_x) |cx| {
                        // Legacy: use explicit cursor position from layoutWithCursor
                        if (ref.cursor_y) |cy| {
                            var pos_buf: [32]u8 = undefined;
                            const pos_seq = std.fmt.bufPrint(&pos_buf, "\x1b[{};{}H\x1b[?25h", .{ cy + 1, cx + 1 }) catch continue;
                            _ = std.posix.write(renderer.ttyfd, pos_seq) catch {};
                        }
                    }

                    // Store widget_positions for Effect.after.set_cursor resolution
                    // (currently unused, but available for future Effect-based cursor handling)
                    _ = render_result.widget_positions;
                }

                // Frame pacing
                if (subs.animation_frame) {
                    const frame_time = std.time.milliTimestamp() - now;
                    const target: i64 = if (options.target_fps == 0) 1 else @divFloor(1000, options.target_fps);
                    if (frame_time < target) {
                        std.Thread.sleep(@intCast((target - frame_time) * std.time.ns_per_ms));
                    }
                }
            }
        }

        /// Find first canvas in view tree
        fn findCanvasRef(node: *Node) ?Node.CanvasRef {
            switch (node.data) {
                .canvas => |ref| return ref,
                .column => |children| {
                    for (children) |child| {
                        if (findCanvasRef(child)) |ref| return ref;
                    }
                },
                .row => |children| {
                    for (children) |child| {
                        if (findCanvasRef(child)) |ref| return ref;
                    }
                },
                .flex => |f| return findCanvasRef(f.child),
                .fixed => |f| return findCanvasRef(f.child),
                else => {},
            }
            return null;
        }

        /// Find first layout in view tree
        fn findLayoutRef(node: *Node) ?Node.LayoutRef {
            switch (node.data) {
                .layout => |ref| return ref,
                .column => |children| {
                    for (children) |child| {
                        if (findLayoutRef(child)) |ref| return ref;
                    }
                },
                .row => |children| {
                    for (children) |child| {
                        if (findLayoutRef(child)) |ref| return ref;
                    }
                },
                .flex => |f| return findLayoutRef(f.child),
                .fixed => |f| return findLayoutRef(f.child),
                else => {},
            }
            return null;
        }

        /// Execute draw commands on thermite renderer's back buffer
        fn executeDrawCommands(renderer: *thermite.Renderer, commands: []const DrawCommand) void {
            var cur_x: u32 = 0;
            var cur_y: u32 = 0;
            var cur_fg: u32 = thermite.DEFAULT_COLOR;
            var cur_bg: u32 = thermite.DEFAULT_COLOR;

            for (commands) |cmd| {
                switch (cmd) {
                    .move_cursor => |pos| {
                        cur_x = pos.x;
                        cur_y = pos.y;
                    },
                    .draw_text => |text| {
                        // Decode UTF-8 to get codepoints
                        var i: usize = 0;
                        while (i < text.text.len) {
                            const byte = text.text[i];
                            const codepoint_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
                            const codepoint = if (i + codepoint_len <= text.text.len)
                                std.unicode.utf8Decode(text.text[i..][0..codepoint_len]) catch byte
                            else
                                byte;

                            if (cur_x < renderer.term_width and cur_y < renderer.term_height) {
                                renderer.back_plane.setCell(cur_x, cur_y, .{
                                    .ch = codepoint,
                                    .fg = cur_fg,
                                    .bg = cur_bg,
                                });
                                cur_x += 1;
                            }
                            i += codepoint_len;
                        }
                    },
                    .clear_screen => {
                        renderer.clearBackBuffer();
                        cur_x = 0;
                        cur_y = 0;
                    },
                    .clear_line => {
                        var x = cur_x;
                        while (x < renderer.term_width) : (x += 1) {
                            renderer.back_plane.setCell(x, cur_y, thermite.Cell.init());
                        }
                    },
                    .set_color => |color| {
                        if (color.fg) |fg| cur_fg = @intFromEnum(fg);
                        if (color.bg) |bg| cur_bg = @intFromEnum(bg);
                    },
                    .reset_attributes => {
                        cur_fg = thermite.DEFAULT_COLOR;
                        cur_bg = thermite.DEFAULT_COLOR;
                    },
                    // show_cursor and flush are handled after renderDifferential
                    .show_cursor, .flush => {},
                    else => {},
                }
            }
        }

        /// Find first on_key handler in view tree (depth-first)
        fn findKeyHandler(node: *Node) ?*const anyopaque {
            // Check this node
            if (node.on_key) |handler| return handler;

            // Check children
            switch (node.data) {
                .column => |children| {
                    for (children) |child| {
                        if (findKeyHandler(child)) |h| return h;
                    }
                },
                .row => |children| {
                    for (children) |child| {
                        if (findKeyHandler(child)) |h| return h;
                    }
                },
                .flex => |f| return findKeyHandler(f.child),
                .fixed => |f| return findKeyHandler(f.child),
                else => {},
            }
            return null;
        }

        fn msgFromEvent(comptime M: type, event: Terminal.Event) ?M {
            return switch (event) {
                .key => |k| if (@hasField(M, "key")) @unionInit(M, "key", k) else null,
                .resize => |s| if (@hasField(M, "resize")) @unionInit(M, "resize", Size{ .w = s.w, .h = s.h }) else null,
            };
        }

        fn msgFromResize(comptime M: type, w: u32, h: u32) M {
            return @unionInit(M, "resize", Size{ .w = w, .h = h });
        }

        fn msgFromTick(comptime M: type, dt: f32) ?M {
            return if (@hasField(M, "tick")) @unionInit(M, "tick", dt) else null;
        }

        /// Execute a command, returns true if should quit
        fn executeCmd(cmd: Cmd) bool {
            switch (cmd) {
                .none => return false,
                .quit => return true,
                .batch => |cmds| {
                    for (cmds) |c| {
                        if (executeCmd(c)) return true;
                    }
                    return false;
                },
            }
        }

        /// Result of processing an Effect
        const EffectResult = struct {
            should_quit: bool = false,
            after_paint: ?Effect(Msg).AfterPaint = null,
        };

        /// Process an Effect, collecting dispatched messages and after-paint effects
        fn processEffect(
            effect: Effect(Msg),
            model: *Model,
            message_queue: *std.ArrayList(Msg),
        ) EffectResult {
            var result = EffectResult{};

            switch (effect) {
                .none => {},
                .quit => {
                    result.should_quit = true;
                },
                .dispatch => |msg| {
                    // Queue message for processing
                    message_queue.append(msg) catch {};
                },
                .after => |ap| {
                    result.after_paint = ap;
                },
                .batch => |effects| {
                    for (effects) |e| {
                        const sub_result = processEffect(e, model, message_queue);
                        if (sub_result.should_quit) result.should_quit = true;
                        if (sub_result.after_paint) |ap| result.after_paint = ap;
                    }
                },
            }

            return result;
        }

        /// Execute after-paint effect (cursor positioning, etc.)
        /// widget_positions is used to resolve Effect.set_cursor coordinates
        fn executeAfterPaint(ap: Effect(Msg).AfterPaint, fd: i32, widget_positions: []const WidgetPosition) void {
            switch (ap) {
                .set_cursor => |c| {
                    // Look up widget position from layout
                    var abs_x: u16 = c.x;
                    var abs_y: u16 = c.y;

                    // Find widget in position map and add screen offset
                    for (widget_positions) |wp| {
                        if (wp.widget_ptr == c.widget) {
                            abs_x = wp.bounds.x + c.x;
                            abs_y = wp.bounds.y + c.y;
                            break;
                        }
                    }

                    var buf: [32]u8 = undefined;
                    const seq = std.fmt.bufPrint(&buf, "\x1b[{};{}H\x1b[?25h", .{ abs_y + 1, abs_x + 1 }) catch return;
                    _ = std.posix.write(fd, seq) catch {};
                },
                .show_cursor => {
                    _ = std.posix.write(fd, "\x1b[?25h") catch {};
                },
                .hide_cursor => {
                    _ = std.posix.write(fd, "\x1b[?25l") catch {};
                },
            }
        }

        const CursorPos = struct { x: u16, y: u16 };

        /// Find cursor position from draw commands (look for show_cursor preceded by move_cursor)
        fn findCursorInCommands(commands: []const DrawCommand) ?CursorPos {
            var last_pos: ?CursorPos = null;
            for (commands) |cmd| {
                switch (cmd) {
                    .move_cursor => |pos| {
                        last_pos = .{ .x = pos.x, .y = pos.y };
                    },
                    .show_cursor => {
                        // Found show_cursor - return the last move_cursor position
                        return last_pos;
                    },
                    else => {},
                }
            }
            return null;
        }

        /// Draw overlay text at bottom of terminal (status bar)
        fn drawOverlayText(fd: i32, term_width: u32, term_height: u32, text: []const u8) void {
            if (term_width < 10 or term_height < 3) return;

            var buf: [32]u8 = undefined;
            // Move to bottom row, white on black
            const prefix = std.fmt.bufPrint(&buf, "\x1b[{};1H\x1b[97;40m", .{term_height}) catch return;
            _ = std.posix.write(fd, prefix) catch {};

            // Write text (truncated to terminal width)
            const write_len = @min(text.len, term_width);
            _ = std.posix.write(fd, text[0..write_len]) catch {};

            // Fill rest of line with spaces
            if (term_width > write_len) {
                var spaces: [256]u8 = undefined;
                const fill_len = @min(term_width - write_len, 256);
                @memset(spaces[0..fill_len], ' ');
                _ = std.posix.write(fd, spaces[0..fill_len]) catch {};
            }

            // Reset colors
            _ = std.posix.write(fd, "\x1b[0m") catch {};
        }

        fn renderToScreen(screen: *ScreenBuffer, root: *Node, width: u32, height: u32) void {
            // Simple layout: for now just handle full-screen canvas or text
            renderNode(screen, root, 0, 0, width, height);
        }

        fn renderNode(screen: *ScreenBuffer, node: *Node, x: u32, y: u32, w: u32, h: u32) void {
            switch (node.data) {
                .canvas => |ref| {
                    // Call render function first (draws to canvas)
                    if (ref.render_fn) |render| {
                        render(ref.render_ctx);
                    }
                    // Blit canvas pixels to screen using half-blocks
                    screen.blitCanvasRef(ref, x, y, w, h);
                },
                .text => |str| {
                    screen.drawText(str, x, y);
                },
                .column => |children| {
                    if (children.len == 0) return;
                    const child_h = h / @as(u32, @intCast(children.len));
                    for (children, 0..) |child, i| {
                        renderNode(screen, child, x, y + @as(u32, @intCast(i)) * child_h, w, child_h);
                    }
                },
                .row => |children| {
                    if (children.len == 0) return;
                    const child_w = w / @as(u32, @intCast(children.len));
                    for (children, 0..) |child, i| {
                        renderNode(screen, child, x + @as(u32, @intCast(i)) * child_w, y, child_w, h);
                    }
                },
                .flex => |f| {
                    renderNode(screen, f.child, x, y, w, h);
                },
                .fixed => |f| {
                    _ = f;
                    // TODO: handle fixed sizing
                },
                .layout => {
                    // Layout nodes are handled separately in runThermite/runSimple
                    // For now, just ignore in this legacy renderer
                },
            }
        }
    };
}

// ============================================
// Terminal abstraction (minimal for now)
// ============================================

// Global state for signal handler
var g_resize_pending: bool = false;
var g_terminal_fd: ?std.posix.fd_t = null;

const Terminal = struct {
    fd: std.posix.fd_t,
    width: u32,
    height: u32,
    original_termios: ?std.posix.termios,

    const TIOCGWINSZ = if (@import("builtin").os.tag == .macos) 0x40087468 else 0x5413;

    pub const Event = union(enum) {
        key: Key,
        resize: struct { w: u32, h: u32 },
    };

    pub fn init() !Terminal {
        // Open /dev/tty directly for terminal control
        const fd = try std.posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0);

        // Store fd for signal handler
        g_terminal_fd = fd;

        // Get terminal size
        var size = std.posix.winsize{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        _ = std.c.ioctl(fd, TIOCGWINSZ, @intFromPtr(&size));
        const width: u32 = if (size.col > 0) size.col else 80;
        const height: u32 = if (size.row > 0) size.row else 24;

        // Enter raw mode
        const original = try std.posix.tcgetattr(fd);
        var raw = original;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(fd, .FLUSH, raw);

        // Install SIGWINCH handler for resize
        const act = std.posix.Sigaction{
            .handler = .{ .handler = handleSigwinch },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.WINCH, &act, null);

        // Enter alt screen, hide cursor
        _ = try std.posix.write(fd, "\x1b[?1049h\x1b[?25l");

        return .{
            .fd = fd,
            .width = width,
            .height = height,
            .original_termios = original,
        };
    }

    fn handleSigwinch(_: c_int) callconv(.c) void {
        g_resize_pending = true;
    }

    pub fn deinit(self: *const Terminal) void {
        // Clear global state
        g_terminal_fd = null;

        // Restore terminal
        _ = std.posix.write(self.fd, "\x1b[?25h\x1b[?1049l") catch {};
        if (self.original_termios) |orig| {
            std.posix.tcsetattr(self.fd, .FLUSH, orig) catch {};
        }
        std.posix.close(self.fd);
    }

    /// Check for and consume resize event, returns new size if resized
    pub fn checkResize(self: *Terminal) ?Event {
        if (!g_resize_pending) return null;
        g_resize_pending = false;

        // Query new size
        var size = std.posix.winsize{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        _ = std.c.ioctl(self.fd, TIOCGWINSZ, @intFromPtr(&size));
        const new_width: u32 = if (size.col > 0) size.col else 80;
        const new_height: u32 = if (size.row > 0) size.row else 24;

        if (new_width != self.width or new_height != self.height) {
            self.width = new_width;
            self.height = new_height;
            return .{ .resize = .{ .w = new_width, .h = new_height } };
        }
        return null;
    }

    pub fn waitForEvent(self: *const Terminal) void {
        _ = self;
        // TODO: proper poll
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    pub fn pollEvent(self: *const Terminal) ?Event {
        var buf: [1]u8 = undefined;
        const n = std.posix.read(self.fd, &buf) catch return null;
        if (n == 0) return null;
        // Convert byte to Key (simple backend - no escape sequence parsing)
        const key: Key = switch (buf[0]) {
            1 => .ctrl_a,
            3 => .ctrl_c,
            4 => .ctrl_d,
            5 => .ctrl_e,
            11 => .ctrl_k,
            12 => .ctrl_l,
            15 => .ctrl_o,
            21 => .ctrl_u,
            23 => .ctrl_w,
            9 => .tab,
            10, 13 => .enter,
            27 => .escape,
            127 => .backspace,
            else => if (buf[0] >= 32 and buf[0] < 127) .{ .char = buf[0] } else .unknown,
        };
        return .{ .key = key };
    }

    pub fn present(self: *const Terminal, screen: *ScreenBuffer) !void {
        _ = try std.posix.write(self.fd, screen.buffer[0..screen.len]);
    }
};

// ============================================
// Screen buffer
// ============================================

const ScreenBuffer = struct {
    buffer: []u8,
    len: usize,
    width: u32,
    height: u32,

    pub fn init(allocator: Allocator, width: u32, height: u32) !ScreenBuffer {
        // Each cell needs ~45 bytes for full RGB color escape sequences
        // \x1b[38;2;RRR;GGG;BBB;48;2;RRR;GGG;BBBm▀ = ~43 bytes worst case
        const size = width * height * 50;
        const buffer = try allocator.alloc(u8, size);
        return .{
            .buffer = buffer,
            .len = 0,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *ScreenBuffer, allocator: Allocator) void {
        allocator.free(self.buffer);
    }

    pub fn resize(self: *ScreenBuffer, allocator: Allocator, width: u32, height: u32) !void {
        if (self.width == width and self.height == height) return;
        allocator.free(self.buffer);
        const size = width * height * 50;
        self.buffer = try allocator.alloc(u8, size);
        self.width = width;
        self.height = height;
        self.len = 0;
    }

    pub fn clear(self: *ScreenBuffer) void {
        self.len = 0;
        // Hide cursor, clear screen, home cursor
        self.append("\x1b[?25l\x1b[2J\x1b[H");
    }

    pub fn append(self: *ScreenBuffer, str: []const u8) void {
        if (self.len + str.len > self.buffer.len) return;
        @memcpy(self.buffer[self.len..][0..str.len], str);
        self.len += str.len;
    }

    pub fn drawText(self: *ScreenBuffer, str: []const u8, x: u32, y: u32) void {
        // Move cursor and write text
        var buf: [32]u8 = undefined;
        const pos = std.fmt.bufPrint(&buf, "\x1b[{};{}H", .{ y + 1, x + 1 }) catch return;
        self.append(pos);
        self.append(str);
    }

    /// Blit a type-erased canvas reference to screen
    pub fn blitCanvasRef(self: *ScreenBuffer, ref: Node.CanvasRef, x: u32, y: u32, w: u32, h: u32) void {
        _ = w;
        const pixels = ref.pixels.*;
        const canvas_width = ref.width.*;
        const canvas_height = ref.height.*;

        // Render canvas pixels using half-block characters
        // Each character cell represents 2 vertical pixels
        var row: u32 = 0;
        while (row < h and row * 2 + 1 < canvas_height) : (row += 1) {
            // Move to position
            var buf: [32]u8 = undefined;
            const pos = std.fmt.bufPrint(&buf, "\x1b[{};{}H", .{ y + row + 1, x + 1 }) catch continue;
            self.append(pos);

            var col: u32 = 0;
            while (col < canvas_width) : (col += 1) {
                const top_idx = row * 2 * canvas_width + col;
                const bot_idx = (row * 2 + 1) * canvas_width + col;

                const top = if (top_idx < pixels.len) pixels[top_idx] else 0;
                const bot = if (bot_idx < pixels.len) pixels[bot_idx] else 0;

                // Extract RGB (assuming RGBA format)
                const tr = (top >> 24) & 0xFF;
                const tg = (top >> 16) & 0xFF;
                const tb = (top >> 8) & 0xFF;
                const br = (bot >> 24) & 0xFF;
                const bg = (bot >> 16) & 0xFF;
                const bb = (bot >> 8) & 0xFF;

                // Set colors and write half-block
                var color_buf: [64]u8 = undefined;
                const color_str = std.fmt.bufPrint(&color_buf, "\x1b[38;2;{};{};{};48;2;{};{};{}m▀", .{ tr, tg, tb, br, bg, bb }) catch continue;
                self.append(color_str);
            }
        }
        self.append("\x1b[0m");
    }
};
