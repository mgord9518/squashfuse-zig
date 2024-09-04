const std = @import("std");
const posix = std.posix;

const fuse = @import("fuse");
const squashfuse = @import("squashfuse");
const SquashFs = squashfuse.SquashFs;

pub const FuseOperations = struct {
    // Struct for holding our FUSE info
    pub const Squash = struct {
        image: *SquashFs,
        file_tree: std.StringArrayHashMap(SquashFs.Dir.Walker.Entry),
        open_files: std.AutoHashMap(u64, SquashFs.File),
    };

    pub var squash: Squash = undefined;

    pub fn read(path: [:0]const u8, buf: []u8, offset: u64, fi: *fuse.FileInfo) fuse.MountError!usize {
        _ = squash.file_tree.get(path) orelse return error.NoEntry;

        var file = squash.open_files.get(fi.handle) orelse return error.InvalidArgument;

        const read_bytes = file.pread(buf, offset) catch |err| {
            std.debug.print("squashfuse-zig error: {!}\n", .{err});
            return fuse.MountError.Io;
        };

        return read_bytes;
    }

    pub fn create(_: [:0]const u8, _: std.fs.File.Mode, _: *fuse.FileInfo) fuse.MountError!void {
        return error.ReadOnly;
    }

    pub fn openDir(path: [:0]const u8, fi: *fuse.FileInfo) fuse.MountError!void {
        if (std.mem.eql(u8, path, "/")) {
            fi.handle = @bitCast(squash.image.super_block.root_inode_id);

            return;
        }

        const entry = squash.file_tree.get(path[0..]) orelse return fuse.MountError.NoEntry;

        fi.handle = @bitCast(entry.id);
    }

    pub fn release(_: [:0]const u8, fi: *fuse.FileInfo) fuse.MountError!void {
        var file = squash.open_files.get(fi.handle) orelse return error.NoEntry;
        file.close();

        _ = squash.open_files.remove(fi.handle);

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
        const entry = squash.file_tree.get(path) orelse return fuse.MountError.NoEntry;
        var inode = squash.image.getInode(
            entry.id,
        ) catch unreachable;

        if (entry.kind != .sym_link) return fuse.MountError.InvalidArgument;

        return inode.readLink(buf) catch return fuse.MountError.Io;
    }

    pub fn open(path: [:0]const u8, fi: *fuse.FileInfo) fuse.MountError!void {
        const entry = squash.file_tree.get(path) orelse return fuse.MountError.NoEntry;

        const file = SquashFs.File.initFromInode(
            squash.image.getInode(
                entry.id,
            ) catch unreachable,
        );

        fi.handle = @bitCast(entry.id);

        _ = squash.open_files.put(fi.handle, file) catch unreachable;
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
        const entry = squash.file_tree.get(path) orelse return fuse.MountError.NoEntry;
        var inode = squash.image.getInode(
            entry.id,
        ) catch unreachable;

        return inode.statC() catch {
            return fuse.MountError.Io;
        };
    }
};
