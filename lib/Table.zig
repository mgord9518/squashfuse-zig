const Table = @This();

const std = @import("std");
const os = std.os;

const squashfuse = @import("squashfuse.zig");
const SquashFs = squashfuse.SquashFs;
const Cache = @import("Cache.zig");

allocator: std.mem.Allocator,
each: usize,
blocks: []u64,
count: usize,

// TODO: port table struct and move methods into it
pub fn init(
    allocator: std.mem.Allocator,
    fd: i32,
    start: usize,
    each: usize,
    count: usize,
) !Table {
    var table: Table = undefined;

    if (count == 0) return Table{
        .allocator = allocator,
        .each = 0,
        .blocks = &[_]u64{},
        .count = 0,
    };

    const nblocks = try std.math.divCeil(
        usize,
        each * count,
        SquashFs.metadata_size,
    );
    //const bread = nblocks * 8;

    table.each = each;

    table.blocks = try allocator.alloc(u64, nblocks);

    try squashfuse.load(
        fd,
        table.blocks,
        start,
    );

    var i: usize = 0;
    while (i < nblocks) : (i += 1) {
        table.blocks[i] = std.mem.littleToNative(u64, table.blocks[i]);
    }

    return table;
}

pub fn get(
    allocator: std.mem.Allocator,
    table: *Table,
    sqfs: *SquashFs,
    idx: usize,
    buf: [*]u8,
) !void {
    const pos = idx * table.each;
    const bnum = pos / SquashFs.metadata_size;
    const off = pos % SquashFs.metadata_size;

    var bpos = table.blocks[bnum];

    const block = try sqfs.mdCache(allocator, &bpos);

    @memcpy(buf[0..table.each], block.data[off..][0..table.each]);

    // TODO c.sqfs_block_dispose
}

pub fn deinit(
    allocator: std.mem.Allocator,
    table: *Table,
) void {
    allocator.free(table.blocks);
    //table.blocks = null;
}
