const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Thermite module (low-level pixel rendering)
    const thermite = b.addModule("thermite", .{
        .root_source_file = b.path("src/thermite/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Repl module (readline-style input widget)
    const repl = b.addModule("repl", .{
        .root_source_file = b.path("src/widgets/repl/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // LogView module (scrolling log/chat widget)
    const logview = b.addModule("logview", .{
        .root_source_file = b.path("src/widgets/logview/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Phosphor module (high-level TUI framework)
    const phosphor = b.addModule("phosphor", .{
        .root_source_file = b.path("src/phosphor.zig"),
        .target = target,
        .optimize = optimize,
    });
    phosphor.addImport("thermite", thermite);

    // Export widgets separately (for now, until integrated into phosphor)
    _ = repl;
    _ = logview;

    // Tests
    const test_step = b.step("test", "Run all tests");

    // Terminal state tests (PTY-based, signal handling)
    const terminal_state_test_mod = b.createModule(.{
        .root_source_file = b.path("src/terminal_state_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const terminal_state_tests = b.addTest(.{
        .root_module = terminal_state_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(terminal_state_tests).step);

    // REPL widget tests
    const repl_test_mod = b.createModule(.{
        .root_source_file = b.path("src/widgets/repl/repl.zig"),
        .target = target,
        .optimize = optimize,
    });
    const repl_tests = b.addTest(.{
        .root_module = repl_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(repl_tests).step);

    // Line buffer tests
    const line_buffer_test_mod = b.createModule(.{
        .root_source_file = b.path("src/widgets/repl/line_buffer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const line_buffer_tests = b.addTest(.{
        .root_module = line_buffer_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(line_buffer_tests).step);
}
