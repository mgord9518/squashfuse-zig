const std = @import("std");
const squashfuse = @import("squashfuse");
const SquashFs = squashfuse.SquashFs;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var args_it = try std.process.argsWithAllocator(allocator);
    defer args_it.deinit();

    const argv0 = args_it.next().?;
    const argv1 = args_it.next() orelse {
        std.debug.print("usage: {s} <zlib-compressed squashfs>\n", .{argv0});
        return;
    };

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    // Must first run `test/make_images.sh` in order for this to work
    var sqfs = try SquashFs.init(allocator, argv1, .{});
    defer sqfs.deinit();

    try stdout.print("SqusahFS info:\n", .{});
    try stdout.print("  compression: {s}\n", .{@tagName(sqfs.super_block.compression)});

    try bw.flush(); // don't forget to flush!
}
