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
    const repl = phosphor_dep.module("repl");
    const logview = phosphor_dep.module("logview");

    // REPL demo
    const repl_demo = b.addExecutable(.{
        .name = "repl-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("repl_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    repl_demo.root_module.addImport("phosphor", phosphor);
    repl_demo.root_module.addImport("repl", repl);
    repl_demo.root_module.addImport("logview", logview);
    b.installArtifact(repl_demo);

    // Run step
    const run_cmd = b.addRunArtifact(repl_demo);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the REPL demo");
    run_step.dependOn(&run_cmd.step);
}
