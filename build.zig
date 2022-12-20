const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("squash", "src/SquashFs.zig");
    lib.setBuildMode(mode);
    lib.install();
    lib.linkSystemLibrary("squashfuse");

    const main_tests = b.addTest("src/SquashFs.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
