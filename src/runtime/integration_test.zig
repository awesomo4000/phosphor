/// Integration tests for the runtime - validates full flow without real terminal
const std = @import("std");
const runtime_mod = @import("runtime.zig");
const Runtime = runtime_mod.Runtime;
const Context = runtime_mod.Context;
const Effect = runtime_mod.Effect;
const Key = runtime_mod.Key;
const Size = runtime_mod.Size;

// ─────────────────────────────────────────────────────────────
// Test App: Simple counter with key handling
// ─────────────────────────────────────────────────────────────

const CounterModel = struct {
    count: u32 = 0,
    last_key: ?Key = null,
    last_time: i64 = 0,
    last_frame: u64 = 0,
    quit_requested: bool = false,
};

const CounterMsg = union(enum) {
    key: Key,
    resize: Size,
    increment,
    decrement,
};

fn counterUpdate(model: *CounterModel, msg: CounterMsg, ctx: Context) Effect {
    model.last_time = ctx.time_ms;
    model.last_frame = ctx.frame;

    switch (msg) {
        .key => |key| {
            model.last_key = key;
            switch (key) {
                .char => |c| {
                    if (c == 'q') {
                        model.quit_requested = true;
                        return .quit;
                    }
                    if (c == '+') model.count += 1;
                    if (c == '-' and model.count > 0) model.count -= 1;
                },
                .ctrl_c => {
                    model.quit_requested = true;
                    return .quit;
                },
                .up => model.count += 1,
                .down => if (model.count > 0) {
                    model.count -= 1;
                },
                else => {},
            }
        },
        .resize => {},
        .increment => model.count += 1,
        .decrement => if (model.count > 0) {
            model.count -= 1;
        },
    }
    return .none;
}

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

test "integration: key injection and processing" {
    var rt = Runtime(CounterMsg).init(std.testing.allocator, .{ .headless = true });
    defer rt.deinit();

    var model = CounterModel{};

    // Inject keys
    rt.send(.{ .key = .{ .char = '+' } });
    rt.send(.{ .key = .{ .char = '+' } });
    rt.send(.{ .key = .{ .char = '+' } });
    rt.send(.{ .key = .{ .char = '-' } });

    // Process all messages in one step
    _ = try rt.step(&model, counterUpdate);

    try std.testing.expectEqual(@as(u32, 2), model.count);
    try std.testing.expectEqual(@as(u21, '-'), model.last_key.?.char);
}

test "integration: arrow key navigation" {
    var rt = Runtime(CounterMsg).init(std.testing.allocator, .{ .headless = true });
    defer rt.deinit();

    var model = CounterModel{};

    rt.send(.{ .key = .up });
    rt.send(.{ .key = .up });
    rt.send(.{ .key = .up });
    rt.send(.{ .key = .down });

    _ = try rt.step(&model, counterUpdate);

    try std.testing.expectEqual(@as(u32, 2), model.count);
    try std.testing.expectEqual(Key.down, model.last_key.?);
}

test "integration: quit on q" {
    var rt = Runtime(CounterMsg).init(std.testing.allocator, .{ .headless = true });
    defer rt.deinit();

    var model = CounterModel{};

    rt.send(.{ .key = .{ .char = 'q' } });

    const should_continue = try rt.step(&model, counterUpdate);

    try std.testing.expect(!should_continue);
    try std.testing.expect(model.quit_requested);
}

test "integration: quit on ctrl-c" {
    var rt = Runtime(CounterMsg).init(std.testing.allocator, .{ .headless = true });
    defer rt.deinit();

    var model = CounterModel{};

    rt.send(.{ .key = .ctrl_c });

    const should_continue = try rt.step(&model, counterUpdate);

    try std.testing.expect(!should_continue);
    try std.testing.expect(model.quit_requested);
}

test "integration: context provides time" {
    var rt = Runtime(CounterMsg).init(std.testing.allocator, .{ .headless = true });
    defer rt.deinit();

    var model = CounterModel{};

    rt.setTime(42000);
    rt.send(.increment);

    _ = try rt.step(&model, counterUpdate);

    try std.testing.expectEqual(@as(i64, 42000), model.last_time);
}

test "integration: context provides frame number" {
    var rt = Runtime(CounterMsg).init(std.testing.allocator, .{ .headless = true });
    defer rt.deinit();

    var model = CounterModel{};

    // First step
    rt.send(.increment);
    _ = try rt.step(&model, counterUpdate);
    try std.testing.expectEqual(@as(u64, 0), model.last_frame);

    // Second step
    rt.send(.increment);
    _ = try rt.step(&model, counterUpdate);
    try std.testing.expectEqual(@as(u64, 1), model.last_frame);

    // Third step
    rt.send(.increment);
    _ = try rt.step(&model, counterUpdate);
    try std.testing.expectEqual(@as(u64, 2), model.last_frame);
}

test "integration: time advances between steps" {
    var rt = Runtime(CounterMsg).init(std.testing.allocator, .{ .headless = true });
    defer rt.deinit();

    var model = CounterModel{};

    rt.setTime(1000);
    rt.send(.increment);
    _ = try rt.step(&model, counterUpdate);
    const time1 = model.last_time;

    rt.advanceTime(500);
    rt.send(.increment);
    _ = try rt.step(&model, counterUpdate);
    const time2 = model.last_time;

    try std.testing.expectEqual(@as(i64, 500), time2 - time1);
}

test "integration: multiple steps accumulate" {
    var rt = Runtime(CounterMsg).init(std.testing.allocator, .{ .headless = true });
    defer rt.deinit();

    var model = CounterModel{};

    // Step 1: increment twice
    rt.send(.increment);
    rt.send(.increment);
    _ = try rt.step(&model, counterUpdate);
    try std.testing.expectEqual(@as(u32, 2), model.count);

    // Step 2: increment once more
    rt.send(.increment);
    _ = try rt.step(&model, counterUpdate);
    try std.testing.expectEqual(@as(u32, 3), model.count);

    // Step 3: decrement
    rt.send(.decrement);
    _ = try rt.step(&model, counterUpdate);
    try std.testing.expectEqual(@as(u32, 2), model.count);
}

test "integration: empty step is no-op" {
    var rt = Runtime(CounterMsg).init(std.testing.allocator, .{ .headless = true });
    defer rt.deinit();

    var model = CounterModel{ .count = 5 };

    // Step with no messages
    const should_continue = try rt.step(&model, counterUpdate);

    try std.testing.expect(should_continue);
    try std.testing.expectEqual(@as(u32, 5), model.count);
    try std.testing.expectEqual(@as(u64, 1), rt.frame);
}

test "integration: sendAll injects multiple messages" {
    var rt = Runtime(CounterMsg).init(std.testing.allocator, .{ .headless = true });
    defer rt.deinit();

    var model = CounterModel{};

    rt.sendAll(&[_]CounterMsg{
        .increment,
        .increment,
        .increment,
        .increment,
        .increment,
    });

    _ = try rt.step(&model, counterUpdate);

    try std.testing.expectEqual(@as(u32, 5), model.count);
}
