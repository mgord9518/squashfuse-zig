const std = @import("std");
const fmt = std.fmt;
const clap = @import("clap");

const SquashFs = @import("squashfuse").SquashFs;

const Version = struct {
    prefix: ?[]const u8 = null,

    major: u8,
    minor: u8,
    patch: u8,

    pub fn string(self: *const Version, buf: []u8) []const u8 {
        if (self.prefix) |prefix| {
            return fmt.bufPrint(buf, "{s}-{d}.{d}.{d}", .{
                prefix,
                self.major,
                self.minor,
                self.patch,
            }) catch unreachable;
        }

        return fmt.bufPrint(buf, "{d}.{d}.{d}", .{
            self.major,
            self.minor,
            self.patch,
        }) catch unreachable;
    }
};

const version = Version{
    .major = 0,
    .minor = 0,
    .patch = 1,
};

pub fn main() !void {
    var allocator = std.heap.c_allocator;

    var stderr = std.io.getStdErr().writer();
    var stdout = std.io.getStdOut().writer();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help            display this help and exit
        \\
        \\    --offset <usize>  access at an offset
        \\    --version         print the current version
        \\<str>...
    );

    var res = try clap.parse(clap.Help, &params, clap.parsers.default, .{});
    defer res.deinit();

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
            var buf: [32]u8 = undefined;
            const ver_str = version.string(&buf);

            try stderr.print("{s}\n", .{ver_str});
            return;
        }

        try stderr.print(
            \\{s}usage{s}: {s}{s} {s}[{s}archive{s}] [{s}option{s}]...
            \\{s}description{s}: list all of the files in a SquashFS image
            \\
            \\{s}normal options{s}:
            \\
        , .{ orange, reset, light_blue, "squashfuse_ls", reset, light_blue, reset, cyan, reset, orange, reset, orange, reset });

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

    var sqfs: SquashFs = undefined;

    for (res.positionals, 0..) |arg, idx| {
        if (idx > 0) {
            try stderr.print("{s}::{s} failed to parse args: too many arguments\n", .{ red, reset });
            std.os.exit(1);
        }

        // Open the SquashFS image in the first positional argument
        if (res.args.offset) |o| {
            offset = o;
        }

        sqfs = SquashFs.init(allocator, arg, offset) catch |err| {
            try stderr.print("{s}::{s} failed to open image: {!}\n", .{ red, reset, err });
            std.os.exit(1);
        };
    }

    var root_inode = try sqfs.getInode(sqfs.internal.sb.root_inode);
    var walker = try root_inode.walk(allocator);
    defer walker.deinit();

    // Iterate over the SquashFS image and print their paths to stdout
    while (try walker.next()) |entry| {
        try stdout.print("{s}\n", .{entry.path});
    }
}
