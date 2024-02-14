const std = @import("std");
const os = std.os;

const SquashFs = @import("SquashFs.zig").SquashFs;

const c = @cImport({
    @cInclude("squashfuse.h");
});

const Table = @This();

const sqfs_table = c.sqfs_table;

internal: c.sqfs_table,
count: usize,

// TODO: port table struct and move methods into it
pub fn init(
    allocator: std.mem.Allocator,
    fd: c.sqfs_fd_t,
    start: c.sqfs_off_t,
    each: usize,
    count: usize,
) !sqfs_table {
    var table: sqfs_table = undefined;

    if (count == 0) return table;

    const nblocks = try std.math.divCeil(
        usize,
        each * count,
        SquashFs.metadata_size,
    );
    const bread = nblocks * 8;

    table.each = each;

    const blocks = try allocator.alloc(u64, nblocks);
    table.blocks = blocks.ptr;

    const blocks_buf: [*]u8 = @ptrCast(table.blocks);
    if (try os.pread(fd, blocks_buf[0..bread], @intCast(start)) != bread) {
        allocator.free(blocks);
        table.blocks = null;
        return error.Error;
    }

    var i: usize = 0;
    while (i < nblocks) : (i += 1) {
        table.blocks[i] = std.mem.littleToNative(u64, table.blocks[i]);
    }

    return table;
}

pub fn deinit(
    allocator: std.mem.Allocator,
    table: *sqfs_table,
    count: usize,
) void {
    const nblocks = c.sqfs_divceil(
        table.each * count,
        SquashFs.metadata_size,
    );

    allocator.free(table.blocks[0..nblocks]);
    table.blocks = null;
}
