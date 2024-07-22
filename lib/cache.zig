const std = @import("std");
const squashfuse = @import("root.zig");
const SquashFs = squashfuse.SquashFs;
const Inode = SquashFs.Inode;
const assert = std.debug.assert;

pub fn Cache(T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,

        entry_idxs: []u64,
        entries: []T,
        data: ?[]u8,
        compressed_data: ?[]u8,

        count: usize,

        pos: usize = 0,

        pub const Options = struct {
            block_size: usize = 0,
        };

        pub const Entry = struct {
            idx: u64,
            entry: T,
        };

        pub fn init(
            allocator: std.mem.Allocator,
            count: usize,
            opts: Options,
        ) !Self {
            const cache = .{
                .allocator = allocator,
                .count = count,
                .entries = try allocator.alloc(
                    T,
                    count,
                ),
                .entry_idxs = try allocator.alloc(
                    u64,
                    count,
                ),
                .data = try allocator.alloc(
                    u8,
                    count * opts.block_size,
                ),
                .compressed_data = try allocator.alloc(
                    u8,
                    count * opts.block_size,
                ),
            };

            @memset(cache.entry_idxs, SquashFs.invalid_block);

            return cache;
        }

        pub fn deinit(cache: *Self) void {
            cache.allocator.free(cache.entry_idxs);
            cache.allocator.free(cache.entries);

            if (cache.data) |data| {
                cache.allocator.free(data);
            }

            if (cache.compressed_data) |compressed_data| {
                cache.allocator.free(compressed_data);
            }
        }

        pub fn get(cache: *Self, id: u64) ?T {
            const ptr = cache.getPtr(id);

            if (ptr) |p| return p.*;

            return null;
        }

        pub fn getPtr(
            cache: *Self,
            id: u64,
        ) ?*T {
            assert(id != SquashFs.invalid_block);

            for (cache.entry_idxs, 0..) |i, idx| {
                if (i == id) {
                    return &cache.entries[idx];
                }
            }

            return null;
        }

        pub fn put(
            cache: *Self,
            id: u64,
            item: T,
        ) void {
            const entry = &cache.entries[cache.pos];
            entry.* = item;

            cache.entry_idxs[cache.pos] = id;

            cache.pos += 1;
            cache.pos %= cache.count;
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
        return md_size >= SquashFs.metadata_block_size;
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
        const count = (inode.internal.next.offset + md_size - 1) / SquashFs.metadata_block_size;

        var blockidx = sqfs.allocator.alloc(BlockIdx.Entry, count) catch unreachable;

        var i: usize = 0;
        var bl = try SquashFs.File.BlockList.init(sqfs, inode);
        while (bl.remain > 0 and i < count) {
            try bl.next();

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

        const metablock = (bl.cur.offset + block * 4) / SquashFs.metadata_block_size;

        if (metablock == 0) return bl;

        if (!BlockIdx.indexable(
            sqfs,
            inode,
        )) return bl;

        idx = inode.internal.base.inode_number + 1;

        const bp = sqfs.blockidx.getPtr(idx);

        if (bp == null) {
            blockidx = &[_]BlockIdx.Entry{bp.?.*.*};
        } else {
            blockidx = try addBlockIdx(
                sqfs,
                inode,
                @ptrCast(bp),
            );
        }

        const skipped = (metablock * SquashFs.metadata_block_size / 4) - (bl.cur.offset / 4);

        blockidx.ptr += metablock - 1;

        bl.cur.block = @intCast(blockidx[0].md_block + sqfs.super_block.inode_table_start);
        bl.cur.offset %= 4;
        bl.remain -= skipped;
        bl.pos = skipped * sqfs.super_block.block_size;
        bl.block = blockidx[0].data_block;

        return bl;
    }
};
