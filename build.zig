const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("parslet", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    inline for (.{ "peg_parse", "peg_test", "peg_transform" }) |name| {
        const options = b.addOptions();
        options.addOption([]const u8, "command", name);
        const module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        module.addOptions("options", options);
        b.installArtifact(b.addExecutable(.{ .name = name, .root_module = module }));
    }
    const test_step = b.step("test", "Run library unit tests");
    inline for (.{ "src/engine_test.zig", "src/transform_test.zig", "src/diagnostics_test.zig" }) |path| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
