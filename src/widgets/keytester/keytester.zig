const std = @import("std");
const Allocator = std.mem.Allocator;
const phosphor = @import("phosphor");
const LayoutNode = phosphor.LayoutNode;
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
    // Declarative view (returns LayoutNode)
    // ─────────────────────────────────────────────────────────────

    /// Returns a single-line LayoutNode showing the key info
    pub fn viewTree(self: *KeyTester, frame_alloc: Allocator) !ViewTree {
        _ = frame_alloc;
        // Update display before returning
        self.updateDisplay();

        return ViewTree{
            .text = self.getText(),
        };
    }

    pub const ViewTree = struct {
        text: []const u8,

        /// Build a text node for the key display
        pub fn build(self: *const ViewTree) LayoutNode {
            var node = LayoutNode.text(self.text);
            node.sizing.h = .{ .fixed = 1 };
            return node;
        }

        pub fn getHeight(self: *const ViewTree) u16 {
            _ = self;
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
