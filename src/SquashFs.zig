const std = @import("std");
const os = std.os;
const span = std.mem.span;
const expect = std.testing.expect;
const fs = std.fs;

const c = @cImport({
    @cInclude("stat.h"); // squashfuse (not system) stat header
    @cInclude("squashfuse.h");
});

pub const SquashFsError = error{
    Error, // Generic error
    InvalidFormat, // Unknown file format
    InvalidVersion, // Unsupported version
    InvalidCompression, // Unsupported compression algorithm
    UnsupportedFeature, // Unsupported feature
};

// Converts a C error code to a Zig error enum
fn SquashFsErrorFromInt(err: c_uint) SquashFsError!void {
    return switch (err) {
        0 => {},
        2 => SquashFsError.InvalidFormat,
        3 => SquashFsError.InvalidVersion,
        4 => SquashFsError.InvalidCompression,
        5 => SquashFsError.UnsupportedFeature,
        else => SquashFsError.Error,
    };
}

pub const Inode = c.sqfs_inode;
pub const InodeId = c.sqfs_inode_id;

pub const SquashFs = struct {
    internal: c.sqfs = undefined,
    version: Version = undefined,
    file: fs.File = undefined,

    pub const Version = struct {
        major: i32,
        minor: i32,
    };

    pub fn init(path: []const u8, offset: u64) !SquashFs {
        var sqfs = SquashFs{};

        sqfs.file = try std.fs.cwd().openFile(path, .{});

        try SquashFsErrorFromInt(c.sqfs_init(&sqfs.internal, sqfs.file.handle, offset));

        // Set version
        c.sqfs_version(&sqfs.internal, &sqfs.version.major, &sqfs.version.minor);

        return sqfs;
    }

    pub fn deinit(sqfs: *SquashFs) void {
        sqfs.file.close();
    }

    // TODO: Actually start walking from the path provided
    pub fn walk(sqfs: *SquashFs, root: [:0]const u8) !Walker {
        _ = root;
        var walker = Walker{ .internal = undefined };

        var err = c.sqfs_traverse_open(&walker.internal, &sqfs.internal, sqfs.internal.sb.root_inode);
        try SquashFsErrorFromInt(err);

        return walker;
    }

    /// Wrapper of `sqfs_read_range`
    /// Use for reading one byte buffer at a time
    /// Retruns the amount of bytes read
    pub fn readRange(sqfs: *SquashFs, inode: *Inode, buf: []u8, off: usize) !usize {
        // squashfuse writes the amount of bytes read back into the `buffer
        // length` variable, so we create that here
        var buf_len = @intCast(c.sqfs_off_t, buf.len);

        const err = c.sqfs_read_range(&sqfs.internal, inode, @intCast(c.sqfs_off_t, off), &buf_len, @ptrCast(*anyopaque, buf));

        try SquashFsErrorFromInt(err);

        return @intCast(usize, buf_len);
    }

    // Another small wrapper, this shouldn't be used unless necessary (stuff
    // missing from the bindings)
    pub fn getInode(sqfs: *SquashFs, id: InodeId) !Inode {
        var inode: Inode = undefined;

        try SquashFsErrorFromInt(c.sqfs_inode_get(&sqfs.internal, &inode, id));

        return inode;
    }

    // Haven't been able to get this working, I'll probably just re-implement
    // it
    //    pub fn lookup(sqfs: *SquashFs, path: [*:0]const u8) !?c.sqfs_inode {
    //        var inode: c.sqfs_inode = undefined;
    //        var found: bool = false;
    //        _ = path;
    //
    //        const err = c.sqfs_lookup_path(&sqfs.internal, &inode, "", &found);
    //
    //        std.debug.print("\n{}\n", .{found});
    //
    //        if (err != 0) return SquashFsErrorFromInt(err);
    //        if (!found) return SquashFsErrorFromInt(3);
    //
    //        return inode;
    //    }

    // Extracts an inode from the SquashFS image to `dest` using the buffer
    // This should be preferred to `readRange` if the goal is actually to
    // extract an entire file
    pub fn extract(sqfs: *SquashFs, buf: []u8, entry: Walker.Entry, dest: []const u8) !void {
        var inode = try sqfs.getInode(entry.id);

        switch (entry.kind) {
            .File => {
                var f = try fs.cwd().createFile(dest, .{});
                defer f.close();

                var off: usize = 0;
                const fsize = @intCast(usize, inode.xtra.reg.file_size);
                while (off < fsize) {
                    const read_bytes = try sqfs.readRange(&inode, buf, off);
                    off += read_bytes;

                    _ = try f.write(buf[0..read_bytes]);
                }

                // Change the mode of the file to match the inode contained in the
                // SquashFS image
                const st = try sqfs.stat(&inode);
                try f.chmod(st.mode);
            },
            .Directory => {
                fs.makeDir(dest);
            },
            // TODO: implement for other types
        }
    }

    pub fn stat(sqfs: *SquashFs, inode: *Inode) !fs.File.Stat {
        var st: c.struct_stat = undefined;

        try SquashFsErrorFromInt(c.sqfs_stat(&sqfs.internal, inode, &st));

        return fs.File.Stat.fromSystem(@bitCast(std.os.Stat, st));
    }

    // Like `SquashFs.stat` but returns the native stat format
    pub fn statC(sqfs: *SquashFs, inode: *Inode, st: *os.Stat) !void {
        const err = c.sqfs_stat(&sqfs.internal, inode, @ptrCast(*c.struct_stat, st));
        try SquashFsErrorFromInt(err);
    }

    pub fn readlink(sqfs: *SquashFs, inode: *Inode, buf: [*:0]u8, size: *usize) c_uint {
        return c.sqfs_readlink(&sqfs.internal, inode, buf, size);
    }

    pub const Walker = struct {
        internal: c.sqfs_traverse,

        pub const Entry = struct {
            id: InodeId,

            basename: []const u8,
            path: []const u8,
            kind: File.Kind,
        };

        // This just wraps the squashfuse walk function
        pub fn next(walker: *Walker) !?Entry {
            var err: c.sqfs_err = 0;

            if (c.sqfs_traverse_next(&walker.internal, &err)) {
                // Create Zig string from walker path
                var path_slice: []const u8 = undefined;
                path_slice.ptr = walker.internal.path;
                path_slice.len = walker.internal.path_size;
                //var path_slice = std.mem.span(walker.internal.path);

                return .{ .basename = fs.path.basename(path_slice), .path = path_slice, .kind = @intToEnum(File.Kind, walker.internal.entry.type), .id = walker.internal.entry.inode };
            }

            c.sqfs_traverse_close(&walker.internal);
            try SquashFsErrorFromInt(err);

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
};
