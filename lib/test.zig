// Tests basic functionality (walking, reading) for all compression
// algos

const std = @import("std");
const expect = std.testing.expect;
const squashfuse = @import("squashfuse");

pub const SquashFsError = squashfuse.SquashFsError;
pub const InodeId = squashfuse.InodeId;
pub const SquashFs = squashfuse.SquashFs;

test "open SquashFS image (zlib)" {
    const allocator = std.testing.allocator;

    var sqfs = try SquashFs.init(allocator, "test/tree_zlib.sqfs", .{});
    defer sqfs.deinit();
}

// TODO: more tests
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

// TODO: loop and test all compression algos
test "walk tree" {
    const allocator = std.testing.allocator;

    {
        var sqfs = try SquashFs.init(allocator, "test/tree_zlib.sqfs", .{});
        defer sqfs.deinit();
        try testWalk(allocator, &sqfs);
    }

    {
        var sqfs = try SquashFs.init(allocator, "test/tree_xz.sqfs", .{});
        defer sqfs.deinit();
        try testWalk(allocator, &sqfs);
    }

    {
        var sqfs = try SquashFs.init(allocator, "test/tree_lz4.sqfs", .{});
        defer sqfs.deinit();
        try testWalk(allocator, &sqfs);
    }

    {
        var sqfs = try SquashFs.init(allocator, "test/tree_lzo.sqfs", .{});
        defer sqfs.deinit();
        try testWalk(allocator, &sqfs);
    }

    {
        var sqfs = try SquashFs.init(allocator, "test/tree_zstd.sqfs", .{});
        defer sqfs.deinit();
        try testWalk(allocator, &sqfs);
    }
}

// Small helper function to allow freeing slices with defer
fn freeList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |string| {
        allocator.free(string);
    }
}

fn testRead(allocator: std.mem.Allocator, sqfs: *SquashFs) !void {
    var file_tree_hashmap = std.StringArrayHashMap(SquashFs.Inode.Walker.Entry).init(allocator);
    defer file_tree_hashmap.deinit();

    var root_inode = sqfs.getRootInode();
    var walker = try root_inode.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        // Allocate keys because entry.path gets deleted on every call
        // of `walker.next()`
        const alloc_path = try allocator.dupe(u8, entry.path);
        try file_tree_hashmap.put(alloc_path, entry);
    }

    // As the hashmap keys were allocated, free them at function exit
    const keys = file_tree_hashmap.keys();
    defer freeList(allocator, keys);

    var buf: [1024 * 65]u8 = undefined;

    // The entry should never be null because the walk test checks that
    // all files are found
    var inode = file_tree_hashmap.get("1/TEST").?.inode();
    var read_bytes = try inode.read(&buf);
    try expect(std.mem.eql(u8, buf[0..read_bytes], "TEST"));

    inode = file_tree_hashmap.get("2/another dir/sparse_file").?.inode();
    read_bytes = try inode.read(&buf);
    try expect(std.mem.eql(
        u8,
        buf[0..read_bytes],
        &std.mem.zeroes([1024 * 64]u8),
    ));

    inode = file_tree_hashmap.get("2/text").?.inode();
    read_bytes = try inode.read(&buf);
    try expect(std.mem.eql(
        u8,
        buf[0..read_bytes],
        text_contents,
    ));
}

test "read" {
    const allocator = std.testing.allocator;

    {
        var sqfs = try SquashFs.init(allocator, "test/tree_zlib.sqfs", .{});
        defer sqfs.deinit();
        try testRead(allocator, &sqfs);
    }

    {
        var sqfs = try SquashFs.init(allocator, "test/tree_xz.sqfs", .{});
        defer sqfs.deinit();
        try testRead(allocator, &sqfs);
    }

    {
        var sqfs = try SquashFs.init(allocator, "test/tree_lz4.sqfs", .{});
        defer sqfs.deinit();
        try testRead(allocator, &sqfs);
    }

    {
        var sqfs = try SquashFs.init(allocator, "test/tree_lzo.sqfs", .{});
        defer sqfs.deinit();
        try testRead(allocator, &sqfs);
    }

    {
        var sqfs = try SquashFs.init(allocator, "test/tree_zstd.sqfs", .{});
        defer sqfs.deinit();
        try testRead(allocator, &sqfs);
    }
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

const text_contents =
    \\test text file
    \\ABCDEFGHIJKLMNOPQRSTUVWXYZ
    \\more stuff
    \\very compressable
    \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    \\except not here
    \\jfkdjsl;fajldjslkfeanwlrqjoi90325802nfnvsf;hdsgpfgia-12=4fjdksljflsdbffkashcjlf
    \\121039hkfjdsbfls;jfdsjewjorweptjgf04385-43jflmsfd lnnfdjlskflds;fds[\fdsjdlfsjd
    \\JFKDJSL;FAJLDJSLKFEANWLRQJOI90325802NFNVSF;HDSGPFGIA-12=4FJDKSLJFLSDBFFKASHCJLF
    \\121039HKFJDSBFLS;JFDSJEWJORWEPTJGF04385-43JFLMSFD LNNFDJLSKFLDS;FDS[\FDSJDLFSJD
    \\
;
