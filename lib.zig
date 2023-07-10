const std = @import("std");
const os = std.os;
const span = std.mem.span;
const expect = std.testing.expect;
const fs = std.fs;
const squashfuse = @import("lib/SquashFs.zig");

pub const SquashFsError = squashfuse.SquashFsError;
pub const InodeId = squashfuse.InodeId;
pub const SquashFs = squashfuse.SquashFs;

test "open SquashFS image (zlib)" {
    const allocator = std.testing.allocator;

    var sqfs = try SquashFs.init(allocator, "test/tree_zlib.sqfs", 0);
    defer sqfs.deinit();
}

// The file structure of the test image filetree
const file_tree = &[_][]const u8{
    "1",
    "1/TEST",
    "2",
    "2/another dir",
    "2/another dir/sparse_file",
    "2/text",
    // Very long filename
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
};

// TODO: more tests
//
fn testWalk(allocator: std.mem.Allocator, sqfs: *SquashFs) !void {
    var root_inode = sqfs.getRootInode();

    var walker = try root_inode.walk(allocator);
    defer walker.deinit();

    var idx: usize = 0;
    while (try walker.next()) |entry| {
        try expect(std.mem.eql(u8, entry.path, file_tree[idx]));

        idx += 1;
    }

    // Make sure the entire list has been hit
    try expect(idx == file_tree.len);
}

test "walk tree (zlib)" {
    const allocator = std.testing.allocator;

    var sqfs = try SquashFs.init(allocator, "test/tree_zlib.sqfs", 0);
    defer sqfs.deinit();

    try testWalk(allocator, &sqfs);
}

test "walk tree (zstd)" {
    const allocator = std.testing.allocator;

    var sqfs = try SquashFs.init(allocator, "test/tree_zstd.sqfs", 0);
    defer sqfs.deinit();

    try testWalk(allocator, &sqfs);
}

test "walk tree (lz4)" {
    const allocator = std.testing.allocator;

    var sqfs = try SquashFs.init(allocator, "test/tree_lz4.sqfs", 0);
    defer sqfs.deinit();

    try testWalk(allocator, &sqfs);
}

test "walk tree (lzo)" {
    const allocator = std.testing.allocator;

    var sqfs = try SquashFs.init(allocator, "test/tree_lzo.sqfs", 0);
    defer sqfs.deinit();

    try testWalk(allocator, &sqfs);
}

test "walk tree (xz)" {
    const allocator = std.testing.allocator;

    var sqfs = try SquashFs.init(allocator, "test/tree_xz.sqfs", 0);
    defer sqfs.deinit();

    try testWalk(allocator, &sqfs);
}
