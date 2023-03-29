const std = @import("std");
const fuse = @import("fuse.zig");
const E = fuse.E;

const SquashFs = @import("squashfuse").SquashFs;

// Struct for holding our FUSE info
const Squash = struct {
    image: SquashFs,
    file_tree: std.StringArrayHashMap(SquashFs.Inode.Walker.Entry),
};

pub fn main() !void {
    var allocator = std.heap.c_allocator;

    var args = std.ArrayList([:0]const u8).init(allocator);
    var args_it = std.process.args();

    // Skip ARGV0
    try args.append(args_it.next().?);

    // TODO: error handling and offset
    var sqfs = try SquashFs.init(allocator, args_it.next() orelse "", 0);

    while (args_it.next()) |arg| {
        try args.append(arg);
    }

    // Append single threading flag
    try args.append("-s");

    var file_tree = std.StringArrayHashMap(SquashFs.Inode.Walker.Entry).init(allocator);
    var squash = Squash{ .image = sqfs, .file_tree = file_tree };

    var root_inode = try squash.image.getInode(squash.image.internal.sb.root_inode);
    var walker = try root_inode.walk(allocator);
    defer walker.deinit();

    // Iterate over the SquashFS image
    while (try walker.next()) |entry| {
        // Copy paths as they're automatically cleaned up and we actually want
        // them to stick around
        var buf = try allocator.alloc(u8, entry.path.len + 2);

        // Start new path with slash as squashfuse doesn't supply one
        std.mem.copy(u8, buf[1..], entry.path);
        buf[0] = '/';

        // Make sure to add a null byte, because the keys will be not-so-optimally
        // casted to [*:0]const u8 for use in FUSE
        buf[buf.len - 1] = '\x00';

        const new_path = buf[0 .. buf.len - 1 :0];

        // Now add to the HashMap
        try squash.file_tree.put(new_path, entry);

        //std.debug.print("{s}, {d}\n", .{ new_path, new_path.len });
    }

    try fuse.main(allocator, args.items, &fuse_ops, squash);

    return;
}

export const fuse_ops = fuse.Operations{
    .init = squash_init,
    .getattr = squash_getattr,
    .getxattr = squash_getxattr,
    .open = squash_open,
    .opendir = squash_opendir,
    .release = squash_release,
    .releasedir = squash_releasedir,
    .create = squash_create,
    .read = squash_read,
    .readdir = squash_readdir,
    .readlink = squash_readlink,
};

fn squash_init(nfo: *fuse.ConnectionInfo, conf: *fuse.Config) ?*anyopaque {
    _ = nfo;
    _ = conf;

    return fuse.context().private_data;
}

fn squash_read(p: [*:0]const u8, buf: []u8, o: std.os.linux.off_t, fi: *fuse.FileInfo) c_int {
    _ = fi;

    const path = std.mem.span(p);
    var squash = fuse.privateDataAs(Squash);
    const offset = @intCast(usize, o);

    var entry = squash.file_tree.get(path[0..]) orelse return @enumToInt(E.no_entry);
    var inode = entry.inode();

    const read_bytes = inode.read(buf, offset) catch return @enumToInt(E.io);

    return @intCast(c_int, read_bytes);
}

fn squash_create(_: [*:0]const u8, _: std.os.linux.mode_t, _: *fuse.FileInfo) E {
    return .read_only;
}

fn squash_opendir(p: [*:0]const u8, fi: *fuse.FileInfo) E {
    const path = std.mem.span(p);
    var squash = fuse.privateDataAs(Squash);

    if (std.mem.eql(u8, path, "/")) {
        var inode = squash.image.getInode(squash.image.internal.sb.root_inode) catch return .no_entry;

        fi.handle = @ptrToInt(&inode.internal);

        return .success;
    }

    var entry = squash.file_tree.get(path[0..]) orelse return .no_entry;
    var inode = entry.inode();

    if (entry.kind != .Directory) return .not_dir;

    fi.handle = @ptrToInt(&inode.internal);

    return .success;
}

