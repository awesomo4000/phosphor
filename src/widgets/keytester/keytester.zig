const std = @import("std");
const Allocator = std.mem.Allocator;
const phosphor = @import("phosphor");
const LayoutNode = phosphor.LayoutNode;
const LocalWidgetVTable = phosphor.LocalWidgetVTable;
const LayoutSize = phosphor.LayoutSize;
const DrawCommand = phosphor.DrawCommand;
const Key = phosphor.Key;

/// A widget that displays the last key pressed with its tag name and value.
/// Useful for debugging key input and learning the Key API.
pub const KeyTester = struct {
    allocator: Allocator,
    last_key: ?Key = null,
    display_buf: [256]u8 = undefined,
    display_len: usize = 0,

    pub fn init(allocator: Allocator) KeyTester {
        var self = KeyTester{
            .allocator = allocator,
        };
        self.updateDisplay();
        return self;
    }

    pub fn deinit(self: *KeyTester) void {
        _ = self;
        // Nothing to free - we use a fixed buffer
    }

    /// Record a key press and update the display
    pub fn recordKey(self: *KeyTester, key: Key) void {
        self.last_key = key;
        self.updateDisplay();
    }

    /// Get the current display text
    pub fn getText(self: *const KeyTester) []const u8 {
        return self.display_buf[0..self.display_len];
    }

    /// Update the display buffer with the current key info
    fn updateDisplay(self: *KeyTester) void {
        if (self.last_key) |key| {
            const tag = @tagName(key);

            // Format: key name followed by hex code
            self.display_len = switch (key) {
                .char => |c| blk: {
                    if (c >= 32 and c < 127) {
                        break :blk (std.fmt.bufPrint(&self.display_buf, " {s} '{c}'  0x{X:0>2} ", .{ tag, @as(u8, @intCast(c)), c }) catch &self.display_buf).len;
                    } else {
                        break :blk (std.fmt.bufPrint(&self.display_buf, " {s}  0x{X:0>4} ", .{ tag, c }) catch &self.display_buf).len;
                    }
                },
                .f => |n| (std.fmt.bufPrint(&self.display_buf, " F{}  (esc seq) ", .{n}) catch &self.display_buf).len,
                .alt => |c| blk: {
                    if (c >= 32 and c < 127) {
                        break :blk (std.fmt.bufPrint(&self.display_buf, " alt '{c}'  0x1B{X:0>2} ", .{ @as(u8, @intCast(c)), c }) catch &self.display_buf).len;
                    } else {
                        break :blk (std.fmt.bufPrint(&self.display_buf, " alt  0x1B{X:0>4} ", .{c}) catch &self.display_buf).len;
                    }
                },
                // Control keys with known byte values
                .ctrl_a => (std.fmt.bufPrint(&self.display_buf, " {s}  0x01 ", .{tag}) catch &self.display_buf).len,
                .ctrl_b => (std.fmt.bufPrint(&self.display_buf, " {s}  0x02 ", .{tag}) catch &self.display_buf).len,
                .ctrl_c => (std.fmt.bufPrint(&self.display_buf, " {s}  0x03 ", .{tag}) catch &self.display_buf).len,
                .ctrl_d => (std.fmt.bufPrint(&self.display_buf, " {s}  0x04 ", .{tag}) catch &self.display_buf).len,
                .ctrl_e => (std.fmt.bufPrint(&self.display_buf, " {s}  0x05 ", .{tag}) catch &self.display_buf).len,
                .ctrl_f => (std.fmt.bufPrint(&self.display_buf, " {s}  0x06 ", .{tag}) catch &self.display_buf).len,
                .ctrl_g => (std.fmt.bufPrint(&self.display_buf, " {s}  0x07 ", .{tag}) catch &self.display_buf).len,
                .ctrl_h => (std.fmt.bufPrint(&self.display_buf, " {s}  0x08 ", .{tag}) catch &self.display_buf).len,
                .ctrl_i => (std.fmt.bufPrint(&self.display_buf, " {s}  0x09 ", .{tag}) catch &self.display_buf).len,
                .ctrl_j => (std.fmt.bufPrint(&self.display_buf, " {s}  0x0A ", .{tag}) catch &self.display_buf).len,
                .ctrl_k => (std.fmt.bufPrint(&self.display_buf, " {s}  0x0B ", .{tag}) catch &self.display_buf).len,
                .ctrl_l => (std.fmt.bufPrint(&self.display_buf, " {s}  0x0C ", .{tag}) catch &self.display_buf).len,
                .ctrl_m => (std.fmt.bufPrint(&self.display_buf, " {s}  0x0D ", .{tag}) catch &self.display_buf).len,
                .ctrl_n => (std.fmt.bufPrint(&self.display_buf, " {s}  0x0E ", .{tag}) catch &self.display_buf).len,
                .ctrl_o => (std.fmt.bufPrint(&self.display_buf, " {s}  0x0F ", .{tag}) catch &self.display_buf).len,
                .ctrl_p => (std.fmt.bufPrint(&self.display_buf, " {s}  0x10 ", .{tag}) catch &self.display_buf).len,
                .ctrl_q => (std.fmt.bufPrint(&self.display_buf, " {s}  0x11 ", .{tag}) catch &self.display_buf).len,
                .ctrl_r => (std.fmt.bufPrint(&self.display_buf, " {s}  0x12 ", .{tag}) catch &self.display_buf).len,
                .ctrl_s => (std.fmt.bufPrint(&self.display_buf, " {s}  0x13 ", .{tag}) catch &self.display_buf).len,
                .ctrl_t => (std.fmt.bufPrint(&self.display_buf, " {s}  0x14 ", .{tag}) catch &self.display_buf).len,
                .ctrl_u => (std.fmt.bufPrint(&self.display_buf, " {s}  0x15 ", .{tag}) catch &self.display_buf).len,
                .ctrl_v => (std.fmt.bufPrint(&self.display_buf, " {s}  0x16 ", .{tag}) catch &self.display_buf).len,
                .ctrl_w => (std.fmt.bufPrint(&self.display_buf, " {s}  0x17 ", .{tag}) catch &self.display_buf).len,
                .ctrl_x => (std.fmt.bufPrint(&self.display_buf, " {s}  0x18 ", .{tag}) catch &self.display_buf).len,
                .ctrl_y => (std.fmt.bufPrint(&self.display_buf, " {s}  0x19 ", .{tag}) catch &self.display_buf).len,
                .ctrl_z => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1A ", .{tag}) catch &self.display_buf).len,
                // Special keys
                .enter => (std.fmt.bufPrint(&self.display_buf, " {s}  0x0D ", .{tag}) catch &self.display_buf).len,
                .backspace => (std.fmt.bufPrint(&self.display_buf, " {s}  0x7F ", .{tag}) catch &self.display_buf).len,
                .tab => (std.fmt.bufPrint(&self.display_buf, " {s}  0x09 ", .{tag}) catch &self.display_buf).len,
                .escape => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B ", .{tag}) catch &self.display_buf).len,
                .delete => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B337E ", .{tag}) catch &self.display_buf).len,
                .insert => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B327E ", .{tag}) catch &self.display_buf).len,
                // Arrow keys
                .up => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B41 ", .{tag}) catch &self.display_buf).len,
                .down => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B42 ", .{tag}) catch &self.display_buf).len,
                .right => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B43 ", .{tag}) catch &self.display_buf).len,
                .left => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B44 ", .{tag}) catch &self.display_buf).len,
                .home => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B48 ", .{tag}) catch &self.display_buf).len,
                .end => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B46 ", .{tag}) catch &self.display_buf).len,
                .page_up => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B357E ", .{tag}) catch &self.display_buf).len,
                .page_down => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B367E ", .{tag}) catch &self.display_buf).len,
                // Ctrl + arrow/nav
                .ctrl_left => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B313B3544 ", .{tag}) catch &self.display_buf).len,
                .ctrl_right => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B313B3543 ", .{tag}) catch &self.display_buf).len,
                .ctrl_up => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B313B3541 ", .{tag}) catch &self.display_buf).len,
                .ctrl_down => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B313B3542 ", .{tag}) catch &self.display_buf).len,
                .ctrl_home => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B313B3548 ", .{tag}) catch &self.display_buf).len,
                .ctrl_end => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B313B3546 ", .{tag}) catch &self.display_buf).len,
                // Shift/Alt combos
                .shift_tab => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B5A ", .{tag}) catch &self.display_buf).len,
                .shift_enter => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B5B32376D ", .{tag}) catch &self.display_buf).len,
                .alt_enter => (std.fmt.bufPrint(&self.display_buf, " {s}  0x1B0D ", .{tag}) catch &self.display_buf).len,
                // Fallback for unknown - show the raw byte
                .unknown => |b| (std.fmt.bufPrint(&self.display_buf, " {s}  0x{X:0>2} ", .{ tag, b }) catch &self.display_buf).len,
            };
        } else {
            self.display_len = (std.fmt.bufPrint(&self.display_buf, " (press a key) ", .{}) catch &self.display_buf).len;
        }
    }

    // ─────────────────────────────────────────────────────────────
    // LocalWidget interface (draws at 0,0, layout translates)
    // ─────────────────────────────────────────────────────────────

    /// Get a LocalWidgetVTable for use with LayoutNode.localWidget()
    pub fn localWidget(self: *KeyTester) LocalWidgetVTable {
        return .{
            .ptr = self,
            .getPreferredHeightFn = getPreferredHeight,
            .viewFn = view,
        };
    }

    fn getPreferredHeight(_: *anyopaque, _: u16) u16 {
        return 1; // Always single line
    }

    /// Render at local coordinates (0,0). Layout will translate.
    fn view(ptr: *anyopaque, size: LayoutSize, alloc: Allocator) ![]DrawCommand {
        const self: *KeyTester = @ptrCast(@alignCast(ptr));
        self.updateDisplay();

        var commands = try alloc.alloc(DrawCommand, 2);
        // Draw at (0,0) - layout handles positioning
        commands[0] = .{ .move_cursor = .{ .x = 0, .y = 0 } };
        // Truncate to width if needed
        const text = self.getText();
        const display_len = @min(text.len, size.w);
        commands[1] = .{ .draw_text = .{ .text = text[0..display_len] } };
        return commands;
    }

    // ─────────────────────────────────────────────────────────────
    // Legacy viewTree interface (for backwards compatibility)
    // ─────────────────────────────────────────────────────────────

    /// Returns a single-line LayoutNode showing the key info
    pub fn viewTree(self: *KeyTester, frame_alloc: Allocator) !ViewTree {
        _ = frame_alloc;
        self.updateDisplay();
        return ViewTree{ .keytester = self };
    }

    pub const ViewTree = struct {
        keytester: *KeyTester,

        /// Build a local widget node
        pub fn build(self: *const ViewTree) LayoutNode {
            return LayoutNode.localWidgetSized(
                self.keytester.localWidget(),
                .{ .w = .{ .grow = .{} }, .h = .{ .fixed = 1 } },
            );
        }

        pub fn getHeight(_: *const ViewTree) u16 {
            return 1;
        }
    };
};

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

test "basic key recording" {
    var kt = KeyTester.init(std.testing.allocator);
    defer kt.deinit();

    // Initial state
    try std.testing.expect(kt.last_key == null);

    // Record a key
    kt.recordKey(.{ .char = 'a' });
    try std.testing.expect(kt.last_key != null);

    // Text should contain the key info
    const text = kt.getText();
    try std.testing.expect(text.len > 0);
}

test "special keys" {
    var kt = KeyTester.init(std.testing.allocator);
    defer kt.deinit();

    kt.recordKey(.enter);
    try std.testing.expect(std.mem.indexOf(u8, kt.getText(), "enter") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.getText(), "0x0D") != null);

    kt.recordKey(.ctrl_c);
    try std.testing.expect(std.mem.indexOf(u8, kt.getText(), "ctrl_c") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.getText(), "0x03") != null);

    kt.recordKey(.left);
    try std.testing.expect(std.mem.indexOf(u8, kt.getText(), "left") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.getText(), "0x1B5B44") != null);
}
