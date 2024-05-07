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
            // TODO: why does this segfault?
            //            for (cache.entries) |*entry| {
            //                if (!entry.header.valid) continue;
            //
            //                if (@typeInfo(T) == .Struct and @hasDecl(T, "deinit")) {
            //                    entry.entry.deinit();
            //                }
            //            }
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
            idx: u64,
        ) *Entry {
            // Search cache for index, return if present
            for (ch.entries) |*ent| {
                if (ent.header.idx == idx) {
                    assert(ent.header.valid);

                    return ent;
                }
            }

            // Move to the next entry, free and invalidate what was there
            // so we can put something else there
            const entry = &ch.entries[ch.next];
            if (entry.header.valid) {
                if (@typeInfo(T) == .Struct and @hasDecl(T, "deinit")) {
                    entry.entry.deinit();
                }

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
    fn addBlockIdx(
        sqfs: *SquashFs,
        inode: *Inode,
        cachep: **BlockIdx.Entry,
    ) ![]BlockIdx.Entry {
        var first = true;

        const blocks = SquashFs.File.BlockList.count(sqfs, inode);
        const md_size = blocks * 4;
        const count = (inode.internal.next.offset + md_size - 1) / SquashFs.metadata_size;

        //blockidx = @ptrCast((sqfs.allocator.alloc(BlockIdx.Entry, count) catch unreachable).ptr);
        var blockidx = sqfs.allocator.alloc(BlockIdx.Entry, count) catch unreachable;

        //c.sqfs_blocklist_init(&sqfs.internal, @ptrCast(&inode.internal), &bl);

        var i: usize = 0;
        var bl = try SquashFs.File.BlockList.init(sqfs, inode);
        while (bl.remain > 0 and i < count) {
            try bl.next(sqfs.allocator);

            errdefer {
                sqfs.allocator.free(blockidx[0..count]);
                unreachable;
            }

            if (bl.cur.offset < 4 and !first) {
                blockidx[i].data_block = bl.block + bl.input_size;
                blockidx[i].md_block = @intCast(@as(u64, @intCast(bl.cur.block)) - sqfs.super_block.inode_table_start);
                i += 1;
            }
            first = false;
        }

        cachep.* = @ptrCast(blockidx.ptr);
        return blockidx;
    }

    // TODO: refactor
    pub fn blockList(
        sqfs: *SquashFs,
        inode: *SquashFs.Inode,
        //bl: *SquashFs.File.BlockList,
        start: u64,
    ) !SquashFs.File.BlockList {
        var blockidx: []const BlockIdx.Entry = undefined;

        var idx: usize = 0;

        var bl = try SquashFs.File.BlockList.init(sqfs, inode);

        const block: usize = @intCast(start / sqfs.super_block.block_size);
        if (block > bl.remain) {
            bl.remain = 0;
            return bl;
        }

        const metablock = (bl.cur.offset + block * 4) / SquashFs.metadata_size;

        if (metablock == 0) return bl;

        if (!BlockIdx.indexable(
            sqfs,
            inode,
        )) return bl;

        idx = inode.internal.base.inode_number + 1;

        const bp = sqfs.blockidx.get(idx);

        if (sqfs.blockidx.entries[idx].header.valid) {
            blockidx = &[_]BlockIdx.Entry{bp.entry.*};
        } else {
            blockidx = try addBlockIdx(
                sqfs,
                inode,
                @ptrCast(bp),
            );
            sqfs.blockidx.entries[idx].header.valid = true;
        }

        const skipped = (metablock * SquashFs.metadata_size / 4) - (bl.cur.offset / 4);

        blockidx.ptr += metablock - 1;

        bl.cur.block = @intCast(blockidx[0].md_block + sqfs.super_block.inode_table_start);
        bl.cur.offset %= 4;
        bl.remain -= skipped;
        bl.pos = skipped * sqfs.super_block.block_size;
        bl.block = blockidx[0].data_block;

        return bl;
    }
};
