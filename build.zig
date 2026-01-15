const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Startup timer module (debug timing utility)
    const startup_timer = b.addModule("startup_timer", .{
        .root_source_file = b.path("src/startup_timer.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Thermite module (low-level pixel rendering)
    const thermite = b.addModule("thermite", .{
        .root_source_file = b.path("src/thermite/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    thermite.addImport("startup_timer", startup_timer);

    // Phosphor module (high-level TUI framework)
    const phosphor = b.addModule("phosphor", .{
        .root_source_file = b.path("src/phosphor.zig"),
        .target = target,
        .optimize = optimize,
    });
    phosphor.addImport("thermite", thermite);
    phosphor.addImport("startup_timer", startup_timer);

    // Repl module (readline-style input widget) - depends on phosphor for render_commands
    const repl = b.addModule("repl", .{
        .root_source_file = b.path("src/widgets/repl/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    repl.addImport("phosphor", phosphor);

    // LogView module (scrolling log/chat widget) - depends on phosphor for LayoutNode
    const logview = b.addModule("logview", .{
        .root_source_file = b.path("src/widgets/logview/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    logview.addImport("phosphor", phosphor);

    // App module (new Elm-style architecture experiment)
    const app_mod = b.addModule("app", .{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_mod.addImport("thermite", thermite);

    // ============================================
    // Examples
    // ============================================
    const examples_step = b.step("examples", "Build all examples");

    const Example = struct {
        name: []const u8,
        path: []const u8,
        deps: []const []const u8,
    };

    const examples = [_]Example{
        .{ .name = "repl-demo", .path = "examples/repl_demo.zig", .deps = &.{ "phosphor", "repl", "logview" } },
        // App architecture demos (Elm-style)
        .{ .name = "mandelbrot", .path = "examples/mandelbrot.zig", .deps = &.{"app"} },
        .{ .name = "sprites", .path = "examples/sprites.zig", .deps = &.{"app"} },
        .{ .name = "hypercube", .path = "examples/hypercube.zig", .deps = &.{"app"} },
        .{ .name = "app-demo", .path = "examples/app_demo.zig", .deps = &.{"app"} },
        // Direct thermite API demos (low-level)
        .{ .name = "mandelbrot-thermite", .path = "examples/thermite/mandelbrot-thermite.zig", .deps = &.{"thermite"} },
        .{ .name = "sprites-thermite", .path = "examples/thermite/sprites-thermite.zig", .deps = &.{"thermite"} },
        .{ .name = "hypercube-thermite", .path = "examples/thermite/hypercube-thermite.zig", .deps = &.{"thermite"} },
    };

    // Module lookup table
    const modules = .{
        .{ "phosphor", phosphor },
        .{ "thermite", thermite },
        .{ "repl", repl },
        .{ "logview", logview },
        .{ "app", app_mod },
    };

    inline for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = target,
                .optimize = optimize,
            }),
        });

        // Add dependencies
        inline for (example.deps) |dep_name| {
            inline for (modules) |mod| {
                if (std.mem.eql(u8, mod[0], dep_name)) {
                    exe.root_module.addImport(dep_name, mod[1]);
                }
            }
        }

        const install = b.addInstallArtifact(exe, .{});
        examples_step.dependOn(&install.step);

        // Create run step
        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        b.step(b.fmt("run-{s}", .{example.name}), b.fmt("Run {s}", .{example.name})).dependOn(&run.step);
    }

    // ============================================
    // Tests
    // ============================================
    const test_step = b.step("test", "Run all tests");

    // Terminal state tests (PTY-based, signal handling)
    // NOTE: Temporarily disabled - these tests require a real terminal/PTY
    // const terminal_state_test_mod = b.createModule(.{
    //     .root_source_file = b.path("src/terminal_state_test.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const terminal_state_tests = b.addTest(.{
    //     .root_module = terminal_state_test_mod,
    // });
    // test_step.dependOn(&b.addRunArtifact(terminal_state_tests).step);

    // REPL widget tests - needs phosphor import for render_commands
    const repl_test_mod = b.createModule(.{
        .root_source_file = b.path("src/widgets/repl/repl.zig"),
        .target = target,
        .optimize = optimize,
    });
    repl_test_mod.addImport("phosphor", phosphor);
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

    // Layout system tests
    const layout_test_mod = b.createModule(.{
        .root_source_file = b.path("src/layout.zig"),
        .target = target,
        .optimize = optimize,
    });
    layout_test_mod.addImport("render_commands", b.createModule(.{
        .root_source_file = b.path("src/render_commands.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const layout_tests = b.addTest(.{
        .root_module = layout_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(layout_tests).step);
}
