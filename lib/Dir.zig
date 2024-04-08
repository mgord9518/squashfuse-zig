const std = @import("std");
const os = std.os;
const squashfuse = @import("squashfuse.zig");
const SquashFs = squashfuse.SquashFs;
const assert = std.debug.assert;

pub const Dir = @This();

cur: SquashFs.MdCursor,
offset: u64,
total: u64,
header: Header,

pub const Entry = extern struct {
    inode: u64,
    inode_number: u32,
    kind: c_int,
    name: [*]u8,
    name_len: usize,
    offset: u64,
    next_offset: u64,
};

const InternalEntry = packed struct {
    offset: u16,
    inode_number: u16,
    kind: u16,
    size: u16,
};

pub const Header = extern struct {
    count: u32,
    start_block: u32,
    inode_number: u32,
};

pub fn open(sqfs: *SquashFs, inode: *SquashFs.Inode) !Dir {
    if (inode.kind != .directory) return error.NotDir;

    var dir = std.mem.zeroes(Dir);

    dir.cur.block = @intCast(inode.internal.xtra.dir.start_block + sqfs.super_block.directory_table_start);
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
    var e: InternalEntry = undefined;

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

    entry.kind = e.kind;
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

    try squashfuse.mdRead(allocator, sqfs, &dir.cur, buf);
}
