pub const Cache = @This();

const std = @import("std");
const squashfuse = @import("squashfuse.zig");
const SquashFs = squashfuse.SquashFs;
const Inode = SquashFs.Inode;
const assert = std.debug.assert;

buf: [*]u8,

dispose: Dispose,

size: usize,
count: usize,
next: usize,

//const c = @cImport({
//    @cInclude("squashfuse.h");
//});

pub fn init(
    allocator: std.mem.Allocator,
    size: usize,
    count: usize,
    dispose: Dispose,
) !*Cache {
    const cache = try allocator.create(Cache);

    cache.* = .{
        .size = size + @sizeOf(BlockCacheEntry.Header),
        .count = count,
        .dispose = dispose,
        .next = 0,
        .buf = undefined,
    };

    const buf = try allocator.alloc(u8, count * cache.size);
    @memset(buf, 0);

    cache.buf = buf.ptr;

    return cache;
}

pub fn header(cache: *Cache, i: usize) *BlockCacheEntry.Header {
    return @ptrCast(@alignCast(cache.buf + i * cache.size));
}

pub fn entry(cache: *Cache, i: usize) ?*anyopaque {
    return @ptrFromInt(
        @intFromPtr(cache.header(i)) + @sizeOf(BlockCacheEntry.Header),
    );
}

pub const Dispose = *const fn (data: ?*anyopaque) callconv(.C) void;

// sqfs_block
pub const Block = extern struct {
    size: usize,
    data: [*]u8,
    refcount: c_long,
    //allocator: std.mem.Allocator,

    //    export fn dispose(block: *Block) void {
    //        if (c.sqfs_block_deref(@ptrCast(block))) {
    //            std.
    //        }
    //    }

};

pub const BlockCacheEntry = extern struct {
    block: *Block,
    data_size: usize,

    pub const Header = extern struct {
        valid: bool,
        idx: u64,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        count: usize,
    ) !*Cache {
        return try Cache.init(
            allocator,
            @sizeOf(BlockCacheEntry),
            count,
            @ptrCast(&noop),
        );
    }

    pub fn header(e: *BlockCacheEntry) *Header {
        var hdr: [*]Header = @ptrCast(@alignCast(e));
        hdr -= 1;

        return @ptrCast(hdr);
    }

    pub fn isValid(e: *BlockCacheEntry) bool {
        return e.header().valid;
    }

    pub fn markValid(e: *BlockCacheEntry) void {
        var hdr = e.header();

        if (hdr.valid) unreachable;

        hdr.valid = true;
    }
};

// sqfs_cache_get
pub fn getCache(
    allocator: std.mem.Allocator,
    ch: *Cache,
    idx: u64,
) *BlockCacheEntry {
    _ = allocator;

    var i: usize = 0;

    while (i < ch.count) : (i += 1) {
        const hdr = ch.header(i);

        if (hdr.idx == idx) {
            assert(hdr.valid);

            return @ptrCast(@alignCast(ch.entry(i)));
        }
    }

    i = ch.next;
    ch.next += 1;

    ch.next %= ch.count;

    var hdr = ch.header(i);
    if (hdr.valid) {
        ch.dispose(@ptrFromInt(@intFromPtr(hdr) + @sizeOf(BlockCacheEntry.Header)));
        hdr.valid = false;
    }

    hdr.idx = idx;
    return @ptrFromInt(@intFromPtr(hdr) + @sizeOf(BlockCacheEntry.Header));
}

