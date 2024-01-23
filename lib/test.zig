// Tests basic functionality (walking, reading) for all compression
// algos

const std = @import("std");
const expect = std.testing.expect;
const squashfuse = @import("squashfuse");

pub const SquashFsError = squashfuse.SquashFsError;
pub const InodeId = squashfuse.InodeId;
pub const SquashFs = squashfuse.SquashFs;

const compression_algos = &[_][]const u8{
    "xz",
    "zlib",
    "zstd",
    "lzo",
    "lz4",
};

test "open SquashFS image (zlib)" {
    const allocator = std.testing.allocator;

    var sqfs = try SquashFs.init(allocator, "test/tree_zlib.sqfs", .{});
    defer sqfs.deinit();
}

// TODO: loop and test all compression algos
test "walk tree" {
    const allocator = std.testing.allocator;

    inline for (compression_algos) |algo| {
        const file_path = std.fmt.comptimePrint("test/tree_{s}.sqfs", .{algo});

        var sqfs = try SquashFs.init(allocator, file_path, .{});
        defer sqfs.deinit();

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
    defer for (keys) |key| {
        allocator.free(key);
    };

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

    inline for (compression_algos) |algo| {
        const file_path = std.fmt.comptimePrint("test/tree_{s}.sqfs", .{algo});

        var sqfs = try SquashFs.init(allocator, file_path, .{});
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
