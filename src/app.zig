const std = @import("std");
const Allocator = std.mem.Allocator;
const thermite = @import("thermite");

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

/// Subscriptions - what events the app wants
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

/// Commands - side effects returned from update
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
    on_key: ?*const anyopaque = null, // fn(u8) Msg
    on_click: ?*const anyopaque = null, // fn() Msg

    pub const Data = union(enum) {
        text: []const u8,
        canvas: CanvasRef,
        column: []*Node,
        row: []*Node,
        flex: Flex,
        fixed: Fixed,
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
        on_key: ?*const fn (u8) Msg = null,
        on_click: ?*const fn () Msg = null,
        on_mouse: ?*const fn (u16, u16) Msg = null, // x, y
        overlay_text: ?[]const u8 = null, // status bar text drawn at bottom
    };
}

/// UI builder - holds allocator, provides node constructors
pub const Ui = struct {
    ally: Allocator,

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
                                const typed_handler: *const fn (u8) Msg = @ptrCast(@alignCast(handler));
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

            // Get initial pixel resolution
            const max_res = renderer.maxResolution();
            var pixel_width = max_res.width;
            var pixel_height = max_res.height;

            // UI builder using frame arena
            var ui = Ui{ .ally = frame_arena.allocator() };

            // Timing
            var last_frame = std.time.milliTimestamp();

            // Send initial resize (pixel dimensions)
            if (executeCmd(Module.update(model, msgFromResize(Msg, pixel_width, pixel_height), allocator))) return;

            // Build initial view
            var root = Module.view(model, &ui);

            const term_fd = renderer.getTerminalFd();

            // Event loop
            while (true) {
                const subs = Module.subs(model);

                // Input handling
                if (subs.animation_frame) {
                    // Non-blocking key check when animating
                    if (thermite.terminal.readKey(term_fd)) |key| {
                        if (findKeyHandler(root)) |handler| {
                            const typed_handler: *const fn (u8) Msg = @ptrCast(@alignCast(handler));
                            if (executeCmd(Module.update(model, typed_handler(key), allocator))) return;
                        } else if (@hasField(Msg, "key")) {
                            if (executeCmd(Module.update(model, @unionInit(Msg, "key", key), allocator))) return;
                        }
                    }
                } else {
                    // Blocking poll when not animating
                    switch (thermite.terminal.pollInput(term_fd, 100) catch .timeout) {
                        .ready => {
                            if (thermite.terminal.readKey(term_fd)) |key| {
                                if (findKeyHandler(root)) |handler| {
                                    const typed_handler: *const fn (u8) Msg = @ptrCast(@alignCast(handler));
                                    if (executeCmd(Module.update(model, typed_handler(key), allocator))) return;
                                } else if (@hasField(Msg, "key")) {
                                    if (executeCmd(Module.update(model, @unionInit(Msg, "key", key), allocator))) return;
                                }
                            }
                        },
                        .resize, .timeout => {},
                    }
                }

                // Check for terminal resize
                if (renderer.checkResize()) |new_res| {
                    pixel_width = new_res.width;
                    pixel_height = new_res.height;
                    if (@hasField(Msg, "resize")) {
                        const msg = @unionInit(Msg, "resize", Size{ .w = pixel_width, .h = pixel_height });
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

                // Render: find canvas in view tree and send to thermite
                if (findCanvasRef(root)) |ref| {
                    // Call render function
                    if (ref.render_fn) |render_fn| {
                        render_fn(ref.render_ctx);
                    }
                    // Send pixels to thermite
                    try renderer.setPixels(ref.pixels.*, ref.width.*, ref.height.*);
                    try renderer.presentOptimized();

                    // Draw overlay text (status bar) if present
                    if (ref.overlay_text) |text| {
                        drawOverlayText(renderer.ttyfd, renderer.term_width, renderer.term_height, text);
                    }
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
        key: u8,
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
        return .{ .key = buf[0] };
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
