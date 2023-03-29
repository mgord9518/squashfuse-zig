const std = @import("std");
const fuse = @import("fuse.zig");
const clap = @import("clap");
const E = fuse.E;

const SquashFs = @import("squashfuse").SquashFs;

// Struct for holding our FUSE info
const Squash = struct {
    image: SquashFs,
    file_tree: std.StringArrayHashMap(SquashFs.Inode.Walker.Entry),
};

pub fn main() !void {
    var allocator = std.heap.c_allocator;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help            display this help and exit
        \\-f, --foreground      run in foreground
        \\-d, --debug           enable debug output (runs in foreground)
        \\-o, --option          use a mount option
        \\
        \\    --offset <usize>  mount at an offset
        \\<str>...
    );

    var res = try clap.parse(clap.Help, &params, clap.parsers.default, .{});
    defer res.deinit();

    var args = std.ArrayList([:0]const u8).init(allocator);
    var args_it = std.process.args();

    // Skip ARGV0
    try args.append(args_it.next().?);

    var sqfs: SquashFs = undefined;

    var reset: []const u8 = "\x1b[0;0m";
    var orange: []const u8 = "\x1b[0;33m";
    var red: []const u8 = "\x1b[0;31m";
    var light_blue: []const u8 = "\x1b[0;94m";
    var light_green: []const u8 = "\x1b[0;92m";
    var cyan: []const u8 = "\x1b[0;36m";

    if (res.args.help or res.positionals.len == 0) {
        // Obtain the longest argument length
        var longest_normal: usize = 0;
        var longest_long_only: usize = 0;
        for (params) |param| {
            if (param.names.long) |long_name| {
                if (param.names.short) |_| {
                    if (long_name.len > longest_normal) longest_normal = long_name.len;
                } else {
                    if (long_name.len > longest_long_only) longest_long_only = long_name.len;
                }
            }
        }

        const env_map = try std.process.getEnvMap(allocator);

        if (env_map.get("NO_COLOR")) |_| {
            reset = "";
            orange = "";
            light_blue = "";
            light_green = "";
            cyan = "";
        }

        std.debug.print(
            \\{s}usage{s}: {s}{s} {s}[{s}archive{s}] [{s}mountpoint{s}] [{s}option{s}]...
            \\{s}description{s}: mount SquashFS images
            \\
            \\{s}normal options{s}:
            \\
        , .{ orange, reset, light_blue, args.items[0], reset, light_blue, reset, light_blue, reset, cyan, reset, orange, reset, orange, reset });

        // Print all normal arguments and their descriptions
        for (params) |param| {
            if (param.names.short) |short_name| {
                std.debug.print("  {s}-{c}{s}, ", .{ cyan, short_name, reset });
            } else {
                continue;
            }

            if (param.names.long) |long_name| {
                std.debug.print("{s}--{s}{s}:", .{ cyan, long_name, reset });

                // Pad all equal to the longest GNU-style flag
                for (long_name.len..longest_normal) |_| {
                    std.debug.print(" ", .{});
                }

                std.debug.print("  {s}\n", .{param.id.description()});
            }
        }

        std.debug.print(
            \\
            \\{s}long-only options{s}:
            \\
        , .{ orange, reset });

        for (params) |param| {
            if (param.names.long) |long_name| {
                if (param.names.short) |_| continue;

                std.debug.print("  {s}--{s}{s}:", .{ cyan, long_name, reset });

                // Pad all equal to the longest GNU-style flag
                for (long_name.len..longest_long_only) |_| {
                    std.debug.print(" ", .{});
                }

                std.debug.print("  {s}\n", .{param.id.description()});
            }
        }

        std.debug.print(
        //            \\
        //            \\{s}mount options{s}:
        //            \\  {s}offset{s}: <usize> mount at an offset
            \\
            \\{s}enviornment variables{s}:
            \\  {s}NO_COLOR{s}: disable color
            \\
            \\
            //, .{ orange, reset, cyan, reset, orange, reset, cyan, reset });
        , .{ orange, reset, cyan, reset });

        return;
    }

    for (res.positionals, 0..) |arg, idx| {
        // Open the SquashFS image in the first positional argument
        if (idx == 0) {
            const offset = res.args.offset orelse 0;

            sqfs = SquashFs.init(allocator, arg, offset) catch |err| {
                std.debug.print("{s}::{s} failed to open image: {!}\n", .{ red, reset, err });
                std.os.exit(1);
            };

            continue;
        }

        if (idx > 1) {
            std.debug.print("{s}::{s} failed to parse args: too many arguments\n", .{ red, reset });
            std.os.exit(1);
        }

        // pass further positional args to FUSE
        const c_arg = try std.cstr.addNullByte(allocator, arg);
        try args.append(c_arg);
    }

    if (res.args.debug) {
        try args.append("-d");
    } else if (res.args.foreground) {
        try args.append("-f");
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
    }

    // TODO: nicer error printing
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
