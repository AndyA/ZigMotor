const std = @import("std");
const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const firmwares = [_][]const u8{
        "blinky",
        "clocky",
        "rampy",
        "speedy",
        "steppy",
        "swoopy",
        "twitchy",
    };

    inline for (firmwares) |name| {
        const fw = mb.add_firmware(.{
            .name = name,
            .target = mb.ports.rp2xxx.boards.raspberrypi.pico,
            .optimize = .ReleaseFast,
            .root_source_file = b.path("src/" ++ name ++ ".zig"),
        });

        mb.install_firmware(fw, .{});
        mb.install_firmware(fw, .{ .format = .elf });
    }

    const mule = b.addExecutable(.{
        .name = "mule",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mule.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(mule);

    const mule_step = b.step("mule", "Run the mule");
    const mule_cmd = b.addRunArtifact(mule);
    mule_step.dependOn(&mule_cmd.step);
    mule_cmd.step.dependOn(b.getInstallStep());

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/steppy.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const unit_tests_run = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run platform agnostic unit tests");
    test_step.dependOn(&unit_tests_run.step);
}
