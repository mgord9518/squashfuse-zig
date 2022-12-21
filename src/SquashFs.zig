const std = @import("std");
const span = std.mem.span;
const expect = std.testing.expect;
const fs = std.fs;

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

    version: Version = undefined,

    pub const Version = struct {
        major: i32,
        minor: i32,
    };

    // squash_open wrapper
    pub fn init(path: [*:0]const u8, offset: u64) SquashFsError!SquashFs {
        var sqfs = SquashFs{};

        // TODO: implement `sqfs_open_image` in Zig (it just wraps `sqfs_init`)
        // so that nothing gets annoyingly printed to stdout on failure
        const err = c.sqfs_open_image(&sqfs.internal, path, offset);
        if (err != 0) return SquashFsErrorFromInt(err);

        // Set version
        sqfs.version = Version{ .major = 0, .minor = 0 };
        c.sqfs_version(&sqfs.internal, &sqfs.version.major, &sqfs.version.minor);

        return sqfs;
    }

    // TODO: Actually start walking from the path provided
    pub fn walk(sqfs: *SquashFs, root: [*:0]const u8) !Walker {
        var walker = Walker{};

        _ = root;
        var err = c.sqfs_traverse_open(&walker.internal, &sqfs.internal, sqfs.internal.sb.root_inode);
        if (err != 0) return SquashFsErrorFromInt(err);

        return walker;
    }

    //    pub fn lookup(sqfs: *SquashFs, path: [*:0]const u8) !void {
    //        var entry: c.sqfs_dir_entry = undefined;

    //   }
};

pub const Walker = struct {
    internal: c.sqfs_traverse = undefined,

    pub const WalkerEntry = struct {
        //    internal: c.sqfs_dir_entry,

        //dir: Dir,
        basename: [*:0]const u8,
        path: [*:0]const u8,
        kind: File.Kind,
    };

    // This just wraps the squashfuse walk function
    pub fn next(walker: *Walker) !?WalkerEntry {
        // TODO: Handle this error
        var err: u32 = undefined;

        // Maybe these values should be passed as a pointer so they don't have
        // to be copied?
        if (c.sqfs_traverse_next(&walker.internal, &err)) {
            //return { .path = walker.internal.path, .internal = walker.internal.entry, .inode_type = @intToEnum(SquashFsDirType, walker.internal.entry.type) };
            return WalkerEntry{ .basename = basenameZ(walker.internal.path, walker.internal.path_size), .path = walker.internal.path, .kind = @intToEnum(File.Kind, walker.internal.entry.type) };
        }

        if (err != 0) return SquashFsErrorFromInt(err);
        c.sqfs_traverse_close(&walker.internal);

        // Once `sqfs_traverse_next` stops returning true, we pass null so that
        // this will stop any while loop its put into
        return null;
    }
};

pub const File = struct {
    pub const Kind = enum(u8) {
        Directory = 1,
        File,
        SymLink,
        BlockDevice,
        CharacterDevice,
        NamedPipe,
        UnixDomainSocket,

        // Not really sure what these are tbh, but squashfuse has entries for
        // them
        LDirectory,
        LFile,
        LSymLink,
        LBlockDevice,
        LCharacterDevice,
        LNamedPipe,
        LUnixDomainSocket,
    };
};

// Modified `std.fs.path.basename` as the stdlib doesn't contain one for
// C strings
pub fn basenameZ(path: [*c]const u8, path_size: usize) [*c]const u8 {
    if (path_size == 0)
        return "";

    var end_index: usize = path_size - 1;
    while (path[end_index] == '/') {
        if (end_index == 0)
            return "";
        end_index -= 1;
    }

    var start_index: usize = end_index;
    end_index += 1;
    while (path[start_index] != '/') {
        if (start_index == 0)
            return path[0..end_index].ptr;
        start_index -= 1;
    }

    return path[start_index + 1 .. end_index].ptr;
}
