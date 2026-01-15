const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get modules from parent phosphor package
    const phosphor_dep = b.dependency("phosphor", .{
        .target = target,
        .optimize = optimize,
    });

    const phosphor = phosphor_dep.module("phosphor");
    const thermite = phosphor_dep.module("thermite");
    const repl = phosphor_dep.module("repl");
    const logview = phosphor_dep.module("logview");

    const Example = struct {
        name: []const u8,
        path: []const u8,
        deps: []const []const u8,
    };

    const examples = [_]Example{
        .{ .name = "repl-demo", .path = "repl_demo.zig", .deps = &.{ "phosphor", "repl", "logview" } },
        .{ .name = "mandelbrot", .path = "thermite/mandelbrot.zig", .deps = &.{"thermite"} },
        .{ .name = "sprites", .path = "thermite/sprites.zig", .deps = &.{"thermite"} },
        .{ .name = "hypercube", .path = "thermite/hypercube.zig", .deps = &.{"thermite"} },
    };

    // Module lookup table
    const modules = .{
        .{ "phosphor", phosphor },
        .{ "thermite", thermite },
        .{ "repl", repl },
        .{ "logview", logview },
    };

    var repl_demo_run: ?*std.Build.Step.Run = null;

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

        b.installArtifact(exe);

        // Create run step
        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        b.step(b.fmt("run-{s}", .{example.name}), b.fmt("Run {s}", .{example.name})).dependOn(&run.step);

        // Track repl-demo for default run step
        if (std.mem.eql(u8, example.name, "repl-demo")) {
            repl_demo_run = run;
        }
    }

    // Default run step for repl-demo
    if (repl_demo_run) |run| {
        const run_step = b.step("run", "Run the REPL demo");
        run_step.dependOn(&run.step);
    }
}
