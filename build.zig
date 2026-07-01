const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("4orman_tools", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "4orman-tools",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "4orman_tools", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |run_args| run_cmd.addArgs(run_args);
    b.step("run", "Run 4orman-tools").dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const stress_exe = b.addExecutable(.{
        .name = "4orman-stress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stress.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const stress_run = b.addRunArtifact(stress_exe);
    stress_run.step.dependOn(b.getInstallStep());
    stress_run.addArtifactArg(exe);
    stress_run.addArg(b.build_root.path orelse ".");
    b.step("stress", "Run stress tests against the built binary").dependOn(&stress_run.step);
}
