const std = @import("std");
const squashfuse = @import("squashfuse.zig");
const SquashFs = squashfuse.SquashFs;
const assert = std.debug.assert;

pub const Cache = @This();

const c = @cImport({
    @cInclude("squashfuse.h");
});

const Internal = extern struct {
    buf: [*]u8,

    dispose: c.sqfs_cache_dispose,

    size: usize,
    count: usize,
    next: usize,

    fn header(cache: *Internal, i: usize) *BlockCacheEntry.Header {
        return @ptrCast(@alignCast(cache.buf + i * cache.size));
    }

    fn entry(cache: *Internal, i: usize) ?*anyopaque {
        return @ptrFromInt(
            @intFromPtr(cache.header(i)) + @sizeOf(BlockCacheEntry.Header),
        );
    }
};

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
        idx: c.sqfs_cache_idx,

        pub fn isValid(entry: *anyopaque) bool {
            var header: [*]Header = @ptrCast(@alignCast(entry));
            header -= 1;

            return header[0].valid;
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        count: usize,
    ) !*Internal {
        return try Cache.init(
            allocator,
            @sizeOf(BlockCacheEntry),
            count,
            @ptrCast(&noop),
        );
    }

    pub fn isValid(entry: *BlockCacheEntry) bool {
        var hdr: [*]Header = @ptrCast(@alignCast(entry));
        hdr -= 1;

        return hdr[0].valid;
    }

    pub fn markValid(entry: *BlockCacheEntry) void {
        var hdr: [*]Header = @ptrCast(entry);
        hdr -= 1;

        if (hdr[0].valid) unreachable;

        hdr[0].valid = true;
    }
};

// sqfs_cache_get
pub fn getCache(
    allocator: std.mem.Allocator,
    cache: **Internal,
    idx: c.sqfs_cache_idx,
) *BlockCacheEntry {
    _ = allocator;

    var i: usize = 0;
    var ch: *Internal = @ptrCast(@alignCast(cache.*));

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
        ch.dispose.?(@ptrFromInt(@intFromPtr(hdr) + @sizeOf(BlockCacheEntry.Header)));
        hdr.valid = false;
    }

    hdr.idx = idx;
    return @ptrFromInt(@intFromPtr(hdr) + @sizeOf(BlockCacheEntry.Header));
}

pub const BlockIdx = struct {
    pub fn init(allocator: std.mem.Allocator) !*Internal {
        return try Cache.init(
            allocator,
            @sizeOf(**c.sqfs_blockidx_entry),
            SquashFs.meta_slots,
            &dispose,
            //  @ptrCast(&noop),
        );
    }

    export fn dispose(data: ?*anyopaque) void {
        const entry: *BlockCacheEntry = @ptrCast(@alignCast(data.?));
        //c.sqfs_block_dispose(@ptrCast(entry.block));
        _ = entry;
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

pub fn init(
    allocator: std.mem.Allocator,
    size: usize,
    count: usize,
    dispose: c.sqfs_cache_dispose,
) !*Internal {
    const temp = try allocator.create(Internal);

    temp.* = .{
        .size = size + @sizeOf(BlockCacheEntry.Header),
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
