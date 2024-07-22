const std = @import("std");
const io = std.io;
const os = std.os;
const posix = std.posix;
const fs = std.fs;

// TODO: is this always correct?
const S = std.os.linux.S;

const Stat = std.os.linux.Stat;

pub const build_options = @import("build_options");

const Table = @import("table.zig").Table;

const squashfuse = @import("root.zig");
const SquashFs = squashfuse.SquashFs;

pub const MetadataCursor = extern struct {
    sqfs: *SquashFs,
    block: u64,
    offset: usize,

    /// Reads
    pub fn load(
        cur: *SquashFs.MetadataCursor,
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

                try cur.read(item_u8[0..size]);
            },
            else => unreachable,
        }
    }

    pub fn read(
        cur: *SquashFs.MetadataCursor,
        buf: []u8,
    ) !void {
        var pos = cur.block;

        var size = buf.len;
        var nbuf = buf;

        while (size > 0) {
            const block = try cur.sqfs.mdCache(&pos);

            const take = @min(
                block.data.len - cur.offset,
                size,
            );

            @memcpy(
                nbuf[0..take],
                block.data[cur.offset..][0..take],
            );

            nbuf = nbuf[take..];

            size -= take;
            cur.offset += take;

            if (cur.offset == block.data.len) {
                cur.block = pos;
                cur.offset = 0;
            }
        }
    }
};
