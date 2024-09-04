const std = @import("std");
const posix = std.posix;

const squashfuse = @import("../root.zig");
const metadata = squashfuse.metadata;
const SquashFs = squashfuse.SquashFs;

const assert = std.debug.assert;

const File = @This();

pub const Kind = std.fs.File.Kind;

inode: SquashFs.Inode,
block_list: BlockListIterator,
pos: u64,

// Previously discovered block offsets for fast seeking
cache: std.ArrayList(CacheEntry),

const CacheEntry = struct {
    block_offset: u64,
    entry: SquashFs.Block.DataEntry,
};

pub fn close(file: *File) void {
    file.cache.deinit();
}

pub fn initFromInode(inode: SquashFs.Inode) File {
    const cache = std.ArrayList(CacheEntry).init(inode.parent.allocator);

    var file = File{
        .inode = inode,
        .pos = 0,
        .cache = cache,
        .block_list = undefined,
    };

    file.block_list = BlockListIterator.init(&file.inode);

    return file;
}

pub const GetSeekPosError = posix.SeekError || posix.FStatError;
pub const SeekError = posix.SeekError || error{InvalidSeek};

// If the index is already cached, get it. Otherwise, read the blocklist
// and cache every entry until the target index is found
fn getBlocklistCache(file: *File, idx: usize) ?CacheEntry {
    if (idx == file.block_list.count) {
        return null;
    }

    while (file.block_list.idx <= idx) {
        const entry = file.block_list.next() catch unreachable;
        if (entry == null) return null;

        // TODO
        file.cache.append(.{
            .block_offset = file.block_list.block_offset,
            .entry = entry.?,
        }) catch unreachable;
    }

    return file.cache.items[idx];
}

pub const SeekableStream = std.io.SeekableStream(
    File,
    SeekError,
    GetSeekPosError,
    seekTo,
    seekBy,
    getPos,
    getEndPos,
);

pub fn seekableStream(file: File) SeekableStream {
    return .{ .context = file };
}

// TODO: handle invalid seeks
pub fn seekTo(self: *File, pos: u64) SeekError!void {
    const end = self.getEndPos() catch unreachable;

    if (pos > end) {
        return SeekError.InvalidSeek;
    }

    self.pos = pos;
}

pub fn seekBy(file: *File, pos: i64) SeekError!void {
    const end = file.getEndPos() catch return SeekError.Unseekable;

    if (file.pos + pos > end) {
        return SeekError.InvalidSeek;
    }

    file.pos += pos;
}

pub fn seekFromEnd(file: *File, pos: i64) SeekError!void {
    const end = file.getEndPos() catch return SeekError.Unseekable;
    file.pos = end - pos;
}

pub fn getPos(file: File) GetSeekPosError!u64 {
    return file.pos;
}

pub fn getEndPos(self: File) GetSeekPosError!u64 {
    return self.inode.xtra.reg.size;
}

pub const Reader = std.io.Reader(*File, ReadError, read);
pub fn reader(self: *File) Reader {
    return .{ .context = self };
}

pub const ReadError = std.fs.File.ReadError;
pub fn read(file: *File, buf: []u8) ReadError!usize {
    const block = file.preadNoCopy(file.pos) catch unreachable;

    const take = @min(
        block.len,
        buf.len,
    );

    @memcpy(
        buf[0..take],
        block[0..take],
    );

    file.pos += take;

    return take;
}

/// Peeks into cached memory instead of copying into a buffer
/// Due to not needing another copy, this is ever so slightly faster than using
/// `pread`
pub fn preadNoCopy(
    file: *File,
    offset: u64,
) PReadError![]const u8 {
    var sqfs = file.inode.parent;

    const file_size = try file.getEndPos();
    const block_size = sqfs.super_block.block_size;

    if (offset == file_size) return &.{};
    if (offset > file_size) return error.InvalidSeek;

    const block = offset / block_size;

    const read_off: usize = @intCast(offset % block_size);

    const maybe_entry = file.getBlocklistCache(block);
    if (maybe_entry) |entry| {
        if (entry.entry.size == 0) {
            const size = @min(
                file_size - (block * block_size),
                block_size,
            );

            return sqfs.zero_block[0..size];
        } else {
            const block_data = sqfs.dataCache(
                &sqfs.data_cache,
                entry.block_offset - entry.entry.size,
                entry.entry,
            ) catch return error.SystemResources;

            return block_data[read_off..];
        }
    }

    // End of file, possible fragment block
    if (file.inode.xtra.reg.frag_idx == SquashFs.invalid_frag) return &.{};

    const block_data = file.fragBlock() catch return error.SystemResources;

    return block_data[read_off..];
}

pub fn fragBlock(
    file: *File,
) ![]u8 {
    var sqfs = file.inode.parent;

    if (file.inode.xtra.reg.frag_idx == SquashFs.invalid_frag) return error.Error;

    const frag = try sqfs.frag_table.get(
        file.inode.xtra.reg.frag_idx,
    );

    const block_data = try sqfs.dataCache(
        &sqfs.frag_cache,
        frag.start_block,
        frag.block_header,
    );

    const offset = file.inode.xtra.reg.frag_off;
    const size = file.inode.xtra.reg.size % sqfs.super_block.block_size;

    return block_data[offset..][0..size];
}

pub const PReadError = ReadError || SeekError;
pub fn pread(
    file: *File,
    buf: []u8,
    offset: u64,
) PReadError!usize {
    const block = try file.preadNoCopy(offset);

    const take = @min(
        block.len,
        buf.len,
    );

    @memcpy(
        buf[0..take],
        block[0..take],
    );

    return take;
}

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

pub const BlockListIterator = extern struct {
    inode: *SquashFs.Inode,
    idx: usize,
    count: usize,
    cur: metadata.Cursor,

    // Compressed offset of where the current block starts
    block_offset: u64,
    input_size: u32,

    pub fn init(inode: *SquashFs.Inode) BlockListIterator {
        return .{
            .inode = inode,
            .count = BlockListIterator.getTotalBlockCount(inode),
            .idx = 0,
            .cur = inode.next,
            .block_offset = inode.xtra.reg.start_block,
            .input_size = 0,
        };
    }

    fn getTotalBlockCount(inode: *SquashFs.Inode) usize {
        const size = inode.xtra.reg.size;
        const block = inode.parent.super_block.block_size;

        if (inode.xtra.reg.frag_idx == SquashFs.invalid_frag) {
            return @intCast(std.math.divCeil(u64, size, block) catch unreachable);
        }

        return @intCast(size / block);
    }

    pub fn next(block_list: *BlockListIterator) !?SquashFs.Block.DataEntry {
        if (block_list.idx == block_list.count) return null;

        block_list.idx += 1;

        var entry: SquashFs.Block.DataEntry = undefined;
        try block_list.cur.load(&entry);
        entry = squashfuse.littleToNative(entry);

        block_list.block_offset += entry.size;

        return entry;
    }
};
