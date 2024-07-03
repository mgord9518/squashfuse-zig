// Tests basic functionality (walking, reading) for all compression
// algos

const std = @import("std");
const posix = std.posix;
const fs = std.fs;
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

test "iterate dir" {
    const allocator = std.testing.allocator;

    var sqfs = try SquashFs.init(allocator, "test/tree_zlib.sqfs", .{});
    defer sqfs.deinit();

    var root_inode = sqfs.getRootInode();
    var root_dir = try SquashFs.Dir.initFromInode(&sqfs, &root_inode);

    var it = try root_dir.iterate();

    while (try it.next()) |_| {
        //        std.debug.print("{s}\n", .{entry.name});
    }
}

test "open SquashFS image (zlib)" {
    const allocator = std.testing.allocator;

    var sqfs = try SquashFs.init(allocator, "test/tree_zlib.sqfs", .{});
    defer sqfs.deinit();
}

// TODO: loop and test all compression algos
test "SquashFs.Inode.walk" {
    const allocator = std.testing.allocator;

    inline for (compression_algos) |algo| {
        const file_path = std.fmt.comptimePrint("test/tree_{s}.sqfs", .{algo});

        var sqfs = try SquashFs.init(allocator, file_path, .{});
        defer sqfs.deinit();

        var root_inode = sqfs.getRootInode();

        var walker = try root_inode.walk(allocator);
        defer walker.deinit();

        var idx: usize = 0;
        while (try walker.next()) |entry| : (idx += 1) {
            try expect(std.mem.eql(u8, entry.path, file_tree[idx]));
        }

        // Make sure the entire list has been hit
        try expect(idx == file_tree.len);
    }
}

test "SquashFs.Inode.Stat" {
    const allocator = std.testing.allocator;

    inline for (compression_algos) |algo| {
        const file_path = std.fmt.comptimePrint("test/tree_{s}.sqfs", .{algo});

        var sqfs = try SquashFs.init(allocator, file_path, .{});
        defer sqfs.deinit();

        var root_inode = sqfs.getRootInode();

        var walker = try root_inode.walk(allocator);
        defer walker.deinit();

        var idx: usize = 0;
        while (try walker.next()) |entry| : (idx += 1) {
            if (entry.path.len < 7 or !std.mem.eql(u8, entry.path[0..5], "perm_")) continue;

            var inode = entry.inode();

            const trunc_mode: u9 = @truncate((try inode.stat()).mode);
            const goal_mode = try std.fmt.parseInt(u9, entry.path[5..], 8);

            try expect(trunc_mode == goal_mode);
        }
    }
}

test "devices" {
    const allocator = std.testing.allocator;

    inline for (compression_algos) |algo| {
        const file_path = std.fmt.comptimePrint("test/tree_{s}.sqfs", .{algo});

        var sqfs = try SquashFs.init(allocator, file_path, .{});
        defer sqfs.deinit();

        var root_inode = sqfs.getRootInode();

        var iterator = try root_inode.iterate();
        //defer walker.deinit();

        var idx: usize = 0;
        while (try iterator.next()) |entry| : (idx += 1) {
            var inode = entry.inode();
            _ = &inode;

            if (std.mem.eql(
                u8,
                entry.name,
                "block_device",
            )) {
                const dev = inode.internal.xtra.dev;

                try expect(dev.major() == 69);
                try expect(dev.minor() == 2);
            }

            if (std.mem.eql(
                u8,
                entry.name,
                "character_device",
            )) {
                const dev = inode.internal.xtra.dev;

                try expect(dev.major() == 0);
                try expect(dev.minor() == 1);
            }

            //            try expect(trunc_mode == goal_mode);
        }
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

test "read link" {
    const allocator = std.testing.allocator;

    inline for (compression_algos) |algo| {
        const file_path = std.fmt.comptimePrint("test/tree_{s}.sqfs", .{algo});

        var sqfs = try SquashFs.init(allocator, file_path, .{});
        defer sqfs.deinit();

        var root_inode = sqfs.getRootInode();

        var walker = try root_inode.walk(allocator);
        defer walker.deinit();

        var idx: usize = 0;
        while (try walker.next()) |entry| : (idx += 1) {
            if (!std.mem.eql(u8, entry.path, "symlink")) {
                continue;
            }

            var buf: [fs.MAX_PATH_BYTES]u8 = undefined;
            var inode = entry.inode();

            const link_target = try inode.readLink(&buf);

            try expect(std.mem.eql(
                u8,
                link_target,
                "2/text",
            ));
        }
    }
}

// The file structure of the test image file tree
const file_tree = &[_][]const u8{
    "1",
    "1/TEST",
    "2",
    "2/another dir",
    "2/another dir/sparse_file",
    "2/text",
    // Very long filename
    "A" ** 256,
    "block_device",
    "broken_symlink",
    "character_device",
    // Permissions
    "perm_400",
    "perm_644",
    "perm_777",
    "symlink",
};

const text_contents = @embedFile("test.zig");
