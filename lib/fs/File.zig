const std = @import("std");

const squashfuse = @import("../root.zig");
const SquashFs = squashfuse.SquashFs;

const File = @This();

pub const Kind = enum(u3) {
    directory = 1,
    file = 2,
    sym_link = 3,
    block_device = 4,
    character_device = 5,
    named_pipe = 6,
    unix_domain_socket = 7,
};

pub const InternalKind = enum(u4) {
    directory = 1,
    file = 2,
    sym_link = 3,
    block_device = 4,
    character_device = 5,
    named_pipe = 6,
    unix_domain_socket = 7,

    // `long` versions of the types, which contain additional info
    l_directory = 8,
    l_file = 9,
    l_sym_link = 10,
    l_block_device = 11,
    l_character_device = 12,
    l_named_pipe = 13,
    l_unix_domain_socket = 14,

    pub fn fromInt(int: u16) InternalKind {
        return @enumFromInt(int);
    }

    pub fn toKind(kind: InternalKind) Kind {
        const kind_int = @intFromEnum(kind);

        return if (kind_int <= 7) blk: {
            break :blk @enumFromInt(kind_int);
        } else blk: {
            break :blk @enumFromInt(kind_int - 7);
        };
    }
};

pub const BlockList = extern struct {
    sqfs: *SquashFs,
    remain: usize,
    cur: SquashFs.MetadataCursor,
    started: bool,

    pos: u64,

    block: u64,
    header: SquashFs.Block.DataEntry,
    input_size: u32,

    pub fn init(sqfs: *SquashFs, inode: *SquashFs.Inode) !BlockList {
        return .{
            .sqfs = sqfs,
            .remain = BlockList.count(sqfs, inode),
            .cur = inode.internal.next,
            .started = false,
            .pos = 0,
            .header = .{ .is_uncompressed = false, .size = 0 },
            .block = inode.internal.xtra.reg.start_block,
            .input_size = 0,
        };
    }

    pub fn count(sqfs: *SquashFs, inode: *SquashFs.Inode) usize {
        const size = inode.internal.xtra.reg.size;
        const block = sqfs.super_block.block_size;

        if (inode.internal.xtra.reg.frag_idx == SquashFs.invalid_frag) {
            return @intCast(std.math.divCeil(u64, size, block) catch unreachable);
        }

        return @intCast(size / block);
    }

    pub fn next(bl: *BlockList) !void {
        if (bl.remain == 0) {
            // TODO: better errors
            return error.NoRemain;
        }

        bl.remain -= 1;

        try bl.cur.load(
            &bl.header,
        );

        bl.header = squashfuse.littleToNative(bl.header);

        bl.block += bl.input_size;

        bl.input_size = bl.header.size;

        if (bl.started) {
            bl.pos += bl.sqfs.super_block.block_size;
        }

        bl.started = true;
    }
};
