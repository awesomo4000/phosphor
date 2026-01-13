const std = @import("std");
const render_commands = @import("render_commands.zig");
const DrawCommand = render_commands.DrawCommand;
const BoxStyle = render_commands.BoxStyle;

// Thermite imports for ThermiteBackend
const thermite = @import("thermite/root.zig");
const ThermiteRenderer = thermite.Renderer;
const ThermiteCell = thermite.Cell;
const DEFAULT_COLOR = thermite.DEFAULT_COLOR;

/// Event types that backends produce
pub const Event = union(enum) {
    key: Key,
    resize: Size,
    paste_start,
    paste_end,
    tick,
    none,
};

pub const Key = union(enum) {
    char: u21,
    enter,
    backspace,
    delete,
    tab,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    ctrl_a,
    ctrl_c,
    ctrl_d,
    ctrl_e,
    ctrl_k,
    ctrl_l,
    ctrl_o,
    ctrl_u,
    ctrl_w,
    ctrl_left,
    ctrl_right,
    shift_enter,
    alt_enter,
    unknown,
};

pub const Size = struct {
    cols: u16,
    rows: u16,
};

/// Backend interface - abstracts terminal I/O for testing
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        execute: *const fn (ptr: *anyopaque, cmds: []const DrawCommand) void,
        readEvent: *const fn (ptr: *anyopaque) anyerror!?Event,
        getSize: *const fn (ptr: *anyopaque) Size,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn execute(self: Backend, cmds: []const DrawCommand) void {
        self.vtable.execute(self.ptr, cmds);
    }

    pub fn readEvent(self: Backend) !?Event {
        return self.vtable.readEvent(self.ptr);
    }

    pub fn getSize(self: Backend) Size {
        return self.vtable.getSize(self.ptr);
    }

    pub fn deinit(self: Backend) void {
        self.vtable.deinit(self.ptr);
    }
};

// ─────────────────────────────────────────────────────────────
// Terminal Backend - real terminal I/O
// ─────────────────────────────────────────────────────────────

