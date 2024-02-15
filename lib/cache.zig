const std = @import("std");
const squashfuse = @import("SquashFs.zig");
const SquashFs = squashfuse.SquashFs;
const assert = std.debug.assert;

pub const Cache = @This();

const c = @cImport({
    @cInclude("squashfuse.h");
});

pub const BlockCacheEntry = extern struct {
    block: *c.sqfs_block,
    data_size: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        count: usize,
    ) !c.sqfs_cache {
        return try Cache.init(
            allocator,
            @sizeOf(BlockCacheEntry),
            count,
            @ptrCast(&noop),
        );
    }

    fn isValid(entry: *BlockCacheEntry) bool {
        var hdr: [*]EntryHeader = @ptrCast(@alignCast(entry));
        hdr -= 1;

        return hdr[0].valid;
    }
};

const EntryHeader = extern struct {
    valid: bool,
    idx: c.sqfs_cache_idx,

    pub fn isValid(entry: *anyopaque) bool {
        var header: [*]EntryHeader = @ptrCast(@alignCast(entry));
        header -= 1;

        return header[0].valid;
    }
};

fn cacheEntryMarkValid(e: *anyopaque) void {
    var hdr: [*]EntryHeader = @ptrCast(@alignCast(e));
    hdr -= 1;

    if (hdr[0].valid) unreachable;

    hdr[0].valid = true;
}

pub fn mdCache(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    pos: *usize,
) !*c.sqfs_block {
    var entry: *BlockCacheEntry = undefined;

    entry = @ptrCast(@alignCast(getCache(
        allocator,
        @ptrCast(&sqfs.internal.md_cache),
        @intCast(pos.*),
    )));

    if (!entry.isValid()) {
        try squashfuse.mdBlockRead(
            allocator,
            sqfs,
            pos.*,
            &entry.data_size,
            @ptrCast(&entry.block),
        );

        cacheEntryMarkValid(entry);
    }

    pos.* += @intCast(entry.data_size);
    return entry.block;
}

fn getCache(
    allocator: std.mem.Allocator,
    cache: *c.sqfs_cache,
    idx: c.sqfs_cache_idx,
) ?*anyopaque {
    _ = allocator;

    var i: usize = 0;
    var ch: *Internal = @ptrCast(@alignCast(cache.*));

    while (i < ch.count) : (i += 1) {
        const hdr = ch.header(i);

        if (hdr.idx == idx) {
            assert(hdr.valid);

            return ch.entry(i);
        }
    }

    i = ch.next;
    ch.next += 1;

    ch.next %= ch.count;

    var hdr = ch.header(i);
    if (hdr.valid) {
        ch.dispose.?(@ptrFromInt(@intFromPtr(hdr) + @sizeOf(EntryHeader)));
        hdr.valid = false;
    }

    hdr.idx = idx;
    return @ptrFromInt(@intFromPtr(hdr) + @sizeOf(EntryHeader));
}

pub const BlockIdx = struct {
    pub fn init(allocator: std.mem.Allocator) !c.sqfs_cache {
        return try Cache.init(
            allocator,
            @sizeOf(**c.sqfs_blockidx_entry),
            SquashFs.meta_slots,
            @ptrCast(&noop),
        );
    }

    // TODO
    //    blockList(sqfs: *SquashFs, inode: *Inode, bl: *c.sqfs_blocklist, start: c.sqfs_off_t,) !void {
    //        var block: usize = 0;
    //        var metablock: usize = 0;
    //        var skipped: usize = 0;
    //
    //        bp: **c.sqfs_blockidx_entry = undefined;
    //        blockidx: *c.sqfs_blockidx_entry = undefined;
    //
    //        idx: c.sqfs_cache_idx;
    //
    //        c.sqfs_blocklist_init(&sqfs.internal, &inode.internal, bl);
    //        block = start / sqfs.internal.sb.block_size;
    //        if (block > bl.remain) {
    //            bl.remain = 0;
    //            return;
    //        }
    //
    //        metablock = (bl.cur.offset + block * @sizeOf(c.sqfs_blocklist_entry)) / SquashFs.metadata_size;
    //
    //        if (metablock == 0) return;
    //    }
};

fn noop() void {}

const Internal = extern struct {
    buf: [*]u8,

    dispose: c.sqfs_cache_dispose,

    size: usize,
    count: usize,
    next: usize,

    fn header(cache: *Internal, i: usize) *EntryHeader {
        const ch: *EntryHeader = @ptrCast(@alignCast(cache.buf + i * cache.size));
        return ch;
    }

    fn entry(cache: *Internal, i: usize) ?*anyopaque {
        return @ptrFromInt(
            @intFromPtr(cache.header(i)) + @sizeOf(EntryHeader),
        );
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    size: usize,
    count: usize,
    dispose: c.sqfs_cache_dispose,
) !c.sqfs_cache {
    const temp = try allocator.create(Internal);

    temp.* = .{
        .size = size + @sizeOf(EntryHeader),
        .count = count,
        .dispose = dispose,
        .next = 0,
        .buf = undefined,
    };

    const buf = try allocator.alloc(u8, count * temp.size);
    @memset(buf, 0);
    temp.buf = buf.ptr;

    return @ptrCast(temp);
}