pub const BlockIdx = struct {
    pub fn init(allocator: std.mem.Allocator) !*Cache {
        return try Cache.init(
            allocator,
            @sizeOf(**BlockIdx.Entry),
            SquashFs.meta_slots,
            &dispose,
            //  @ptrCast(&noop),
        );
    }

    pub const Entry = extern struct {
        data_block: u64,
        md_block: u32,
    };

    export fn dispose(data: ?*anyopaque) callconv(.C) void {
        const e: *BlockCacheEntry = @ptrCast(@alignCast(data.?));
        //c.sqfs_block_dispose(@ptrCast(entry.block));
        _ = e;
    }

    pub fn indexable(sqfs: *SquashFs, inode: *Inode) bool {
        const blocks = SquashFs.File.BlockList.count(sqfs, inode);
        const md_size = blocks * @sizeOf(u32);
        return md_size >= SquashFs.metadata_size;
    }

    fn blockidx_add(sqfs: *SquashFs, inode: *Inode, out: [*c][*c]BlockIdx.Entry, cachep: **BlockIdx.Entry) !void {
        var blocks: usize = undefined;
        var md_size: usize = undefined;
        var count: usize = undefined;

        var blockidx: [*c]BlockIdx.Entry = undefined;
        var bl: SquashFs.File.BlockList = undefined;

        var i: usize = 0;
        var first = true;

        out.* = null;

        //        blocks = c.sqfs_blocklist_count(
        //            &sqfs.internal,
        //            @ptrCast(&inode.internal),
        //        );

        blocks = SquashFs.File.BlockList.count(sqfs, inode);
        md_size = blocks * @sizeOf(BlockIdx.Entry);
        count = (inode.internal.next.offset + md_size - 1 / SquashFs.metadata_size);

        blockidx = @ptrCast((sqfs.allocator.alloc(BlockIdx.Entry, count) catch unreachable).ptr);

        //c.sqfs_blocklist_init(&sqfs.internal, @ptrCast(&inode.internal), &bl);
        bl = try SquashFs.File.BlockList.init(sqfs, inode);
        while (bl.remain > 0 and i < count) {
            if (bl.cur.offset < @sizeOf(BlockIdx.Entry) and !first) {
                blockidx[i].data_block = bl.block + bl.input_size;
                blockidx[i].md_block = @intCast(@as(u64, @intCast(bl.cur.block)) - sqfs.super_block.inode_table_start);
                i += 1;
            }
            first = false;

            try bl.next(sqfs.allocator);
            errdefer {
                sqfs.allocator.free(blockidx[0..count]);
                unreachable;
            }
        }

        out.* = blockidx;
        cachep.* = blockidx;
    }

    // TODO
    pub fn blockList(
        sqfs: *SquashFs,
        inode: *SquashFs.Inode,
        bl: *SquashFs.File.BlockList,
        start: u64,
        //) !SquashFs.BlockList {
    ) !void {
        var metablock: usize = 0;
        var skipped: usize = 0;

        var bp: **BlockIdx.Entry = undefined;
        var blockidx: [*c]BlockIdx.Entry = undefined;

        var idx: u64 = 0;

        bl.* = try SquashFs.File.BlockList.init(sqfs, inode);

        var block: usize = start / sqfs.super_block.block_size;

        block = start / sqfs.super_block.block_size;
        if (block > bl.remain) {
            bl.remain = 0;
            return;
        }

        metablock = (bl.cur.offset + block * 4) / SquashFs.metadata_size;

        if (metablock == 0) return;

        if (!BlockIdx.indexable(
            sqfs,
            inode,
        )) return;

        idx = inode.internal.base.inode_number + 1;

        bp = @ptrCast(getCache(sqfs.allocator, @ptrCast(@alignCast(sqfs.internal.blockidx)), idx));
        //if (c.sqfs_cache_entry_valid(&sqfs.internal.blockidx, @ptrCast(bp)) != 0) {
        if (@as(*BlockCacheEntry, @ptrCast(bp)).isValid()) {
            blockidx = bp.*;
        } else {
            try blockidx_add(
                sqfs,
                inode,
                @ptrCast(&blockidx),
                @ptrCast(bp),
            );
            @as(*BlockCacheEntry, @ptrCast(bp)).markValid();
        }

        skipped = (metablock * SquashFs.metadata_size / 4 - bl.cur.offset / 4);

        blockidx += metablock - 1;

        bl.cur.block = @intCast(blockidx[0].md_block + sqfs.super_block.inode_table_start);
        bl.cur.offset %= 4;
        bl.remain -= skipped;
        bl.pos = skipped * sqfs.super_block.block_size;
        bl.block = blockidx[0].data_block;
    }
};

fn noop() void {}
