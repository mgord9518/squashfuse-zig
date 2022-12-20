const std = @import("std");
const span = std.mem.span;
const expect = std.testing.expect;

const c = @cImport({
    @cInclude("squashfuse.h"); // squashfuse config file
});

pub const SquashFsError = error{
    Error, // Generic error
    InvalidFormat, // Unknown file format
    InvalidVersion, // Unsupported version
    InvalidCompression, // Unsupported compression algorithm
    UnsupportedFeature, // Unsupported feature
};

fn SquashFsErrorFromInt(err: u32) SquashFsError {
    switch (err) {
        2 => return SquashFsError.InvalidFormat,
        3 => return SquashFsError.InvalidVersion,
        4 => return SquashFsError.InvalidCompression,
        5 => return SquashFsError.UnsupportedFeature,
        else => return SquashFsError.Error,
    }
}

pub const SquashFs = struct {
    internal: c.sqfs = undefined,

    version: SquashFsVersion = undefined,

    // squash_open wrapper
    pub fn init(path: [*:0]const u8, offset: u64) SquashFsError!SquashFs {
        var sqfs = SquashFs{};

        // TODO: implement `sqfs_open_image` in Zig (it just wraps `sqfs_init`)
        // so that nothing gets annoyingly printed to stdout on failure
        const err = c.sqfs_open_image(&sqfs.internal, path, offset);
        if (err != 0) return SquashFsErrorFromInt(err);

        // Set version
        sqfs.version = SquashFsVersion{ .major = 0, .minor = 0 };
        c.sqfs_version(&sqfs.internal, &sqfs.version.major, &sqfs.version.minor);

        return sqfs;
    }

    // TODO: Actually start walking from the path provided
    pub fn walk(sqfs: *SquashFs, root: [*:0]const u8) !SquashFsWalker {
        var walker = SquashFsWalker{};

        _ = root;
        var err = c.sqfs_traverse_open(&walker.internal, &sqfs.internal, c.sqfs_inode_root(&sqfs.internal));
        if (err != 0) return SquashFsErrorFromInt(err);

        return walker;
    }

    //    pub fn extract(sqfs: *SquashFs, path: [*:0]const u8) !void {
    //    }
};

pub const SquashFsWalker = struct {
    internal: c.sqfs_traverse = undefined,

    // This just wraps the squashfuse walk function
    pub fn next(walker: *SquashFsWalker) ?SquashFsEntry {
        // TODO: Handle this error
        var err: u32 = undefined;

        // Maybe these values should be passed as a pointer so they don't have
        // to be copied?
        if (c.sqfs_traverse_next(&walker.internal, &err)) {
            return SquashFsEntry{ .path = walker.internal.path, .internal = walker.internal.entry, .inode_type = @intToEnum(SquashFsDirType, walker.internal.entry.type) };
        }

        // Once `sqfs_traverse_next` stops returning true, we pass null so that
        // this will stop any while loop its put into
        return null;
    }
};

// TODO: Implement this to mimic the stdlib nicely
pub const SquashFsEntry = struct {
    internal: c.sqfs_dir_entry,

    path: [*:0]const u8,
    inode_type: SquashFsDirType,
};

pub const SquashFsDirType = enum(u8) {
    directory = 1,
    regular,
    symlink,
    blkdev,
    chrdev,
    fifo,
    socket,
    ldirectory,
    lregular,
    lsymlink,
    lblkdev,
    lchrdev,
    lfifo,
    lsocket,
};

pub const SquashFsVersion = struct {
    major: i32,
    minor: i32,
};
