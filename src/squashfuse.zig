const std = @import("std");
const fmt = std.fmt;
const fuse = @import("fuse.zig");
const clap = @import("clap");
const E = fuse.E;
const linux = std.os.linux;

const SquashFs = @import("squashfuse").SquashFs;

// Struct for holding our FUSE info
const Squash = struct {
    image: SquashFs,
    file_tree: std.StringArrayHashMap(SquashFs.Inode.Walker.Entry),
};

const version = std.SemanticVersion{
    .major = 0,
    .minor = 0,
    .patch = 37,
};

pub fn main() !void {
    var allocator = std.heap.c_allocator;

    // TODO: buffered IO
    var stderr = std.io.getStdErr().writer();
    var stdout = std.io.getStdOut().writer();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help            display this help and exit
        \\-f, --foreground      run in foreground
        \\-d, --debug           enable debug output (runs in foreground)
        // TODO:        \\-x, --extract         extract the entire SquashFS image
        \\-l, --list            list file tree of SquashFS image
        \\-o, --option <str>... use a mount option
        \\
        \\    --offset <usize>  mount at an offset
        \\    --version         print the current version
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

    if (res.args.help != 0 or res.positionals.len == 0) {
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

        if (res.args.version != 0) {
            try stderr.print("{d}.{d}.{d}\n", .{
                version.major,
                version.minor,
                version.patch,
            });

            return;
        }

        try stderr.print(
            \\{s}usage{s}: {s}{s} {s}[{s}archive{s}] [{s}mountpoint{s}] [{s}option{s}]...
            \\{s}description{s}: mount SquashFS images
            \\
            \\{s}normal options{s}:
            \\
        , .{ orange, reset, light_blue, args.items[0], reset, light_blue, reset, light_blue, reset, cyan, reset, orange, reset, orange, reset });

        // Print all normal arguments and their descriptions
        for (params) |param| {
            if (param.names.short) |short_name| {
                try stderr.print("  {s}-{c}{s}, ", .{ cyan, short_name, reset });
            } else {
                continue;
            }

            if (param.names.long) |long_name| {
                try stderr.print("{s}--{s}{s}:", .{ cyan, long_name, reset });

                // Pad all equal to the longest GNU-style flag
                for (long_name.len..longest_normal) |_| {
                    try stderr.print(" ", .{});
                }

                try stderr.print("  {s}\n", .{param.id.description()});
            }
        }

        try stderr.print(
            \\
            \\{s}long-only options{s}:
            \\
        , .{ orange, reset });

        for (params) |param| {
            if (param.names.long) |long_name| {
                if (param.names.short) |_| continue;

                try stderr.print("  {s}--{s}{s}:", .{ cyan, long_name, reset });

                // Pad all equal to the longest GNU-style flag
                for (long_name.len..longest_long_only) |_| {
                    try stderr.print(" ", .{});
                }

                try stderr.print("  {s}\n", .{param.id.description()});
            }
        }

        try stderr.print(
            \\
            \\{s}enviornment variables{s}:
            \\  {s}NO_COLOR{s}: disable color
            \\
            \\
        , .{ orange, reset, cyan, reset });

        return;
    }

    var offset: usize = 0;

    for (res.args.option) |opt| {
        // Check if `offset` called as an option as squashfuse supports it
        if (opt.len >= 7 and std.mem.eql(u8, opt[0..7], "offset=")) {
            const num_str = opt[7..];

            offset = std.fmt.parseInt(usize, num_str, 0) catch {
                try stderr.print("{s}::{s} invalid offset given: {s}\n", .{ red, reset, num_str });
                std.os.exit(1);
            };
        } else {
            // If not, just pass the option on to libfuse
            const c_opt = try allocator.dupeZ(u8, opt);

            try args.appendSlice(&[_][:0]const u8{ "-o", c_opt });
        }
    }

    for (res.positionals, 0..) |arg, idx| {
        // Open the SquashFS image in the first positional argument
        if (idx == 0) {
            if (res.args.offset) |o| {
                offset = o;
            }

            sqfs = SquashFs.init(allocator, arg, offset) catch |err| {
                try stderr.print("{s}::{s} failed to open image: {!}\n", .{ red, reset, err });
                std.os.exit(1);
            };

            continue;
        }

        if (idx > 1) {
            try stderr.print("{s}::{s} failed to parse args: too many arguments\n", .{ red, reset });
            std.os.exit(1);
        }

        // Pass further positional args to FUSE
        const c_arg = try allocator.dupeZ(u8, arg);
        try args.append(c_arg);
    }

    if (res.args.debug != 0) {
        try args.append("-d");
    } else if (res.args.foreground != 0) {
        try args.append("-f");
    }

    // Append single threading flag
    try args.append("-s");

    var file_tree = std.StringArrayHashMap(SquashFs.Inode.Walker.Entry).init(allocator);
    var squash = Squash{ .image = sqfs, .file_tree = file_tree };

    var root_inode = squash.image.getRootInode();
    var walker = try root_inode.walk(allocator);
    defer walker.deinit();

    if (res.args.list != 0) {
        while (try walker.next()) |entry| {
            try stdout.print("{s}\n", .{entry.path});
        }

        return;
    }

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

fn squash_init(nfo: *fuse.ConnectionInfo, conf: *fuse.Config) callconv(.C) ?*anyopaque {
    _ = nfo;
    _ = conf;

    return fuse.context().private_data;
}

fn squash_read(p: [*:0]const u8, b: [*]u8, len: usize, o: std.os.linux.off_t, fi: *fuse.FileInfo) callconv(.C) c_int {
    _ = fi;

    var buf = b[0..len];

    const path = std.mem.span(p);
    var squash = fuse.privateDataAs(Squash);
    const offset: usize = @intCast(o);

    var entry = squash.file_tree.get(path[0..]) orelse return @intFromEnum(E.no_entry);
    var inode = entry.inode();
    inode.seekTo(offset);

    const read_bytes = inode.read(buf) catch return @intFromEnum(E.io);

    return @intCast(read_bytes);
}

fn squash_create(_: [*:0]const u8, _: std.os.linux.mode_t, _: *fuse.FileInfo) callconv(.C) E {
    return .read_only;
}

fn squash_opendir(p: [*:0]const u8, fi: *fuse.FileInfo) callconv(.C) E {
    const path = std.mem.span(p);
    var squash = fuse.privateDataAs(Squash);

    if (std.mem.eql(u8, path, "/")) {
        var inode = squash.image.getRootInode();

        fi.handle = @intFromPtr(&inode.internal);

        return .success;
    }

    var entry = squash.file_tree.get(path[0..]) orelse return .no_entry;
    var inode = entry.inode();

    if (entry.kind != .directory) return .not_dir;

    fi.handle = @intFromPtr(&inode.internal);

    return .success;
}

fn squash_release(_: [*:0]const u8, fi: *fuse.FileInfo) callconv(.C) E {
    fi.handle = 0;
    return .success;
}

const squash_releasedir = squash_release;

fn squash_readdir(p: [*:0]const u8, filler: fuse.FillDir, _: linux.off_t, fi: *fuse.FileInfo, flags: fuse.ReadDirFlags) callconv(.C) E {
    _ = flags;
    _ = fi;

    var squash = fuse.privateDataAs(Squash);
    var path = std.mem.span(p);

    var root_inode = squash.image.getRootInode();
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
            const path_terminated: [*:0]const u8 = @ptrCast(key[dirname.len + skip_slash ..].ptr);

            try filler.add(path_terminated, &st);
        }
    }

    return .success;
}

