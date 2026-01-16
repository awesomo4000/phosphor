const std = @import("std");

/// Effect - declarative side effects returned from update
/// Effects tell the runtime what to do, rather than doing it directly.
/// This enables pure update functions and predictable state management.
pub fn Effect(comptime Msg: type) type {
    return union(enum) {
        /// No effect
        none,

        /// Exit the application
        quit,

        /// Queue a message for the next update cycle
        /// This goes through the message queue, maintaining proper ordering
        dispatch: Msg,

        /// Combine multiple effects
        batch: []const Effect(Msg),

        /// Effects that MUST run after paint completes
        after: AfterPaint,

        const Self = @This();

        /// Effects executed after rendering is complete
        pub const AfterPaint = union(enum) {
            /// Position the terminal cursor (for text input, etc.)
            /// Coordinates are local to widget; runtime resolves to screen position
            set_cursor: struct {
                widget: *anyopaque, // Widget pointer for position lookup
                x: u16, // Local x coordinate
                y: u16, // Local y coordinate
            },

            /// Show the terminal cursor
            show_cursor,

            /// Hide the terminal cursor
            hide_cursor,

            // Future:
            // ring_bell,
            // set_title: []const u8,
            // copy_to_clipboard: []const u8,
        };

        /// Transform the message type using a mapping function
        /// Used for child-to-parent message wrapping
        pub fn mapMsg(self: Self, comptime NewMsg: type, comptime f: *const fn (Msg) NewMsg) Effect(NewMsg) {
            return switch (self) {
                .none => .none,
                .quit => .quit,
                .dispatch => |msg| .{ .dispatch = f(msg) },
                .batch => |effects| blk: {
                    // Note: This allocates - caller should use frame allocator
                    var mapped = std.heap.page_allocator.alloc(Effect(NewMsg), effects.len) catch return .none;
                    for (effects, 0..) |e, i| {
                        mapped[i] = e.mapMsg(NewMsg, f);
                    }
                    break :blk .{ .batch = mapped };
                },
                .after => |ap| .{ .after = ap },
            };
        }

        /// Convenience for creating cursor effect
        pub fn setCursor(widget: anytype, x: u16, y: u16) Self {
            return .{ .after = .{ .set_cursor = .{
                .widget = @ptrCast(widget),
                .x = x,
                .y = y,
            } } };
        }

        /// Convenience for batching effects
        pub fn batchEffects(effects: []const Self) Self {
            return .{ .batch = effects };
        }
    };
}

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

test "effect none" {
    const Msg = enum { foo, bar };
    const e: Effect(Msg) = .none;
    try std.testing.expectEqual(Effect(Msg).none, e);
}

test "effect dispatch" {
    const Msg = union(enum) {
        clicked: u32,
        typed: u8,
    };
    const e: Effect(Msg) = .{ .dispatch = .{ .clicked = 42 } };
    switch (e) {
        .dispatch => |msg| {
            try std.testing.expectEqual(@as(u32, 42), msg.clicked);
        },
        else => try std.testing.expect(false),
    }
}

test "effect after set_cursor" {
    const Msg = enum { foo };
    var dummy: u32 = 0;
    const e = Effect(Msg).setCursor(&dummy, 10, 20);
    switch (e) {
        .after => |ap| switch (ap) {
            .set_cursor => |c| {
                try std.testing.expectEqual(@as(u16, 10), c.x);
                try std.testing.expectEqual(@as(u16, 20), c.y);
            },
            else => try std.testing.expect(false),
        },
        else => try std.testing.expect(false),
    }
}
