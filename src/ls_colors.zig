const std = @import("std");
const fmt = std.fmt;

const squashfuse = @import("squashfuse");
const SquashFs = squashfuse.SquashFs;

const S = std.os.linux.S;

pub fn getEntryColor(entry: SquashFs.Inode.Walker.Entry, colors: []const u8, color_buf: []u8) ![]const u8 {
    //_ = env_map.get("LS_COLORS") orelse return reset;

    var inode = entry.inode();

    const st = try inode.statC();

    // Initially set the color based on the file type
    var color = getLsColorGnu(color_buf, colors, switch (inode.kind) {
        .file => "fi",
        .directory => "di",
        .sym_link => "ln",
        .named_pipe => "pi",
        .unix_domain_socket => "so",
        .block_device => "bd",
        .character_device => "cd",
    }) orelse reset;

    var name_buf: [4096]u8 = undefined;

    // Then override with the file extension
    // TODO: is this correct behavior?
    const glob = try std.fmt.bufPrint(
        &name_buf,
        "*{s}",
        .{getExtension(entry.path) orelse ""},
    );
    color = getLsColorGnu(color_buf, colors, glob) orelse color;

    if ((st.mode & S.IXUSR) | (st.mode & S.IXGRP) | (st.mode & S.IXOTH) != 0) {
        color = getLsColorGnu(color_buf, colors, "ex") orelse color;
    }

    if (st.mode & S.ISUID != 0) {
        color = getLsColorGnu(color_buf, colors, "su") orelse color;
    }

    if (st.mode & S.ISGID != 0) {
        color = getLsColorGnu(color_buf, colors, "sg") orelse color;
    }

    return color;
}

fn getExtension(file_name: []const u8) ?[]const u8 {
    var it = std.mem.splitBackwardsSequence(u8, file_name, ".");

    const chars = it.first();

    if (chars.len == file_name.len) return file_name;

    return file_name[file_name.len - chars.len - 1 ..];
}

// TODO: add BSD LSCOLOR support
pub fn getLsColorGnu(buf: []u8, ls_colors: []const u8, glob: []const u8) ?[]const u8 {
    // TODO: better NO_COLOR check
    if (reset.len == 0) return null;

    var it = std.mem.splitSequence(u8, ls_colors, ":");
    while (it.next()) |color| {
        if (color.len < 3) continue;
        const file_type = std.mem.sliceTo(color, '=');

        if (std.mem.eql(u8, file_type, glob)) {
            return std.fmt.bufPrint(
                buf,
                "\x1b[{s}m",
                .{color[file_type.len + 1 ..]},
            ) catch unreachable;
        }
    }

    return null;
}

var reset: []const u8 = "\x1b[0;0m";
