const std = @import("std");
const expect = std.testing.expect;
const squashfuse = @import("squashfuse");
const SquashFs = squashfuse.SquashFs;

const compression_algos = &.{
    "xz",
    "zlib",
    "zstd",
    "lz4",
};

test "Dir.openDir" {
    const file = try std.fs.cwd().openFile("test/tree_zlib.sqfs", .{});
    defer file.close();
    var sqfs = try SquashFs.open(std.testing.allocator, file, .{});
    defer sqfs.close();

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

        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        var sqfs = try SquashFs.open(std.testing.allocator, file, .{});
        defer sqfs.close();

        var root = sqfs.root();

        var walker = try root.walk(std.testing.allocator);
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

test "Inode.Stat" {
    inline for (compression_algos) |algo| {
        const file_path = std.fmt.comptimePrint(
            "test/tree_{s}.sqfs",
            .{algo},
        );

        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        var sqfs = try SquashFs.open(std.testing.allocator, file, .{});
        defer sqfs.close();

        var root = sqfs.root();

        var walker = try root.walk(std.testing.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.path.len < 7 or !std.mem.eql(u8, entry.path[0..5], "perm_")) continue;

            var inode = sqfs.getInode(
                entry.id,
            ) catch unreachable;

            const trunc_mode: u9 = @truncate((try inode.stat()).mode);
            const trunc_modeC: u9 = @truncate((try inode.statC()).mode);
            const goal_mode = try std.fmt.parseInt(u9, entry.path[5..], 8);

            try expect(trunc_mode == goal_mode);
            try expect(trunc_modeC == goal_mode);
        }
    }
}

// TODO
//test "devices" {
//    inline for (compression_algos) |algo| {
//        const file_path = std.fmt.comptimePrint("test/tree_{s}.sqfs", .{algo});
//
//        const file = try std.fs.cwd().openFile(file_path, .{});
//        defer file.close();
//        var sqfs = try SquashFs.open(allocator, file, .{});
//        defer sqfs.close();
//
//        var root = sqfs.root();
//
//        var iterator = try root.iterate();
//        //defer walker.deinit();
//
//        while (try iterator.next()) |entry| {
//            if (std.mem.eql(
//                u8,
//                entry.name,
//                "block_device",
//            )) {
//                const dev = inode.xtra.dev;
//
//                try expect(dev.major() == 69);
//                try expect(dev.minor() == 2);
//            }
//
//            if (std.mem.eql(
//                u8,
//                entry.name,
//                "character_device",
//            )) {
//                const dev = inode.xtra.dev;
//
//                try expect(dev.major() == 0);
//                try expect(dev.minor() == 1);
//            }
//
//            //            try expect(trunc_mode == goal_mode);
//        }
//    }
//}

fn testRead(sqfs: *SquashFs) !void {
    var root = sqfs.root();
    var buf: [1024 * 65]u8 = undefined;

    var file = try root.openFile("/1/TEST", .{});
    var read_bytes = try file.reader().readAll(&buf);
    try expect(std.mem.eql(u8, buf[0..read_bytes], "TEST"));
    file.close();

    file = try root.openFile("2/another dir/sparse_file", .{});
    read_bytes = try file.reader().readAll(&buf);
    try expect(std.mem.eql(
        u8,
        buf[0..read_bytes],
        &std.mem.zeroes([1024 * 64]u8),
    ));
    file.close();

    file = try root.openFile("../../2/text", .{});
    read_bytes = try file.reader().readAll(&buf);
    try expect(std.mem.eql(
        u8,
        buf[0..read_bytes],
        text_contents,
    ));
    file.close();
}

test "File.read" {
    inline for (compression_algos) |algo| {
        const file_path = std.fmt.comptimePrint("test/tree_{s}.sqfs", .{algo});

        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        var sqfs = try SquashFs.open(std.testing.allocator, file, .{});
        defer sqfs.close();

        try testRead(sqfs);
    }
}

test "Dir.readLink" {
    inline for (compression_algos) |algo| {
        const file_path = std.fmt.comptimePrint("test/tree_{s}.sqfs", .{algo});

        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        var sqfs = try SquashFs.open(std.testing.allocator, file, .{});
        defer sqfs.close();

        var root = sqfs.root();

        const goal = "2/text";

        var buf: [goal.len]u8 = undefined;
        const link_target = try root.readLink("2/../1/../../../symlink", &buf);

        try expect(std.mem.eql(
            u8,
            link_target,
            goal,
        ));

        var small_buf: [goal.len - 1]u8 = undefined;
        _ = root.readLink("./..////symlink", &small_buf) catch |err| {
            try expect(err == error.NoSpaceLeft);
        };
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

const text_contents = @embedFile("lorem.txt");
