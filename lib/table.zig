const std = @import("std");
const os = std.os;

const squashfuse = @import("root.zig");
const SquashFs = squashfuse.SquashFs;

pub fn Table(T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        blocks: []u64,

        pub fn init(
            allocator: std.mem.Allocator,
            sqfs: *SquashFs,
            start: usize,
            count: usize,
        ) !Self {
            if (count == 0) return .{
                .allocator = allocator,
                .blocks = &[_]u64{},
            };

            const block_count = try std.math.divCeil(
                usize,
                count * @sizeOf(T),
                SquashFs.metadata_size,
            );

            const table = Self{
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
            allocator: std.mem.Allocator,
            sqfs: *SquashFs,
            idx: usize,
            buf: *T,
        ) !void {
            const pos = idx * @sizeOf(T);
            const bnum = pos / SquashFs.metadata_size;
            const off = pos % SquashFs.metadata_size;

            var bpos = table.blocks[bnum];

            // TODO: Update functions to u64
            const block = try sqfs.mdCache(allocator, &bpos);

            const target_u8_ptr: [*]u8 = @ptrCast(buf);
            @memcpy(target_u8_ptr[0..@sizeOf(T)], block.data[off..][0..@sizeOf(T)]);

            // TODO c.sqfs_block_dispose
        }

        pub fn deinit(
            table: *Self,
        ) void {
            table.allocator.free(table.blocks);
        }
    };
}
