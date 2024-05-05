const std = @import("std");
const squashfuse = @import("root.zig");
const SquashFs = squashfuse.SquashFs;
const Inode = SquashFs.Inode;
const assert = std.debug.assert;

pub fn Cache(T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,

        entries: []Entry,

        count: usize,
        next: usize,

        pub const Entry = struct {
            header: Header,
            entry: T,

            pub const Header = packed struct(u64) {
                idx: u63,
                valid: bool,
            };
        };

        pub fn init(
            allocator: std.mem.Allocator,
            count: usize,
        ) !Self {
            const cache = .{
                .allocator = allocator,
                .count = count,
                // .dispose = dispose,
                .next = 0,
                .entries = try allocator.alloc(
                    Entry,
                    count,
                ),
            };

            @memset(cache.entries, .{
                .entry = undefined,
                .header = .{
                    .idx = 0,
                    .valid = false,
                },
            });

            return cache;
        }

        pub fn deinit(cache: *Self) void {
            cache.allocator.free(cache.entries);
        }

        // TODO
        //        pub fn put(cache: *Self, idx, usize, item: T) void {
        //
        //            for (ch.entries) |*ent| {
        //                std.debug.print(
        //                    "idx {d}\n",
        //                    .{ent.header.idx},
        //                );
        //                if (ent.header.idx == idx) {
        //                    assert(ent.header.valid);
        //
        //                    return ent;
        //                }
        //            }
        //        }

        pub fn get(
            ch: *Self,
            idx: usize,
        ) *Entry {
            // Search cache for index, return if present
            for (ch.entries) |*ent| {
                if (ent.header.idx == idx) {
                    assert(ent.header.valid);

                    return ent;
                }
            }

            // Move to the next entry, invalidate it so it's ready for new
            // data
            const entry = &ch.entries[ch.next];
            if (entry.header.valid) {
                //   ch.dispose(@ptrFromInt(@intFromPtr(hdr) + @sizeOf(BlockCacheEntry.Header)));
                entry.header.valid = false;
            }

            entry.header.idx = @intCast(idx);

            ch.next += 1;
            ch.next %= ch.count;

            return entry;
        }
    };
}

pub const BlockIdx = struct {
    //const Self = Cache(**BlockIdx.Entry);
    //const Self = Cache(*BlockIdx.Entry);

    pub const Entry = extern struct {
        data_block: u64,
        md_block: u32,
    };

    pub fn indexable(sqfs: *SquashFs, inode: *Inode) bool {
        const blocks = SquashFs.File.BlockList.count(
            sqfs,
            inode,
        );

        const md_size = blocks * @sizeOf(u32);
        return md_size >= SquashFs.metadata_size;
    }

    // TODO: refactor
    fn blockidx_add(
        sqfs: *SquashFs,
        inode: *Inode,
        out: [*c][*c]BlockIdx.Entry,
        cachep: **BlockIdx.Entry,
    ) !void {
        var blocks: usize = undefined;
        var md_size: usize = undefined;
        var count: usize = undefined;

        var blockidx: [*c]BlockIdx.Entry = undefined;
        var bl: SquashFs.File.BlockList = undefined;

        var i: usize = 0;
        var first = true;

        out.* = null;

        blocks = SquashFs.File.BlockList.count(sqfs, inode);
        md_size = blocks * 4;
        count = (inode.internal.next.offset + md_size - 1) / SquashFs.metadata_size;

        blockidx = @ptrCast((sqfs.allocator.alloc(BlockIdx.Entry, count) catch unreachable).ptr);

        //c.sqfs_blocklist_init(&sqfs.internal, @ptrCast(&inode.internal), &bl);
        bl = try SquashFs.File.BlockList.init(sqfs, inode);

        while (bl.remain > 0 and i < count) {
            if (bl.cur.offset < 4 and !first) {
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

    // TODO: refactor
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

        var idx: usize = 0;

        bl.* = try SquashFs.File.BlockList.init(sqfs, inode);

        const block: usize = @intCast(start / sqfs.super_block.block_size);
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

        //bp = @ptrCast(getCache(sqfs.allocator, @ptrCast(@alignCast(sqfs.blockidx)), idx));
        bp = @ptrCast(sqfs.blockidx.get(idx));
        //if (c.sqfs_cache_entry_valid(&sqfs.internal.blockidx, @ptrCast(bp)) != 0) {
        if (sqfs.blockidx.entries[idx].header.valid) {
            blockidx = bp.*;
        } else {
            try blockidx_add(
                sqfs,
                inode,
                @ptrCast(&blockidx),
                @ptrCast(bp),
            );
            //@as(*BlockCacheEntry, @ptrCast(bp)).markValid();
            sqfs.blockidx.entries[idx].header.valid = true;
        }

        skipped = (metablock * SquashFs.metadata_size / 4) - (bl.cur.offset / 4);

        blockidx += metablock - 1;

        bl.cur.block = @intCast(blockidx[0].md_block + sqfs.super_block.inode_table_start);
        bl.cur.offset %= 4;
        bl.remain -= skipped;
        bl.pos = skipped * sqfs.super_block.block_size;
        bl.block = blockidx[0].data_block;
    }
};

fn noop() void {}
