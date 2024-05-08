const std = @import("std");
const fmt = std.fmt;
const io = std.io;
const posix = std.posix;

const fuse = @import("fuse");
const clap = @import("clap");
const squashfuse = @import("squashfuse");
const SquashFs = squashfuse.SquashFs;
const ls_colors = @import("ls_colors.zig");

const S = std.os.linux.S;

pub const build_options = squashfuse.build_options;

const FuseOperations = @import("fuse_operations.zig").FuseOperations;

const version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 1,
};

var env_map: std.process.EnvMap = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // TODO: buffered IO
    var stderr = std.io.getStdErr().writer();
    var stdout = std.io.getStdOut().writer();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             display this help and exit
        \\-f, --foreground       run in foreground
        \\-d, --debug            enable debug output (runs in foreground)
        \\-x, --extract          extract the SquashFS image
        \\-l, --list             list file tree of SquashFS image (use `-ll` for long format)
        \\-o, --option <str>...  use a libFUSE mount option
        \\-v, --version          print the program version
        \\
        \\--offset <usize>      open SquashFS at an offset
        \\--extract-src <str>   must be used with `--extract`; specify the source inode
        \\--extract-dest <str>  must be used with `--extract`; specify the destination name
        \\--verbose             enable verbose printing
        \\
        \\<str>...
    );

    env_map = try std.process.getEnvMap(allocator);

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
    var args_it = try std.process.argsWithAllocator(allocator);
    defer args_it.deinit();

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
            \\{0s}usage{s}: {2s}{3s} {1s}[{4s}-hfdxlov{1s}] <{2s}archive{1s}> [{2s}mountpoint{1s}] 
            \\{0s}description{1s}: read SquashFS images
            \\
            \\{0s}normal options{1s}:
            \\
        , .{ orange, reset, light_blue, args.items[0], cyan });

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

        var can_decompress = false;
        inline for (comptime std.meta.tags(SquashFs.Compression)) |algo| {
            if (squashfuse.compression.builtWithDecompression(algo)) {
                can_decompress = true;

                try stderr.print(
                    \\  {s}{s}{s},
                    \\
                , .{ cyan, @tagName(algo), reset });
            }
        }

        if (!can_decompress) {
            try stderr.print(
                \\  {s}nothing.
                \\  it can't decompress anything
                \\  what were you thinking with those build options?{s}
                \\
            , .{ cyan, reset });
        }

        try stderr.print("\n", .{});

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
    FuseOperations.squash = FuseOperations.Squash{ .image = sqfs, .file_tree = file_tree };
    defer sqfs.deinit();

    var extract_args_len: usize = 0;
    for (res.args.extract) |_| {
        extract_args_len += 1;
    }

    const src = res.args.@"extract-src" orelse "/";

    // TODO: use basename of src if not `/`
    const dest = res.args.@"extract-dest" orelse "squashfs-root";

    var root_inode = FuseOperations.squash.image.getRootInode();

    if (res.args.extract != 0) {
        extractArchive(
            allocator,
            &sqfs,
            src,
            dest,
            .{ .verbose = res.args.verbose != 0 },
        ) catch |err| {
            const error_string = switch (err) {
                error.PathAlreadyExists => "path already exists",
                else => return err,
            };

            try stderr.print("{s}::{s} failed to extract image: {s}\n", .{
                red,
                reset,
                error_string,
            });

            posix.exit(1);
        };

        return;
    }

    var walker = try root_inode.walk(allocator);
    defer walker.deinit();

    if (res.args.list != 0) {
        // Long printing
        var st_buf: [10]u8 = undefined;
        var col_buf: [4096]u8 = undefined;
        const colors = env_map.get("LS_COLORS") orelse "";

        while (try walker.next()) |entry| {
            var inode = entry.inode();

            const color = try ls_colors.getEntryColor(entry, colors, &col_buf);

            const st = try inode.statC();

            if (res.args.list == 2) {
                st_buf[0] = switch (entry.kind) {
                    .file => '-',
                    .directory => 'd',
                    .sym_link => 'l',
                    .named_pipe => 'p',
                    .character_device => 'c',
                    .block_device => 'c',
                    .unix_domain_socket => 's',
                };

                st_buf[1] = if (st.mode & S.IRUSR != 0) 'r' else '-';
                st_buf[2] = if (st.mode & S.IWUSR != 0) 'w' else '-';
                st_buf[3] = if (st.mode & S.IXUSR != 0) 'x' else '-';

                st_buf[4] = if (st.mode & S.IRGRP != 0) 'r' else '-';
                st_buf[5] = if (st.mode & S.IWGRP != 0) 'w' else '-';
                st_buf[6] = if (st.mode & S.IXGRP != 0) 'x' else '-';

                st_buf[7] = if (st.mode & S.IROTH != 0) 'r' else '-';
                st_buf[8] = if (st.mode & S.IWOTH != 0) 'w' else '-';
                st_buf[9] = if (st.mode & S.IXOTH != 0) 'x' else '-';

                try stdout.print("{s}{s} {0s}{d} {d} {d} {s}{s}{0s}\n", .{
                    reset,
                    st_buf[0..10],
                    inode.internal.nlink,
                    st.uid,
                    st.gid,
                    color,
                    entry.path,
                });
            } else {
                try stdout.print("{s}{s}{s}\n", .{ color, entry.path, reset });
            }
        }

        return;
    }

    // Populate the file_tree
    while (try walker.next()) |entry| {
        // Start new path with slash as squashfuse doesn't supply one
        // and add a null byte
        const new_path = try std.fmt.allocPrintZ(allocator, "/{s}", .{entry.path});

        // Now add to the HashMap
        try FuseOperations.squash.file_tree.put(new_path, entry);
    }

    if (!build_options.@"enable-fuse") return;

    // TODO: nicer error printing
    fuse.run(
        allocator,
        args.items,
        FuseOperations,
        FuseOperations.squash,
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
}

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
