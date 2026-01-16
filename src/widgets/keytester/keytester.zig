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

            // Format based on whether the key has a payload
            self.display_len = switch (key) {
                .char => |c| blk: {
                    if (c >= 32 and c < 127) {
                        break :blk (std.fmt.bufPrint(&self.display_buf, " Key: .{{ .{s} = '{c}' }}  (0x{X:0>2}) ", .{ tag, @as(u8, @intCast(c)), c }) catch &self.display_buf).len;
                    } else {
                        break :blk (std.fmt.bufPrint(&self.display_buf, " Key: .{{ .{s} = 0x{X:0>4} }} ", .{ tag, c }) catch &self.display_buf).len;
                    }
                },
                .f => |n| (std.fmt.bufPrint(&self.display_buf, " Key: .{{ .{s} = {} }}  (F{}) ", .{ tag, n, n }) catch &self.display_buf).len,
                .alt => |c| blk: {
                    if (c >= 32 and c < 127) {
                        break :blk (std.fmt.bufPrint(&self.display_buf, " Key: .{{ .{s} = '{c}' }}  (Alt+{c}) ", .{ tag, @as(u8, @intCast(c)), @as(u8, @intCast(c)) }) catch &self.display_buf).len;
                    } else {
                        break :blk (std.fmt.bufPrint(&self.display_buf, " Key: .{{ .{s} = 0x{X:0>4} }} ", .{ tag, c }) catch &self.display_buf).len;
                    }
                },
                else => (std.fmt.bufPrint(&self.display_buf, " Key: .{s} ", .{tag}) catch &self.display_buf).len,
            };
        } else {
            self.display_len = (std.fmt.bufPrint(&self.display_buf, " Key: (press a key to test) ", .{}) catch &self.display_buf).len;
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
    try std.testing.expect(std.mem.indexOf(u8, kt.getText(), ".enter") != null);

    kt.recordKey(.ctrl_c);
    try std.testing.expect(std.mem.indexOf(u8, kt.getText(), ".ctrl_c") != null);

    kt.recordKey(.left);
    try std.testing.expect(std.mem.indexOf(u8, kt.getText(), ".left") != null);
}
