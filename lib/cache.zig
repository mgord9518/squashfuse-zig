const std = @import("std");
const io = std.io;
const os = std.os;
const fs = std.fs;
const xz = std.compress.xz;
const zstd = std.compress.zstd;
const squashfuse = @import("SquashFs.zig");
const SquashFs = squashfuse.SquashFs;

pub const build_options = @import("build_options");

const table = @import("table.zig");

const c = @cImport({
    @cInclude("squashfuse.h");
    @cInclude("common.h");

    @cInclude("swap.h");
    @cInclude("string.h");
    @cInclude("cache.h");
});

const EntryHeader = extern struct {
    valid: bool,
    idx: c.sqfs_cache_idx,
};

fn cacheEntryValid(e: *c.sqfs_block_cache_entry) bool {
    var hdr: [*]EntryHeader = @ptrCast(@alignCast(e));
    hdr -= 1;

    return hdr[0].valid;
}

fn cacheEntryMarkValid(e: *anyopaque) void {
    const h: [*]EntryHeader = @ptrCast(@alignCast(e));
    var header = (h - 1)[0];

    // TODO: error handling
    if (header.valid != false) unreachable;

    header.valid = true;
}

pub fn mdCache(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    pos: *usize,
    block: **c.sqfs_block,
) !void {
    // TODO
    const use_zig_impl = false;

    var entry: *c.sqfs_block_cache_entry = undefined;

    if (use_zig_impl) {
        entry = @ptrCast(@alignCast(getCache(
            allocator,
            &sqfs.internal.md_cache,
            @intCast(pos.*),
        )));
    } else {
        entry = @ptrCast(@alignCast(c.sqfs_cache_get(
            &sqfs.internal.md_cache,
            @intCast(pos.*),
        )));
    }

    if (use_zig_impl) {
        if (!cacheEntryValid(entry)) {
            //        var err: c.sqfs_err = 0;

            //err = c.sqfs_md_block_read(
            try squashfuse.mdBlockRead(
                allocator,
                sqfs,
                pos.*,
                &entry.data_size,
                @ptrCast(&entry.block),
            );

            //        if (err != 0) {
            //            return SquashFsErrorFromInt(err);
            //        }

            cacheEntryMarkValid(entry);
        }
    } else {
        if (c.sqfs_cache_entry_valid(&sqfs.internal.md_cache, entry) == 0) {
            //        var err: c.sqfs_err = 0;

            //err = c.sqfs_md_block_read(
            try squashfuse.mdBlockRead(
                allocator,
                sqfs,
                pos.*,
                &entry.data_size,
                @ptrCast(&entry.block),
            );

            //        if (err != 0) {
            //            return SquashFsErrorFromInt(err);
            //        }

            c.sqfs_cache_entry_mark_valid(&sqfs.internal.md_cache, entry);
        }
    }

    block.* = entry.block;
    pos.* += @intCast(entry.data_size);

    //c.sqfs_cache_put(&sqfs.internal.md_cache, entry);
}

fn cacheEntryHeader(
    cache: *Internal,
    i: usize,
) *EntryHeader {
    const ch: *EntryHeader = @ptrCast(@alignCast(cache.buf + i * cache.size));
    std.debug.print("cacheEntryHeader: {}\n", .{ch});
    return ch;
}

fn cacheEntry(
    cache: *Internal,
    i: usize,
) ?*anyopaque {
    std.debug.print("call cacheEntryHeader from cacheEntry\n", .{});
    return @ptrFromInt(
        @intFromPtr(cacheEntryHeader(cache, i)) + @sizeOf(EntryHeader),
    );
}

fn getCache(
    allocator: std.mem.Allocator,
    cache: *c.sqfs_cache,
    idx: c.sqfs_cache_idx,
) ?*anyopaque {
    _ = allocator;

    var i: usize = 0;
    var ch: *Internal = @ptrCast(@alignCast(cache.*));
    var hdr: *EntryHeader = undefined;

    while (i < ch.count) : (i += 1) {
        std.debug.print("call cacheEntryHeader from getCache@147\n", .{});
        hdr = cacheEntryHeader(ch, i);
        if (hdr.idx == idx) {
            if (hdr.valid != true) {
                @panic("assert failed! header not valid");
            }
            return cacheEntry(ch, i);
        }
    }

    i = ch.next;
    ch.next += 1;

    //ch = @ptrFromInt(@intFromPtr(ch) + @sizeOf(sqfs_cache_internal));

    ch.next %= ch.count;

    std.debug.print("call cacheEntryHeader from getCache@165\n", .{});
    hdr = cacheEntryHeader(ch, i);
    if (hdr.valid) {
        //ch.dispose.?(@ptrFromInt(@intFromPtr(hdr) + @sizeOf(EntryHeader)));
        //  hdr.valid = false;
    }

    hdr.idx = idx;
    return @ptrFromInt(@intFromPtr(hdr) + @sizeOf(EntryHeader));
}

pub fn initBlockCache(
    allocator: std.mem.Allocator,
    cache: *c.sqfs_cache,
    count: usize,
) !void {
    try initCache(
        allocator,
        cache,
        @sizeOf(c.sqfs_block_cache_entry),
        count,
        //@ptrFromInt(0x69),
        @ptrCast(&noop),
    );
}

pub fn initBlockIdx(allocator: std.mem.Allocator, cache: *c.sqfs_cache) !void {
    try initCache(
        allocator,
        cache,
        @sizeOf(**c.sqfs_blockidx_entry),
        SquashFs.meta_slots,
        @ptrCast(&noop),
    );
}

fn noop() void {}

const Internal = extern struct {
    buf: [*]u8,

    dispose: c.sqfs_cache_dispose,

    size: usize,
    count: usize,
    next: usize,
};

pub fn initCache(
    allocator: std.mem.Allocator,
    cache: *c.sqfs_cache,
    size: usize,
    count: usize,
    dispose: c.sqfs_cache_dispose,
) !void {
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

    cache.* = @ptrCast(temp);
}