fn squash_release(_: [*:0]const u8, fi: *fuse.FileInfo) E {
    fi.handle = 0;
    return .success;
}

const squash_releasedir = squash_release;

fn squash_readdir(p: [*:0]const u8, filler: fuse.FillDir, fi: *fuse.FileInfo, flags: fuse.ReadDirFlags) E {
    _ = flags;
    _ = fi;

    var squash = fuse.privateDataAs(Squash);
    var path = std.mem.span(p);

    var root_inode = squash.image.getInode(squash.image.internal.sb.root_inode) catch return .io;
    var root_st = root_inode.statC() catch return .io;

    // Populate the current and parent directories
    filler.add(".", &root_st) catch return .io;
    filler.add("..", null) catch return .io;

    // Skip ahead to where the parent dir is in the hashmap
    var dir_idx: usize = undefined;
    if (std.mem.eql(u8, path, "/")) {
        dir_idx = 0;
    } else {
        dir_idx = squash.file_tree.getIndex(path) orelse return .no_entry;
    }

    const keys = squash.file_tree.keys();

    for (keys[dir_idx..]) |key| {
        const dirname = std.fs.path.dirname(key) orelse continue;

        if (key.len <= path.len) continue;
        if (!std.mem.eql(u8, path, key[0..path.len])) break;

        if (std.mem.eql(u8, path, dirname)) {
            var entry = squash.file_tree.get(key) orelse return .no_entry;
            var inode = squash.image.getInode(entry.id) catch return .io;

            // Load file info into buffer
            var st = inode.statC() catch return .io;

            var skip_slash: usize = 0;
            if (path.len > 1) skip_slash = 1;

            // This cast is normally not safe, but I've explicitly added a null
            // byte after the key slices upon creation
            const path_terminated = @ptrCast([*:0]const u8, key[dirname.len + skip_slash ..].ptr);

            filler.add(path_terminated, &st) catch return .io;
        }
    }

    return .success;
}

fn squash_readlink(p: [*:0]const u8, buf: []u8) E {
    const path = std.mem.span(p);
    var squash = fuse.privateDataAs(Squash);

    var entry = squash.file_tree.get(path) orelse return .no_entry;
    var inode = entry.inode();

    if (entry.kind != .SymLink) return .invalid_argument;

    inode.readLink(buf) catch return .io;

    return .success;
}

fn squash_open(p: [*:0]const u8, fi: *fuse.FileInfo) E {
    const path = std.mem.span(p);
    var squash = fuse.privateDataAs(Squash);

    const entry = squash.file_tree.get(path) orelse return .no_entry;

    if (entry.kind == .Directory) return .is_dir;

    fi.handle = @ptrToInt(&entry.inode().internal);
    fi.keep_cache = true;

    return .success;
}

fn squash_getxattr(p: [*:0]const u8, r: [*:0]const u8, buf: []u8) E {
    _ = p;
    _ = r;
    _ = buf;

    return .success;
}

fn squash_getattr(p: [*:0]const u8, stbuf: *std.os.linux.Stat, _: *fuse.FileInfo) E {
    const path = std.mem.span(p);
    var squash = fuse.privateDataAs(Squash);

    // Load from the root inode
    if (std.mem.eql(u8, path, "/")) {
        var inode = squash.image.getInode(squash.image.internal.sb.root_inode) catch return .no_entry;
        stbuf.* = inode.statC() catch return .io;

        return .success;
    }

    // Otherwise, grab the entry from our filetree hashmap
    var entry = squash.file_tree.get(path) orelse return .no_entry;
    var inode = entry.inode();

    stbuf.* = inode.statC() catch return .io;

    return .success;
}

fn debug(fmt: []const u8) void {
    std.debug.print(fmt, .{});
}
