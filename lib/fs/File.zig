const std = @import("std");

const squashfuse = @import("../root.zig");
const metadata = squashfuse.metadata;
const SquashFs = squashfuse.SquashFs;

const File = @This();

pub const Kind = std.fs.File.Kind;

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

    _,

    pub fn toKind(kind: InternalKind) Kind {
        return switch (kind) {
            .directory, .l_directory => .directory,
            .file, .l_file => .file,
            .sym_link, .l_sym_link => .sym_link,
            .block_device, .l_block_device => .block_device,
            .character_device, .l_character_device => .character_device,
            .named_pipe, .l_named_pipe => .named_pipe,
            .unix_domain_socket, .l_unix_domain_socket => .unix_domain_socket,

            else => .unknown,
        };
    }
};

pub const BlockList = extern struct {
    sqfs: *SquashFs,
    remain: usize,
    cur: metadata.Cursor,
    started: bool,

    pos: u64,

    block: u64,
    input_size: u32,

    pub fn init(sqfs: *SquashFs, inode: *SquashFs.Inode) !BlockList {
        return .{
            .sqfs = sqfs,
            .remain = BlockList.count(sqfs, inode),
            .cur = inode.next,
            .started = false,
            .pos = 0,
            .block = inode.xtra.reg.start_block,
            .input_size = 0,
        };
    }

    pub fn count(sqfs: *SquashFs, inode: *SquashFs.Inode) usize {
        const size = inode.xtra.reg.size;
        const block = sqfs.super_block.block_size;

        if (inode.xtra.reg.frag_idx == SquashFs.invalid_frag) {
            return @intCast(std.math.divCeil(u64, size, block) catch unreachable);
        }

        return @intCast(size / block);
    }

    pub fn next(block_list: *BlockList) !?SquashFs.Block.DataEntry {
        if (block_list.remain == 0) return null;

        block_list.remain -= 1;

        var entry: SquashFs.Block.DataEntry = undefined;
        try block_list.cur.load(
            &entry,
        );

        entry = squashfuse.littleToNative(entry);

        block_list.block += entry.size;

        if (block_list.started) {
            block_list.pos += block_list.sqfs.super_block.block_size;
        }

        block_list.started = true;

        return entry;
    }

    // TODO
    pub fn previous(block_list: *BlockList) !?SquashFs.Block.DataEntry {
        if (block_list.pos == 0 and block_list.started) return null;

        block_list.remain += 1;

        var entry: SquashFs.Block.DataEntry = undefined;
        try block_list.cur.load(
            &entry,
        );

        entry = squashfuse.littleToNative(entry);
    }
};
