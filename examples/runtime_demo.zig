/// Runtime Demo - Test the new queue-based threaded runtime
///
/// This demo validates:
/// - Input thread reads keys and pushes to queue
/// - Main loop drains queue and calls update
/// - Context provides time, frame, size
/// - Effect.quit stops the runtime
///
const std = @import("std");
const phosphor = @import("phosphor");

const Runtime = phosphor.runtime.Runtime;
const Context = phosphor.runtime.Context;
const Effect = phosphor.runtime.Effect;
const Key = phosphor.runtime.Key;

// ─────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────

const Model = struct {
    last_key: ?Key = null,
    key_count: u32 = 0,
    start_time: i64 = 0,
};

// ─────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────

const Msg = union(enum) {
    key: Key,
    resize: phosphor.runtime.Size,
    tick,
};

// ─────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────

fn update(model: *Model, msg: Msg, ctx: Context) Effect {
    if (model.start_time == 0) {
        model.start_time = ctx.time_ms;
    }

    switch (msg) {
        .key => |key| {
            model.last_key = key;
            model.key_count += 1;

            // Quit on 'q' or Ctrl-C
            switch (key) {
                .char => |c| {
                    if (c == 'q') return .quit;
                },
                .ctrl_c => return .quit,
                else => {},
            }
        },
        .resize => |size| {
            std.debug.print("Resize: {}x{}\n", .{ size.w, size.h });
        },
        .tick => {},
    }

    return .none;
}

// ─────────────────────────────────────────────────────────────
// View (placeholder - just prints to stderr for now)
// ─────────────────────────────────────────────────────────────

fn view(model: *Model) phosphor.runtime.ViewResult {
    // For now, just print to stderr (real rendering comes later)
    if (model.last_key) |key| {
        std.debug.print("\rKeys: {} Last: {s}        ", .{ model.key_count, @tagName(key) });
    } else {
        std.debug.print("\rPress keys (q to quit)...  ", .{});
    }
    return .{};
}

// ─────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    std.debug.print("Runtime Demo - Press keys, 'q' to quit\n", .{});

    var rt = Runtime(Msg).init(init.gpa, init.io, .{
        .target_fps = 30,
        .headless = false,
    });
    defer rt.deinit();

    var model = Model{};

    try rt.run(&model, update, view);

    std.debug.print("\nDone! Pressed {} keys\n", .{model.key_count});
}

// ─────────────────────────────────────────────────────────────
// Tests (using headless mode)
// ─────────────────────────────────────────────────────────────

test "runtime demo: key injection" {
    var rt = Runtime(Msg).init(std.testing.allocator, std.testing.io, .{ .headless = true });
    defer rt.deinit();

    var model = Model{};

    // Inject some keys
    rt.send(.{ .key = .{ .char = 'a' } });
    rt.send(.{ .key = .{ .char = 'b' } });
    rt.send(.{ .key = .{ .char = 'c' } });

    // Step through them
    _ = try rt.step(&model, update);

    try std.testing.expectEqual(@as(u32, 3), model.key_count);
    try std.testing.expectEqual(@as(u21, 'c'), model.last_key.?.char);
}

test "runtime demo: quit on q" {
    var rt = Runtime(Msg).init(std.testing.allocator, std.testing.io, .{ .headless = true });
    defer rt.deinit();

    var model = Model{};

    rt.send(.{ .key = .{ .char = 'q' } });

    const should_continue = try rt.step(&model, update);

    try std.testing.expect(!should_continue);
}

test "runtime demo: context has time" {
    var rt = Runtime(Msg).init(std.testing.allocator, std.testing.io, .{ .headless = true });
    defer rt.deinit();

    rt.setTime(12345);

    var model = Model{};
    rt.send(.{ .key = .{ .char = 'x' } });
    _ = try rt.step(&model, update);

    try std.testing.expectEqual(@as(i64, 12345), model.start_time);
}
