const std = @import("std");

const squashfuse = @import("root.zig");
const SquashFs = squashfuse.SquashFs;

pub fn Table(T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        sqfs: *SquashFs,
        blocks: []u64,

        pub fn init(
            allocator: std.mem.Allocator,
            sqfs: *SquashFs,
            start: u64,
            count: usize,
        ) !Self {
            const block_count = try std.math.divCeil(
                usize,
                count * @sizeOf(T),
                SquashFs.metadata_block_size,
            );

            const table = Self{
                .sqfs = sqfs,
                .allocator = allocator,
                .blocks = try allocator.alloc(u64, block_count),
            };

            try sqfs.load(
                table.blocks,
                start,
            );

            for (table.blocks) |*block| {
                block.* = std.mem.littleToNative(u64, block.*);
            }

            return table;
        }

        pub fn get(
            table: *Self,
            idx: usize,
        ) !T {
            const pos = idx * @sizeOf(T);
            const bnum = pos / SquashFs.metadata_block_size;
            const off = pos % SquashFs.metadata_block_size;

            var bpos = table.blocks[bnum];
            const block = try table.sqfs.mdCache(&bpos);

            var buf: [@sizeOf(T)]u8 = undefined;

            @memcpy(
                &buf,
                block.data[off..][0..@sizeOf(T)],
            );

            return @bitCast(buf);
        }

        pub fn deinit(
            table: *Self,
        ) void {
            table.allocator.free(table.blocks);
        }
    };
}
