const std = @import("std");

const squashfuse = @import("root.zig");
const SquashFs = squashfuse.SquashFs;

pub const Block = struct {
    data: []u8,
    data_size: usize = 0,
};

pub const Table = enum {
    inode_table,
    directory_table,
};

pub const Cursor = extern struct {
    sqfs: *SquashFs,
    block: u64,
    offset: usize,

    pub fn init(sqfs: *SquashFs, table: Table, id: anytype) Cursor {
        const start = switch (table) {
            .inode_table => sqfs.super_block.inode_table_start,
            .directory_table => sqfs.super_block.directory_table_start,
        };

        return .{
            .sqfs = sqfs,
            .block = start + id.block,
            .offset = id.offset,
        };
    }

    pub fn load(
        cur: *Cursor,
        pointer: anytype,
    ) !void {
        const T = @TypeOf(pointer);

        switch (@typeInfo(T)) {
            .Pointer => |info| {
                const size = if (info.size == .Slice) blk: {
                    const ChildT = @TypeOf(pointer.ptr);
                    break :blk @sizeOf(@typeInfo(ChildT).Pointer.child) * pointer.len;
                } else blk: {
                    break :blk @sizeOf(@typeInfo(T).Pointer.child);
                };

                const item_u8: [*]u8 = if (info.size == .Slice) blk: {
                    break :blk @ptrCast(pointer.ptr);
                } else blk: {
                    break :blk @ptrCast(pointer);
                };

                _ = try cur.reader().readAll(item_u8[0..size]);
            },
            else => unreachable,
        }
    }

    pub const ReadError = std.fs.File.ReadError ||
        squashfuse.compression.DecompressError ||
        error{Unseekable};

    pub const Reader = std.io.Reader(
        *Cursor,
        ReadError,
        read,
    );

    pub fn reader(self: *Cursor) Reader {
        return .{ .context = self };
    }

    pub fn read(
        cur: *Cursor,
        buf: []u8,
    ) ReadError!usize {
        var block_offset = cur.block;

        var block = try cur.sqfs.mdCache(&block_offset);

        const take = @min(
            block.data[cur.offset..].len,
            buf.len,
        );

        @memcpy(
            buf[0..take],
            block.data[cur.offset..][0..take],
        );

        cur.offset += take;

        // Move to next block
        if (cur.offset == block.data.len) {
            cur.block = block_offset;
            cur.offset = 0;

            block = try cur.sqfs.mdCache(&block_offset);
        }

        return take;
    }

    pub fn readOld(
        cur: *Cursor,
        buf: []u8,
    ) ReadError!usize {
        var block_offset = cur.block;
        var idx: usize = 0;

        var block = try cur.sqfs.mdCache(&block_offset);

        while (idx < buf.len) {
            const take = @min(
                block.data[cur.offset..].len,
                buf[idx..].len,
            );

            @memcpy(
                buf[idx..][0..take],
                block.data[cur.offset..][0..take],
            );

            idx += take;
            cur.offset += take;

            // Move to next block
            if (cur.offset == block.data.len) {
                cur.block = block_offset;
                cur.offset = 0;

                block = try cur.sqfs.mdCache(&block_offset);
            }
        }

        return buf.len;
    }
};
