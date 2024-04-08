const std = @import("std");
const fmt = std.fmt;
const io = std.io;
const posix = std.posix;

const fuse = @import("fuse");
const clap = @import("clap");

const SquashFs = @import("squashfuse").SquashFs;

// Struct for holding our FUSE info
const Squash = struct {
    image: SquashFs,
    file_tree: std.StringArrayHashMap(SquashFs.Inode.Walker.Entry),
};

var squash: Squash = undefined;

const version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 0,
};

pub fn main() !void {
    var allocator = std.heap.c_allocator;

    // TODO: buffered IO
    var stderr = std.io.getStdErr().writer();
    var stdout = std.io.getStdOut().writer();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             display this help and exit
        \\-f, --foreground       run in foreground
        \\-d, --debug            enable debug output (runs in foreground)
        \\-x, --extract          extract the SquashFS image
        \\-l, --list             list file tree of SquashFS image
        \\-o, --option <str>...  use a libFUSE mount option
        \\
        \\--offset <usize>      mount at an offset
        \\--extract-src <str>   must be used with `--extract`; specify the source inode
        \\--extract-dest <str>  must be used with `--extract`; specify the destination name
        \\--version             print the current version
        \\--verbose             enable verbose printing
        \\
        \\<str>...
    );

    const env_map = try std.process.getEnvMap(allocator);

    if (env_map.get("NO_COLOR")) |_| {
        reset = "";
        orange = "";
        red = "";
        light_blue = "";
        light_green = "";
        cyan = "";
    }

    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .allocator = allocator,
    }) catch |err| {
        const error_string = switch (err) {
            error.InvalidArgument => "unknown option given; use `--help` to get available options",
            else => return err,
        };

        try stderr.print("{s}::{s} {s}\n", .{
            red,
            reset,
            error_string,
        });

        std.posix.exit(1);
    };

    defer res.deinit();

    var args = std.ArrayList([:0]const u8).init(allocator);
    var args_it = std.process.args();

    // Skip ARGV0
    try args.append(args_it.next().?);

    var sqfs: SquashFs = undefined;

    // TODO: move formatting code into its own function or possibly new package
    if (res.args.help != 0 or res.positionals.len == 0) {
        // Obtain the longest argument length
        var longest_normal: usize = 0;
        var longest_long_only: usize = 0;
        for (params) |param| {
            if (param.names.long) |long_name| {
                const suffix = if (param.id.val.len > 0) param.id.val.len + 3 else 0;
                const new_len = long_name.len + suffix;
                if (param.names.short) |_| {
                    if (new_len > longest_normal) longest_normal = new_len;
                } else {
                    if (new_len > longest_long_only) longest_long_only = new_len;
                }
            }
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
                var type_len: usize = 0;

                try stderr.print("  {s}--{s}{s}", .{ cyan, long_name, reset });
                if (param.id.val.len > 0) {
                    type_len = param.id.val.len + 3;
                }
                try stderr.print(":", .{});

                // Pad all equal to the longest GNU-style flag
                for (long_name.len + type_len..longest_normal) |_| {
                    try stderr.print(" ", .{});
                }

                if (param.id.val.len > 0) {
                    try stderr.print(" <{s}>", .{param.id.val});
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

                var type_len: usize = 0;

                try stderr.print("  {s}--{s}{s}", .{ cyan, long_name, reset });
                if (param.id.val.len > 0) {
                    type_len = param.id.val.len + 3;
                }
                try stderr.print(":", .{});

                // Pad all equal to the longest GNU-style flag
                for (long_name.len + type_len..longest_long_only) |_| {
                    try stderr.print(" ", .{});
                }

                if (param.id.val.len > 0) {
                    try stderr.print(" <{s}>", .{param.id.val});
                }

                try stderr.print("  {s}\n", .{param.id.description()});
            }
        }

        try stderr.print(
            \\
            \\{s}enviornment variables{s}:
            \\  {s}NO_COLOR{1s}: disable color
            \\
            \\{0s}this build can decompress{1s}:
            \\
        , .{ orange, reset, cyan });

        inline for (std.meta.fields(SquashFs.Compression)) |algo| {
            try stderr.print(
                \\  {s}{s}{s},
                \\
            , .{ cyan, algo.name, reset });
        }

        return;
    }

    var offset: usize = 0;

    for (res.args.option) |opt| {
        // Check if `offset` called as an option as squashfuse supports it
        if (opt.len >= 7 and std.mem.eql(u8, opt[0..7], "offset=")) {
            const num_str = opt[7..];

            offset = std.fmt.parseInt(usize, num_str, 0) catch {
                try stderr.print("{s}::{s} invalid offset given: {s}\n", .{
                    red,
                    reset,
                    num_str,
                });

                std.posix.exit(1);
            };
        } else {
            // If not, just pass the option on to libfuse
            try args.appendSlice(&[_][:0]const u8{
                "-o",
                try allocator.dupeZ(u8, opt),
            });
        }
    }

    for (res.positionals, 0..) |arg, idx| {
        // Open the SquashFS image in the first positional argument
        if (idx == 0) {
            if (res.args.offset) |o| {
                offset = o;
            }

            sqfs = SquashFs.init(allocator, arg, .{
                .offset = offset,
            }) catch |err| {
                const error_string = switch (err) {
                    error.InvalidCompression => "unsupported compression algorithm",
                    error.InvalidFormat => "unknown file type, doesn't look like a SquashFS image",
                    error.FileNotFound => try std.fmt.allocPrint(allocator, "file `{s}` not found", .{arg}),
                    error.AccessDenied => "permission denied",
                    error.IsDir => "attempted to open directory as SquashFS image",
                    else => return err,
                };

                try stderr.print("{s}::{s} failed to read image: {s}\n", .{
                    red,
                    reset,
                    error_string,
                });

                posix.exit(1);
            };

            continue;
        }

        if (idx > 1) {
            try stderr.print("{s}::{s} failed to parse args: too many arguments\n", .{ red, reset });
            posix.exit(1);
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

    const file_tree = std.StringArrayHashMap(SquashFs.Inode.Walker.Entry).init(allocator);
    squash = Squash{ .image = sqfs, .file_tree = file_tree };
    defer sqfs.deinit();

    var extract_args_len: usize = 0;
    for (res.args.extract) |_| {
        extract_args_len += 1;
    }

    const src = res.args.@"extract-src" orelse "/";

    // TODO: use basename of src if not `/`
    const dest = res.args.@"extract-dest" orelse "squashfs-root";

    var root_inode = squash.image.getRootInode();

    if (res.args.extract != 0) {
        try extractArchive(
            allocator,
            &sqfs,
            src,
            dest,
            .{ .verbose = res.args.verbose != 0 },
        );

        return;
    }

    var walker = try root_inode.walk(allocator);
    defer walker.deinit();

    if (res.args.list != 0) {
        while (try walker.next()) |entry| {
            try stdout.print("{s}\n", .{entry.path});
        }

        return;
    }

    // Populate the file_tree
    while (try walker.next()) |entry| {
        // Start new path with slash as squashfuse doesn't supply one
        // and add a null byte
        const new_path = try std.fmt.allocPrintZ(allocator, "/{s}", .{entry.path});

        // Now add to the HashMap
        try squash.file_tree.put(new_path, entry);
    }

    // TODO: nicer error printing
    fuse.run(
        allocator,
        args.items,
        FuseOperations,
        squash,
    ) catch |err| {
        const error_string = switch (err) {
            error.NoMountPoint => "unsupported compression algorithm",
            else => return err,
        };

        try stderr.print("{s}::{s} failed to read image: {s}\n", .{
            red,
            reset,
            error_string,
        });

        posix.exit(1);
    };

    return;
}

const FuseOperations = struct {
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

const ExtractArchiveOptions = struct {
    verbose: bool = false,
};

fn extractArchive(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    src: []const u8,
    dest: []const u8,
    opts: ExtractArchiveOptions,
) !void {
    var stdout = io.getStdOut().writer();
    //var stderr = io.getStdErr().writer();

    var root_inode = sqfs.getRootInode();

    var walker = try root_inode.walk(allocator);
    defer walker.deinit();

    // Remove slashes at the beginning and end of path
    var real_src = if (src[0] == '/') blk: {
        break :blk src[1..];
    } else blk: {
        break :blk src;
    };

    if (real_src.len > 0 and real_src[real_src.len - 1] == '/') {
        real_src.len -= 1;
    }

    if (real_src.len == 0) {
        const cwd = std.fs.cwd();
        cwd.makeDir(
            dest,
        ) catch |err| {
            switch (err) {
                error.PathAlreadyExists => {},

                else => return err,
            }
        };
    }

    var file_found = false;

    // TODO: flag to change buf size
    const buf_size = 1024 * 1024;
    const buf = try allocator.alloc(u8, buf_size);
    defer allocator.free(buf);

    // Iterate over the SquashFS image and extract each item
    while (try walker.next()) |entry| {
        // Skip if the path doesn't match our source
        if (entry.path.len < real_src.len or !std.mem.eql(u8, real_src, entry.path[0..real_src.len])) {
            continue;
        }

        // Skip files that begin with the same path but aren't the exact same
        // or a directory
        //
        // Example:
        // `test/file` would pass this test
        // `test`      would also pass
        // `test-file` would fail and get skipped
        if (real_src.len > 0 and entry.path.len > real_src.len and entry.path[real_src.len] != '/') {
            continue;
        }

        file_found = true;

        var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const prefixed_dest = switch (real_src.len) {
            0 => try fmt.bufPrint(&path_buf, "{s}/{s}", .{
                dest,
                entry.path,
            }),
            else => try fmt.bufPrint(&path_buf, "{s}{s}", .{
                dest,
                entry.path[real_src.len..],
            }),
        };

        if (opts.verbose) {
            try stdout.print("{s}\n", .{prefixed_dest});
        }

        var inode = entry.inode();
        try inode.extract(buf, prefixed_dest);
    }

    // TODO: better error message
    if (!file_found) {
        std.debug.print("file ({s}) not found!\n", .{real_src});
    }
}

var reset: []const u8 = "\x1b[0;0m";
var orange: []const u8 = "\x1b[0;33m";
var red: []const u8 = "\x1b[0;31m";
var light_blue: []const u8 = "\x1b[0;94m";
var light_green: []const u8 = "\x1b[0;92m";
var cyan: []const u8 = "\x1b[0;36m";