pub const TerminalBackend = struct {
    const tui = @import("tui.zig");
    const TerminalState = @import("terminal_state.zig").TerminalState;

    terminal_state: ?TerminalState,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !TerminalBackend {
        var term = try TerminalState.init();
        TerminalState.global = null; // Will be set after storage
        try term.enableRawMode();

        var self = TerminalBackend{
            .terminal_state = term,
            .allocator = allocator,
        };

        // Set global pointer to our stored state
        TerminalState.global = &self.terminal_state.?;

        return self;
    }

    pub fn deinit(self: *TerminalBackend) void {
        if (self.terminal_state) |*state| {
            state.deinit();
            self.terminal_state = null;
        }
    }

    pub fn backend(self: *TerminalBackend) Backend {
        return .{
            .ptr = self,
            .vtable = &.{
                .execute = executeImpl,
                .readEvent = readEventImpl,
                .getSize = getSizeImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn executeImpl(ptr: *anyopaque, cmds: []const DrawCommand) void {
        _ = ptr;
        const tui_mod = @import("tui.zig");

        for (cmds) |cmd| {
            switch (cmd) {
                .move_cursor => |pos| {
                    tui_mod.moveTo(pos.x, pos.y) catch {};
                },
                .draw_text => |text| {
                    tui_mod.printText(text.text) catch {};
                },
                .draw_box => |box| {
                    tui_mod.drawBox(box.x, box.y, box.width, box.height, mapBoxStyle(box.style)) catch {};
                },
                .clear_screen => {
                    tui_mod.clearScreen() catch {};
                },
                .clear_line => {
                    tui_mod.printText("\x1b[K") catch {};
                },
                .set_color => |color| {
                    if (color.fg) |fg| {
                        if (color.bg) |bg| {
                            tui_mod.setColor(@intFromEnum(fg), @intFromEnum(bg)) catch {};
                        }
                    }
                },
                .reset_attributes => {
                    tui_mod.printText("\x1b[0m") catch {};
                },
                .show_cursor => |vis| {
                    tui_mod.showCursor(vis.visible) catch {};
                },
                .flush => {
                    tui_mod.flush() catch {};
                },
                else => {},
            }
        }
    }

    fn mapBoxStyle(style: BoxStyle) @import("tui.zig").BoxStyle {
        return switch (style) {
            .square => .Single,
            .rounded => .Rounded,
            .single => .Single,
            .double => .Double,
            .dotted => .Single,
            .heavy => .Single,
        };
    }

    fn readEventImpl(ptr: *anyopaque) anyerror!?Event {
        _ = ptr;
        // Use existing key reading logic
        return readKeyAsEvent();
    }

    fn getSizeImpl(ptr: *anyopaque) Size {
        _ = ptr;
        const tui_mod = @import("tui.zig");
        const size = tui_mod.getSize();
        return .{ .cols = size.cols, .rows = size.rows };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *TerminalBackend = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// Read a key and convert to Event
fn readKeyAsEvent() !?Event {
    const tui = @import("tui.zig");

    // Check for pending resize first (from SIGWINCH)
    if (tui.checkResize()) |new_size| {
        return .{ .resize = .{ .cols = new_size.cols, .rows = new_size.rows } };
    }

    const stdin = std.fs.File.stdin();
    const posix = std.posix;

    // Poll for input with 100ms timeout
    var pfd = [_]posix.pollfd{.{
        .fd = stdin.handle,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try posix.poll(&pfd, 100);
    if (ready == 0) {
        // Check for resize again after poll timeout
        if (tui.checkResize()) |new_size| {
            return .{ .resize = .{ .cols = new_size.cols, .rows = new_size.rows } };
        }
        return null; // Timeout
    }

    var buf: [1]u8 = undefined;
    _ = try stdin.read(&buf);
    const c = buf[0];

    // Control characters
    if (c < 32) {
        return .{ .key = switch (c) {
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
            27 => return readEscapeSequence(stdin),
            else => .unknown,
        } };
    }

    if (c == 127) {
        return .{ .key = .backspace };
    }

    if (c >= 32 and c < 127) {
        return .{ .key = .{ .char = c } };
    }

    // UTF-8
    if (c >= 0x80) {
        return readUtf8Event(stdin, c);
    }

    return .{ .key = .unknown };
}

fn readEscapeSequence(stdin: std.fs.File) !?Event {
    const posix = std.posix;

    var pfd = [_]posix.pollfd{.{
        .fd = stdin.handle,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const ready = try posix.poll(&pfd, 50);
    if (ready == 0) {
        return .{ .key = .escape };
    }

    var buf: [1]u8 = undefined;
    _ = try stdin.read(&buf);

    if (buf[0] == '[') {
        _ = try stdin.read(&buf);

        // Check for bracketed paste
        if (buf[0] == '2') {
            var seq: [3]u8 = undefined;
            _ = try stdin.read(&seq);
            if (seq[0] == '0' and seq[1] == '0' and seq[2] == '~') {
                return .paste_start;
            }
            if (seq[0] == '0' and seq[1] == '1' and seq[2] == '~') {
                return .paste_end;
            }
        }

        return .{ .key = switch (buf[0]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            '3' => blk: {
                _ = try stdin.read(&buf);
                if (buf[0] == '~') break :blk .delete;
                break :blk .unknown;
            },
            '1' => blk: {
                _ = try stdin.read(&buf);
                if (buf[0] == ';') {
                    _ = try stdin.read(&buf); // modifier
                    _ = try stdin.read(&buf); // direction
                    if (buf[0] == 'C') break :blk .ctrl_right;
                    if (buf[0] == 'D') break :blk .ctrl_left;
                }
                break :blk .unknown;
            },
            else => .unknown,
        } };
    }

    if (buf[0] == 'O') {
        _ = try stdin.read(&buf);
        return .{ .key = switch (buf[0]) {
            'H' => .home,
            'F' => .end,
            else => .unknown,
        } };
    }

    // Alt+Enter
    if (buf[0] == 13 or buf[0] == 10) {
        return .{ .key = .ctrl_o }; // Treat as newline insert
    }

    return .{ .key = .unknown };
}

fn readUtf8Event(stdin: std.fs.File, first_byte: u8) !?Event {
    const len: usize = if (first_byte & 0xF0 == 0xF0) 4 else if (first_byte & 0xE0 == 0xE0) 3 else if (first_byte & 0xC0 == 0xC0) 2 else return .{ .key = .unknown };

    var utf8_buf: [4]u8 = undefined;
    utf8_buf[0] = first_byte;

    const bytes_read = try stdin.read(utf8_buf[1..len]);
    if (bytes_read != len - 1) {
        return .{ .key = .unknown };
    }

    const codepoint = std.unicode.utf8Decode(utf8_buf[0..len]) catch return .{ .key = .unknown };
    return .{ .key = .{ .char = codepoint } };
}

// ─────────────────────────────────────────────────────────────
// Memory Backend - for testing
// ─────────────────────────────────────────────────────────────

pub const MemoryBackend = struct {
    cells: [][]Cell,
    width: u16,
    height: u16,
    cursor_x: u16,
    cursor_y: u16,
    event_queue: std.ArrayListUnmanaged(Event),
    allocator: std.mem.Allocator,

    pub const Cell = struct {
        char: u21 = ' ',
        fg: u8 = 7,
        bg: u8 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !MemoryBackend {
        var cells = try allocator.alloc([]Cell, height);
        for (0..height) |y| {
            cells[y] = try allocator.alloc(Cell, width);
            for (0..width) |x| {
                cells[y][x] = .{};
            }
        }

        return .{
            .cells = cells,
            .width = width,
            .height = height,
            .cursor_x = 0,
            .cursor_y = 0,
            .event_queue = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemoryBackend) void {
        for (self.cells) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.cells);
        self.event_queue.deinit(self.allocator);
    }

    pub fn backend(self: *MemoryBackend) Backend {
        return .{
            .ptr = self,
            .vtable = &.{
                .execute = executeImpl,
                .readEvent = readEventImpl,
                .getSize = getSizeImpl,
                .deinit = deinitImpl,
            },
        };
    }

    /// Inject an event for testing
    pub fn injectEvent(self: *MemoryBackend, event: Event) !void {
        try self.event_queue.append(self.allocator, event);
    }

    /// Get cell at position (for assertions)
    pub fn getCell(self: *const MemoryBackend, x: u16, y: u16) Cell {
        if (y >= self.height or x >= self.width) return .{};
        return self.cells[y][x];
    }

    /// Get line as string (for assertions)
    pub fn getLine(self: *const MemoryBackend, y: u16, allocator: std.mem.Allocator) ![]u8 {
        if (y >= self.height) return try allocator.alloc(u8, 0);

        var result: std.ArrayListUnmanaged(u8) = .{};
        defer result.deinit(allocator);

        for (self.cells[y]) |cell| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cell.char, &buf) catch continue;
            try result.appendSlice(allocator, buf[0..len]);
        }

        // Trim trailing spaces
        while (result.items.len > 0 and result.items[result.items.len - 1] == ' ') {
            _ = result.pop();
        }

        return result.toOwnedSlice(allocator);
    }

    fn executeImpl(ptr: *anyopaque, cmds: []const DrawCommand) void {
        const self: *MemoryBackend = @ptrCast(@alignCast(ptr));

        for (cmds) |cmd| {
            switch (cmd) {
                .move_cursor => |pos| {
                    self.cursor_x = @min(pos.x, self.width -| 1);
                    self.cursor_y = @min(pos.y, self.height -| 1);
                },
                .draw_text => |text| {
                    for (text.text) |c| {
                        if (self.cursor_x < self.width and self.cursor_y < self.height) {
                            self.cells[self.cursor_y][self.cursor_x].char = c;
                            self.cursor_x += 1;
                        }
                    }
                },
                .clear_screen => {
                    for (self.cells) |row| {
                        for (row) |*cell| {
                            cell.* = .{};
                        }
                    }
                    self.cursor_x = 0;
                    self.cursor_y = 0;
                },
                .clear_line => {
                    if (self.cursor_y < self.height) {
                        for (self.cursor_x..self.width) |x| {
                            self.cells[self.cursor_y][x] = .{};
                        }
                    }
                },
                else => {},
            }
        }
    }

    fn readEventImpl(ptr: *anyopaque) anyerror!?Event {
        const self: *MemoryBackend = @ptrCast(@alignCast(ptr));
        if (self.event_queue.items.len > 0) {
            return self.event_queue.orderedRemove(0);
        }
        return null;
    }

    fn getSizeImpl(ptr: *anyopaque) Size {
        const self: *MemoryBackend = @ptrCast(@alignCast(ptr));
        return .{ .cols = self.width, .rows = self.height };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *MemoryBackend = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

// ─────────────────────────────────────────────────────────────
// Thermite Backend - double-buffered differential rendering
// ─────────────────────────────────────────────────────────────

pub const ThermiteBackend = struct {
    renderer: *ThermiteRenderer,
    allocator: std.mem.Allocator,
    cursor_x: u32,
    cursor_y: u32,
    current_fg: u32,
    current_bg: u32,

    pub fn init(allocator: std.mem.Allocator) !ThermiteBackend {
        const tui = @import("tui.zig");

        const renderer = try ThermiteRenderer.init(allocator);

        // Install resize handler for SIGWINCH
        tui.installResizeHandler();

        return .{
            .renderer = renderer,
            .allocator = allocator,
            .cursor_x = 0,
            .cursor_y = 0,
            .current_fg = DEFAULT_COLOR, // Terminal default
            .current_bg = DEFAULT_COLOR, // Terminal default (transparent)
        };
    }

    pub fn deinit(self: *ThermiteBackend) void {
        self.renderer.deinit();
    }

    /// Handle terminal resize - reallocate planes for new size
    pub fn resize(self: *ThermiteBackend, new_size: Size) !void {
        const Plane = thermite.Plane;

        // Create new planes with new size
        const new_front = try Plane.init(self.allocator, new_size.cols, new_size.rows);
        errdefer new_front.deinit();

        const new_back = try Plane.init(self.allocator, new_size.cols, new_size.rows);
        errdefer new_back.deinit();

        // Free old planes
        self.renderer.front_plane.deinit();
        self.renderer.back_plane.deinit();

        // Update renderer with new planes
        self.renderer.front_plane = new_front;
        self.renderer.back_plane = new_back;
        self.renderer.term_width = new_size.cols;
        self.renderer.term_height = new_size.rows;
        self.renderer.first_frame = true; // Force full redraw

        // Reset cursor
        self.cursor_x = 0;
        self.cursor_y = 0;
    }

    pub fn backend(self: *ThermiteBackend) Backend {
        return .{
            .ptr = self,
            .vtable = &.{
                .execute = executeImpl,
                .readEvent = readEventImpl,
                .getSize = getSizeImpl,
                .deinit = deinitImpl,
            },
        };
    }

    /// Present the back buffer - call this after execute to show changes
    pub fn present(self: *ThermiteBackend) !void {
        try self.renderer.renderDifferential();
    }

    fn executeImpl(ptr: *anyopaque, cmds: []const DrawCommand) void {
        const self: *ThermiteBackend = @ptrCast(@alignCast(ptr));

        for (cmds) |cmd| {
            switch (cmd) {
                .move_cursor => |pos| {
                    self.cursor_x = pos.x;
                    self.cursor_y = pos.y;
                },
                .draw_text => |text| {
                    self.writeText(text.text);
                },
                .clear_screen => {
                    self.renderer.clearBackBuffer();
                    self.cursor_x = 0;
                    self.cursor_y = 0;
                },
                .clear_line => {
                    self.clearLine();
                },
                .set_color => |color| {
                    if (color.fg) |fg| {
                        self.current_fg = colorToRgb(fg);
                    }
                    if (color.bg) |bg| {
                        self.current_bg = colorToRgb(bg);
                    }
                },
                .reset_attributes => {
                    self.current_fg = DEFAULT_COLOR;
                    self.current_bg = DEFAULT_COLOR;
                },
                .flush => {
                    // Present on flush
                    self.present() catch {};
                },
                .show_cursor => {
                    // Thermite handles cursor separately
                },
                else => {},
            }
        }
    }

    fn writeText(self: *ThermiteBackend, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            const byte = text[i];

            if (byte == '\n') {
                self.cursor_y += 1;
                self.cursor_x = 0;
                i += 1;
                continue;
            }

            // Decode UTF-8 to get codepoint and byte length
            const codepoint_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            const codepoint = if (i + codepoint_len <= text.len)
                std.unicode.utf8Decode(text[i..][0..codepoint_len]) catch byte
            else
                byte;

            if (self.cursor_x < self.renderer.term_width and
                self.cursor_y < self.renderer.term_height)
            {
                self.renderer.back_plane.setCell(self.cursor_x, self.cursor_y, .{
                    .ch = codepoint,
                    .fg = self.current_fg,
                    .bg = self.current_bg,
                });
                self.cursor_x += 1;
            }

            i += codepoint_len;
        }
    }

    fn clearLine(self: *ThermiteBackend) void {
        if (self.cursor_y >= self.renderer.term_height) return;

        var x = self.cursor_x;
        while (x < self.renderer.term_width) : (x += 1) {
            self.renderer.back_plane.setCell(x, self.cursor_y, ThermiteCell.init());
        }
    }

    fn colorToRgb(color: render_commands.Color) u32 {
        // Convert CGA Color enum to RGB
        return switch (color) {
            .black => 0x000000,
            .blue => 0x0000AA,
            .green => 0x00AA00,
            .cyan => 0x00AAAA,
            .red => 0xAA0000,
            .magenta => 0xAA00AA,
            .brown => 0xAA5500,
            .light_gray => 0xAAAAAA,
            .dark_gray => 0x555555,
            .light_blue => 0x5555FF,
            .light_green => 0x55FF55,
            .light_cyan => 0x55FFFF,
            .light_red => 0xFF5555,
            .light_magenta => 0xFF55FF,
            .yellow => 0xFFFF55,
            .white => 0xFFFFFF,
        };
    }

    fn readEventImpl(ptr: *anyopaque) anyerror!?Event {
        _ = ptr;
        // Use the shared key reading logic
        return readKeyAsEvent();
    }

    fn getSizeImpl(ptr: *anyopaque) Size {
        const self: *ThermiteBackend = @ptrCast(@alignCast(ptr));
        return .{
            .cols = @intCast(self.renderer.term_width),
            .rows = @intCast(self.renderer.term_height),
        };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *ThermiteBackend = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

test "MemoryBackend basic operations" {
    var mem = try MemoryBackend.init(std.testing.allocator, 40, 10);
    defer mem.deinit();

    const b = mem.backend();

    b.execute(&.{
        .{ .move_cursor = .{ .x = 5, .y = 2 } },
        .{ .draw_text = .{ .text = "Hello" } },
    });

    try std.testing.expectEqual(@as(u21, 'H'), mem.getCell(5, 2).char);
    try std.testing.expectEqual(@as(u21, 'o'), mem.getCell(9, 2).char);
}

test "MemoryBackend event injection" {
    var mem = try MemoryBackend.init(std.testing.allocator, 40, 10);
    defer mem.deinit();

    try mem.injectEvent(.{ .key = .{ .char = 'a' } });
    try mem.injectEvent(.{ .key = .enter });

    const b = mem.backend();

    const e1 = try b.readEvent();
    try std.testing.expect(e1 != null);
    try std.testing.expectEqual(Key{ .char = 'a' }, e1.?.key);

    const e2 = try b.readEvent();
    try std.testing.expect(e2 != null);
    try std.testing.expectEqual(Key.enter, e2.?.key);

    const e3 = try b.readEvent();
    try std.testing.expect(e3 == null);
}

test "MemoryBackend getLine" {
    var mem = try MemoryBackend.init(std.testing.allocator, 40, 10);
    defer mem.deinit();

    mem.backend().execute(&.{
        .{ .move_cursor = .{ .x = 0, .y = 0 } },
        .{ .draw_text = .{ .text = "Test Line" } },
    });

    const line = try mem.getLine(0, std.testing.allocator);
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("Test Line", line);
}
