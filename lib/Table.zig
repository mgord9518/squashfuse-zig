const Table = @This();

const std = @import("std");
const os = std.os;

const squashfuse = @import("squashfuse.zig");
const SquashFs = squashfuse.SquashFs;
const Cache = @import("Cache.zig");

allocator: std.mem.Allocator,
each: usize,
blocks: []u64,

pub fn init(
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    start: usize,
    each: usize,
    count: usize,
) !Table {
    if (count == 0) return Table{
        .allocator = allocator,
        .each = 0,
        .blocks = &[_]u64{},
    };

    const block_count = try std.math.divCeil(
        usize,
        each * count,
        SquashFs.metadata_size,
    );

    const table = Table{
        .allocator = allocator,
        .each = each,
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
    table: *Table,
    allocator: std.mem.Allocator,
    sqfs: *SquashFs,
    idx: usize,
    buf: [*]u8,
) !void {
    const pos = idx * table.each;
    const bnum = pos / SquashFs.metadata_size;
    const off = pos % SquashFs.metadata_size;

    var bpos = table.blocks[bnum];

    // TODO: Update functions to u64
    const block = try sqfs.mdCache(allocator, &bpos);

    @memcpy(buf[0..table.each], block.data[off..][0..table.each]);

    // TODO c.sqfs_block_dispose
}

pub fn deinit(
    table: *Table,
) void {
    table.allocator.free(table.blocks);
    //table.blocks = null;
}
