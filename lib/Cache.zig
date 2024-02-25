pub const Cache = @This();

const std = @import("std");
const squashfuse = @import("squashfuse.zig");
const SquashFs = squashfuse.SquashFs;
const assert = std.debug.assert;

buf: [*]u8,

dispose: Dispose,

size: usize,
count: usize,
next: usize,

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
