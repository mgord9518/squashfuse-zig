const std = @import("std");
const posix = std.posix;

const fuse = @import("fuse");
const squashfuse = @import("squashfuse");
const SquashFs = squashfuse.SquashFs;

pub const FuseOperations = struct {
    // Struct for holding our FUSE info
    pub const Squash = struct {
        image: *SquashFs,
        open_files: std.AutoHashMap(u64, SquashFs.File),
        open_directories: std.AutoHashMap(u64, SquashFs.Dir),

        // TODO: remove
        file_tree: std.StringArrayHashMap(SquashFs.Dir.Walker.Entry),
    };

    pub var squash: Squash = undefined;

    pub fn read(path: [:0]const u8, buf: []u8, offset: u64, fi: *fuse.FileInfo) fuse.MountError!usize {
        _ = path;

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
        if (std.mem.eql(u8, "/", path)) {
            const dir = squash.image.root();

            const inode = squash.image.getInode(dir.id) catch unreachable;
            fi.handle = inode.base.inode_number;

            return;
        }

        const dir = squash.image.root().openDir(path, .{}) catch return error.NoEntry;

        const inode = squash.image.getInode(dir.id) catch unreachable;

        fi.handle = inode.base.inode_number;

        _ = squash.open_directories.put(fi.handle, dir) catch unreachable;
    }

    pub fn release(_: [:0]const u8, fi: *fuse.FileInfo) fuse.MountError!void {
        var file = squash.open_files.get(fi.handle) orelse return error.NoEntry;
        file.close();

        _ = squash.open_files.remove(fi.handle);

        fi.handle = 0;
    }

    pub fn releaseDir(path: [:0]const u8, fi: *fuse.FileInfo) fuse.MountError!void {
        // Never release root
        // TODO: do this in a better way
        if (std.mem.eql(u8, "/", path)) {
            return;
        }

        var dir = squash.open_directories.get(fi.handle) orelse return error.NoEntry;
        dir.close();

        _ = squash.open_directories.remove(fi.handle);

        fi.handle = 0;
    }

    pub fn readDir(path: [:0]const u8, filler: fuse.FillDir, fi: *fuse.FileInfo, _: fuse.ReadDirFlags) fuse.MountError!void {
        _ = path;

        try filler.add(".", null);
        try filler.add("..", null);

        const dir = squash.open_directories.get(fi.handle) orelse return error.InvalidArgument;
        var it = dir.iterate() catch unreachable;

        while (it.next() catch unreachable) |entry| {
            var buf: [256]u8 = undefined;

            const s = std.fmt.bufPrintZ(&buf, "{s}", .{entry.name}) catch unreachable;

            try filler.add(s, null);
        }
    }

    pub fn readLink(path: [:0]const u8, buf: []u8) fuse.MountError![]const u8 {
        return squash.image.root().readLink(path, buf) catch return error.Io;
    }

    pub fn open(path: [:0]const u8, fi: *fuse.FileInfo) fuse.MountError!void {
        const file = squash.image.root().openFile(path, .{}) catch unreachable;

        fi.handle = file.inode.base.inode_number;

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
