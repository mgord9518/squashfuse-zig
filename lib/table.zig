const std = @import("std");
const io = std.io;
const os = std.os;
const fs = std.fs;
const xz = std.compress.xz;
const zstd = std.compress.zstd;
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("squashfuse.h");
    @cInclude("common.h");

    @cInclude("nonstd.h");
    @cInclude("fs.h");
    @cInclude("swap.h");
});

internal: c.sqfs_table,
count: usize,

const Table = @This();

const sqfs_table = c.sqfs_table;

// TODO: port table struct and move methods into it
pub fn initTable(
    allocator: std.mem.Allocator,
    table: *sqfs_table,
    fd: c.sqfs_fd_t,
    start: c.sqfs_off_t,
    each: usize,
    count: usize,
) !void {
    if (count == 0) return;

    //const nblocks = try std.math.divCeil(usize, each * count, c.SQUASHFS_METADATA_SIZE);
    const nblocks = c.sqfs_divceil(each * count, c.SQUASHFS_METADATA_SIZE);
    const bread = nblocks * 8;

    table.each = each;

    table.blocks = (try allocator.alloc(u64, nblocks)).ptr;

    if (c.sqfs_pread(fd, table.blocks, bread, start) != bread) {
        allocator.free(table.blocks[0..nblocks]);
        table.blocks = null;
        return error.Error;
    }

    var i: usize = 0;
    while (i < nblocks) : (i += 1) {
        table.blocks[i] = std.mem.littleToNative(u64, table.blocks[i]);
        //        table.blocks[i] = @byteSwap(table.blocks[i]);
        //c.sqfs_swapin64(&table.blocks[i]);
    }
}

pub fn deinitTable(
    allocator: std.mem.Allocator,
    table: *sqfs_table,
    count: usize,
) void {
    //const nblocks = std.math.divCeil(usize, table.each * count, c.SQUASHFS_METADATA_SIZE) catch unreachable;
    const nblocks = c.sqfs_divceil(table.each * count, c.SQUASHFS_METADATA_SIZE);

    allocator.free(table.blocks[0..nblocks]);
    table.blocks = null;
}
