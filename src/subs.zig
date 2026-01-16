const std = @import("std");
const Key = @import("thermite").terminal.Key;

/// Terminal size
pub const Size = struct {
    w: u32,
    h: u32,
};

/// Subscriptions - declare what events the app wants and how to wrap them
/// Each subscription specifies a message constructor that wraps the event data.
pub fn Subs(comptime Msg: type) type {
    return struct {
        /// Keyboard events - wrapper takes Key, returns Msg
        keyboard: ?*const fn (Key) Msg = null,

        /// Resize events - wrapper takes Size, returns Msg
        resize: ?*const fn (Size) Msg = null,

        /// Animation frame events - wrapper takes delta time (f32), returns Msg
        animation_frame: ?*const fn (f32) Msg = null,

        /// Paste events (bracketed paste mode)
        paste: ?*const fn ([]const u8) Msg = null,

        // Future:
        // mouse: ?*const fn (MouseEvent) Msg = null,
        // timer: ?*const fn (TimerId) Msg = null,

        const Self = @This();

        /// No subscriptions
        pub const none: Self = .{};

        /// Convenience for keyboard-only subscription
        pub fn keyboardOnly(wrapper: *const fn (Key) Msg) Self {
            return .{ .keyboard = wrapper };
        }

        /// Convenience for keyboard + resize
        pub fn interactive(
            key_wrapper: *const fn (Key) Msg,
            resize_wrapper: *const fn (Size) Msg,
        ) Self {
            return .{
                .keyboard = key_wrapper,
                .resize = resize_wrapper,
            };
        }

        /// Convenience for animated apps
        pub fn animated(
            key_wrapper: ?*const fn (Key) Msg,
            resize_wrapper: ?*const fn (Size) Msg,
            tick_wrapper: *const fn (f32) Msg,
        ) Self {
            return .{
                .keyboard = key_wrapper,
                .resize = resize_wrapper,
                .animation_frame = tick_wrapper,
            };
        }
    };
}

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

test "subs none" {
    const Msg = enum { foo };
    const s = Subs(Msg).none;
    try std.testing.expect(s.keyboard == null);
    try std.testing.expect(s.resize == null);
}

test "subs keyboard wrapper" {
    const Msg = union(enum) {
        key_pressed: Key,
        other,
    };

    const wrapper = struct {
        fn wrap(key: Key) Msg {
            return .{ .key_pressed = key };
        }
    }.wrap;

    const s = Subs(Msg).keyboardOnly(wrapper);
    try std.testing.expect(s.keyboard != null);

    // Test the wrapper works
    const msg = s.keyboard.?(.enter);
    try std.testing.expectEqual(Msg{ .key_pressed = .enter }, msg);
}