fn squash_readlink(p: [*:0]const u8, b: [*]u8, len: usize) callconv(.C) E {
    var buf = b[0..len];

    const path = std.mem.span(p);
    var squash = fuse.privateDataAs(Squash);

    var entry = squash.file_tree.get(path) orelse return .no_entry;
    var inode = entry.inode();

    if (entry.kind != .sym_link) return .invalid_argument;

    inode.readLink(buf) catch return .io;

    return .success;
}

fn squash_open(p: [*:0]const u8, fi: *fuse.FileInfo) callconv(.C) E {
    const path = std.mem.span(p);
    var squash = fuse.privateDataAs(Squash);

    const entry = squash.file_tree.get(path) orelse return .no_entry;

    if (entry.kind == .directory) return .is_dir;

    fi.handle = @intFromPtr(&entry.inode().internal);
    fi.keep_cache = true;

    return .success;
}

// TODO
fn squash_getxattr(p: [*:0]const u8, r: [*:0]const u8, b: [*]u8, len: usize) callconv(.C) E {
    var buf = b[0..len];

    _ = p;
    _ = r;
    _ = buf;

    return .success;
}

fn squash_getattr(p: [*:0]const u8, stbuf: *std.os.linux.Stat, _: *fuse.FileInfo) callconv(.C) E {
    const path = std.mem.span(p);
    var squash = fuse.privateDataAs(Squash);

    // Load from the root inode
    if (std.mem.eql(u8, path, "/")) {
        var inode = squash.image.getRootInode();
        stbuf.* = inode.statC() catch return .io;

        return .success;
    }

    // Otherwise, grab the entry from our filetree hashmap
    var entry = squash.file_tree.get(path) orelse return .no_entry;
    var inode = entry.inode();

    stbuf.* = inode.statC() catch return .io;

    return .success;
}
