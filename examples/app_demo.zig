const std = @import("std");
const phosphor = @import("phosphor");
const Application = phosphor.Application;
const Sub = phosphor.Sub;
const Key = phosphor.Key;
const Size = phosphor.Size;
const LayoutNode = phosphor.LayoutNode;

// ─────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────

const Model = struct {
    count: i32,
    size: Size,
    last_key: ?Key,
};

// ─────────────────────────────────────────────────────────────
// Msg
// ─────────────────────────────────────────────────────────────

const Msg = union(enum) {
    key: Key,
    resize: Size,
};

// ─────────────────────────────────────────────────────────────
// Init
// ─────────────────────────────────────────────────────────────

fn init(_: std.mem.Allocator, size: Size) !Model {
    return .{
        .count = 0,
        .size = size,
        .last_key = null,
    };
}

// ─────────────────────────────────────────────────────────────
// Update
// ─────────────────────────────────────────────────────────────

const Cmd = Application(Model, Msg).Cmd;

fn update(model: *Model, msg: Msg) !Cmd {
    switch (msg) {
        .key => |key| {
            model.last_key = key;
            switch (key) {
                .char => |c| {
                    if (c == 'q') return .quit;
                    if (c == '+' or c == '=') model.count += 1;
                    if (c == '-' or c == '_') model.count -= 1;
                },
                .ctrl_c, .ctrl_d => return .quit,
                .up => model.count += 1,
                .down => model.count -= 1,
                else => {},
            }
        },
        .resize => |size| {
            model.size = size;
        },
    }
    return .none;
}

// ─────────────────────────────────────────────────────────────
// Subscriptions
// ─────────────────────────────────────────────────────────────

fn subscriptions(_: *const Model) []const Sub {
    return &.{ .keyboard, .resize };
}

// ─────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────

fn view(model: *const Model, allocator: std.mem.Allocator) !LayoutNode {
    // Build strings
    const count_text = try std.fmt.allocPrint(allocator, "Count: {d}", .{model.count});
    const size_text = try std.fmt.allocPrint(allocator, "Size: {d}x{d}", .{ model.size.cols, model.size.rows });
    const key_text = if (model.last_key) |k|
        try std.fmt.allocPrint(allocator, "Last key: {any}", .{k})
    else
        "Last key: (none)";

    // Build layout
    const children = try allocator.alloc(LayoutNode, 5);
    children[0] = LayoutNode.text("Application Demo - press q to quit");
    children[1] = LayoutNode.text("");
    children[2] = LayoutNode.text(count_text);
    children[3] = LayoutNode.text(size_text);
    children[4] = LayoutNode.text(key_text);

    return LayoutNode.vbox(children);
}

// ─────────────────────────────────────────────────────────────
// App definition
// ─────────────────────────────────────────────────────────────

const MyApp = Application(Model, Msg){
    .init = init,
    .update = update,
    .view = view,
    .subscriptions = subscriptions,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    try MyApp.run(gpa.allocator());
}
