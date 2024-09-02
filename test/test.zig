// Tests basic functionality (walking, reading) for all compression
// algos

const std = @import("std");
const fs = std.fs;
const expect = std.testing.expect;
const squashfuse = @import("squashfuse");
const SquashFs = squashfuse.SquashFs;
const allocator = std.testing.allocator;

const compression_algos = &.{
    "xz",
    "zlib",
    "zstd",
    "lz4",
};

test "Dir.openDir" {
    var sqfs = try SquashFs.init(allocator, "test/tree_zlib.sqfs", .{});
    defer sqfs.deinit();

    var root_dir = sqfs.root();
    defer root_dir.close();

    var dir = try root_dir.openDir("2/another dir", .{});
    defer dir.close();

    var it = try dir.iterate();

    while (try it.next()) |_| {
        //std.debug.print("{s}\n", .{entry.name});
    }
}

test "Dir.walk" {
    inline for (compression_algos) |algo| {
        const file_path = std.fmt.comptimePrint("test/tree_{s}.sqfs", .{algo});

        var sqfs = try SquashFs.init(allocator, file_path, .{});
        defer sqfs.deinit();

        var root = sqfs.root();

        var walker = try root.walk(allocator);
        defer walker.deinit();

        var idx: usize = 0;
        while (try walker.next()) |entry| : (idx += 1) {
            try expect(std.mem.eql(
                u8,
                entry.path,
                file_tree[idx],
            ));
        }

        // Make sure the entire list has been hit
        try expect(idx == file_tree.len);
    }
}

test "SquashFs.Inode.walk" {
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

test "Inode.Stat" {
    inline for (compression_algos) |algo| {
        const file_path = std.fmt.comptimePrint(
            "test/tree_{s}.sqfs",
            .{algo},
        );

        var sqfs = try SquashFs.init(allocator, file_path, .{});
        defer sqfs.deinit();

        var root_inode = sqfs.getRootInode();

        var walker = try root_inode.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.path.len < 7 or !std.mem.eql(u8, entry.path[0..5], "perm_")) continue;

            var inode = entry.inode();

            const trunc_mode: u9 = @truncate((try inode.stat()).mode);
            const trunc_modeC: u9 = @truncate((try inode.statC()).mode);
            const goal_mode = try std.fmt.parseInt(u9, entry.path[5..], 8);

            try expect(trunc_mode == goal_mode);
            try expect(trunc_modeC == goal_mode);
        }
    }
}

test "devices" {
    inline for (compression_algos) |algo| {
        const file_path = std.fmt.comptimePrint("test/tree_{s}.sqfs", .{algo});

        var sqfs = try SquashFs.init(allocator, file_path, .{});
        defer sqfs.deinit();

        var root_inode = sqfs.getRootInode();

        var iterator = try root_inode.iterate();
        //defer walker.deinit();

        while (try iterator.next()) |entry| {
            var inode = entry.inode();
            _ = &inode;

            if (std.mem.eql(
                u8,
                entry.name,
                "block_device",
            )) {
                const dev = inode.xtra.dev;

                try expect(dev.major() == 69);
                try expect(dev.minor() == 2);
            }

            if (std.mem.eql(
                u8,
                entry.name,
                "character_device",
            )) {
                const dev = inode.xtra.dev;

                try expect(dev.major() == 0);
                try expect(dev.minor() == 1);
            }

            //            try expect(trunc_mode == goal_mode);
        }
    }
}

fn testRead(sqfs: *SquashFs) !void {
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
    var file = SquashFs.File.initFromInode(&inode);
    var read_bytes = try file.read(&buf);
    try expect(std.mem.eql(u8, buf[0..read_bytes], "TEST"));

    inode = file_tree_hashmap.get("2/another dir/sparse_file").?.inode();
    read_bytes = try inode.read(&buf);
    try expect(std.mem.eql(
        u8,
        buf[0..read_bytes],
        &std.mem.zeroes([1024 * 64]u8),
    ));

    inode = file_tree_hashmap.get("2/text").?.inode();
    file = SquashFs.File.initFromInode(&inode);
    read_bytes = try file.read(&buf);
    try expect(std.mem.eql(
        u8,
        buf[0..read_bytes],
        text_contents,
    ));
}

test "read" {
    inline for (compression_algos) |algo| {
        const file_path = std.fmt.comptimePrint("test/tree_{s}.sqfs", .{algo});

        var sqfs = try SquashFs.init(allocator, file_path, .{});
        defer sqfs.deinit();

        try testRead(sqfs);
    }
}

test "read link" {
    inline for (compression_algos) |algo| {
        const file_path = std.fmt.comptimePrint("test/tree_{s}.sqfs", .{algo});

        var sqfs = try SquashFs.init(allocator, file_path, .{});
        defer sqfs.deinit();

        var root_inode = sqfs.getRootInode();

        var walker = try root_inode.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (!std.mem.eql(u8, entry.path, "symlink")) {
                continue;
            }

            const goal = "2/text";

            var buf: [goal.len]u8 = undefined;
            var inode = entry.inode();

            const link_target = try inode.readLink(&buf);

            try expect(std.mem.eql(
                u8,
                link_target,
                goal,
            ));

            var small_buf: [goal.len - 1]u8 = undefined;
            _ = inode.readLink(&small_buf) catch |err| {
                try expect(err == error.NoSpaceLeft);
            };
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
