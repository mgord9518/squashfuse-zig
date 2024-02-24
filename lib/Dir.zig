const std = @import("std");
const os = std.os;
const squashfuse = @import("squashfuse.zig");
const SquashFs = squashfuse.SquashFs;
const assert = std.debug.assert;

pub const Dir = @This();

const c = @cImport({
    @cInclude("squashfuse.h");
    @cInclude("dir.h");
});

cur: SquashFs.MdCursor,
offset: c.sqfs_off_t,
total: c.sqfs_off_t,
header: Header,

pub const Entry = extern struct {
    inode: c.sqfs_inode_id,
    inode_number: c.sqfs_inode_num,
    kind: c_int,
    name: [*]u8,
    name_len: usize,
    offset: c.sqfs_off_t,
    next_offset: c.sqfs_off_t,
};

pub const Header = extern struct {
    count: u32,
    start_block: u32,
    inode_number: u32,
};

pub fn open(sqfs: *SquashFs, inode: *SquashFs.Inode) !Dir {
    if (inode.kind != .directory) return error.NotDir;

    var dir = std.mem.zeroes(Dir);

    dir.cur.block = @intCast(inode.internal.xtra.dir.start_block + sqfs.internal.sb.directory_table_start);
    dir.cur.offset = inode.internal.xtra.dir.offset;
    dir.offset = 0;
    dir.total = @intCast(inode.internal.xtra.dir.dir_size -| 3);

    return dir;
}

pub fn dirNext(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    dir: *SquashFs.Dir,
    entry: *SquashFs.Dir.Entry,
) !bool {
    var e: c.squashfs_dir_entry = undefined;

    entry.offset = dir.offset;

    while (dir.header.count == 0) {
        if (dir.offset >= dir.total) {
            return false;
        }

        const header_slice: []u8 = @as([*]u8, @ptrCast(&dir.header))[0..@sizeOf(@TypeOf(dir.header))];
        try dirMdRead(allocator, sqfs, dir, header_slice);

        dir.header = squashfuse.littleToNative(dir.header);
        dir.header.count += 1;
    }

    const e_slice: []u8 = @as([*]u8, @ptrCast(&e))[0..@sizeOf(@TypeOf(e))];
    try dirMdRead(allocator, sqfs, dir, e_slice);

    e = squashfuse.littleToNative(e);

    dir.header.count -= 1;

    entry.kind = e.type;
    entry.name_len = e.size + 1;
    entry.inode = (@as(u64, @intCast(dir.header.start_block)) << 16) + e.offset;
    entry.inode_number = dir.header.inode_number + e.inode_number;

    const entry_slice: []u8 = @as([*]u8, @ptrCast(entry.name))[0..entry.name_len];

    try dirMdRead(allocator, sqfs, dir, entry_slice);

    return true;
}

fn dirMdRead(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    dir: *SquashFs.Dir,
    buf: []u8,
) !void {
    dir.offset += @intCast(buf.len);

    //try SquashFsErrorFromInt(c.sqfs_md_read(sqfs, &dir.cur, buf.ptr, buf.len));

    try squashfuse.mdRead(allocator, sqfs, &dir.cur, buf);
}
