const std = @import("std");
const posix = std.posix;

const fuse = @import("fuse");
const squashfuse = @import("squashfuse");
const SquashFs = squashfuse.SquashFs;

pub const FuseOperations = struct {
    // Struct for holding our FUSE info
    pub const Squash = struct {
        image: SquashFs,
        file_tree: std.StringArrayHashMap(SquashFs.Inode.Walker.Entry),
    };

    pub var squash: Squash = undefined;

    pub fn read(path: [:0]const u8, buf: []u8, offset: u64, _: *fuse.FileInfo) fuse.MountError!usize {
        var entry = squash.file_tree.get(path[0..]) orelse return fuse.MountError.NoEntry;
        var inode = entry.inode();
        inode.seekTo(offset) catch return fuse.MountError.Io;

        const read_bytes = inode.read(buf) catch |err| {
            std.debug.print("ERROR: {!}\n", .{err});
            return fuse.MountError.Io;
        };

        return read_bytes;
    }

    pub fn create(_: [:0]const u8, _: std.fs.File.Mode, _: *fuse.FileInfo) fuse.MountError!void {
        return fuse.MountError.ReadOnly;
    }

    pub fn openDir(path: [:0]const u8, fi: *fuse.FileInfo) fuse.MountError!void {
        if (std.mem.eql(u8, path, "/")) {
            var inode = squash.image.getRootInode();

            fi.handle = @intFromPtr(&inode.internal);

            return;
        }

        var entry = squash.file_tree.get(path[0..]) orelse return fuse.MountError.NoEntry;
        var inode = entry.inode();

        if (entry.kind != .directory) return fuse.MountError.NotDir;

        fi.handle = @intFromPtr(&inode.internal);
    }

    pub fn release(_: [:0]const u8, fi: *fuse.FileInfo) fuse.MountError!void {
        fi.handle = 0;
    }

    pub fn releaseDir(_: [:0]const u8, fi: *fuse.FileInfo) fuse.MountError!void {
        fi.handle = 0;
    }

    pub fn readDir(path: [:0]const u8, filler: fuse.FillDir, _: *fuse.FileInfo, _: fuse.ReadDirFlags) fuse.MountError!void {
        var root_inode = squash.image.getRootInode();
        var root_st = root_inode.statC() catch return fuse.MountError.Io;

        // Populate the current and parent directories
        try filler.add(".", &root_st);
        try filler.add("..", null);

        // Skip ahead to where the parent dir is in the hashmap
        var dir_idx: usize = undefined;
        if (std.mem.eql(u8, path, "/")) {
            dir_idx = 0;
        } else {
            dir_idx = squash.file_tree.getIndex(path) orelse return fuse.MountError.NoEntry;
        }

        const keys = squash.file_tree.keys();

        for (keys[dir_idx..]) |key| {
            const dirname = std.fs.path.dirname(key) orelse continue;

            if (key.len <= path.len) continue;
            if (!std.mem.eql(u8, path, key[0..path.len])) break;

            if (std.mem.eql(u8, path, dirname)) {
                const entry = squash.file_tree.get(key) orelse return fuse.MountError.NoEntry;
                var inode = squash.image.getInode(entry.id) catch return fuse.MountError.Io;

                // Load file info into buffer
                var st = inode.statC() catch return fuse.MountError.Io;

                var skip_slash: usize = 0;
                if (path.len > 1) skip_slash = 1;

                // This cast is normally not safe, but I've explicitly added a null
                // byte after the key slices upon creation
                const path_terminated: [*:0]const u8 = @ptrCast(key[dirname.len + skip_slash ..].ptr);

                try filler.add(path_terminated, &st);
            }
        }
    }

    pub fn readLink(path: [:0]const u8, buf: []u8) fuse.MountError![]const u8 {
        var entry = squash.file_tree.get(path) orelse return fuse.MountError.NoEntry;
        var inode = entry.inode();

        if (entry.kind != .sym_link) return fuse.MountError.InvalidArgument;

        return inode.readLink(buf) catch return fuse.MountError.Io;
    }

    pub fn open(path: [:0]const u8, fi: *fuse.FileInfo) fuse.MountError!void {
        const entry = squash.file_tree.get(path) orelse {
            return fuse.MountError.NoEntry;
        };

        if (entry.kind == .directory) {
            return fuse.MountError.IsDir;
        }

        fi.handle = @intFromPtr(&entry.inode().internal);
        fi.keep_cache = true;
    }

    // TODO
    pub fn getXAttr(path: [:0]const u8, name: [:0]const u8, buf: []u8) fuse.MountError!void {
        _ = path;
        _ = name;
        _ = buf;
    }

    pub fn getAttr(path: [:0]const u8, _: *fuse.FileInfo) fuse.MountError!posix.Stat {
        // Load from the root inode
        if (std.mem.eql(u8, path, "/")) {
            var inode = squash.image.getRootInode();

            return inode.statC() catch {
                return fuse.MountError.Io;
            };
        }

        // Otherwise, grab the entry from our filetree hashmap
        var entry = squash.file_tree.get(path) orelse return fuse.MountError.NoEntry;
        var inode = entry.inode();

        return inode.statC() catch {
            return fuse.MountError.Io;
        };
    }
};
