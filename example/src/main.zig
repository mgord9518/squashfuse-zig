const std = @import("std");
const squashfuse = @import("squashfuse");
const SquashFs = squashfuse.SquashFs;

pub fn main() !void {
    std.debug.print("opening `test_file.sfs`\n", .{});

    const allocator = std.heap.page_allocator;

    var sqfs = try SquashFs.init(allocator, "../../test_file.sfs", .{});
    defer sqfs.deinit();
}
