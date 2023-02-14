// NOTE BEFORE BUILDING:
// The <https://github.com/vasi/squashfuse> repo must be inside this directory,
// along with running `./autogen.sh` then `./configure` inside it to generate
// `config.h`

const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("squashfuse", "src/SquashFs.zig");
    lib.setBuildMode(mode);
    lib.install();

    const main_tests = b.addTest("src/SquashFs.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
