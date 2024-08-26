const std = @import("std");
const os = std.os;
const squashfuse = @import("../root.zig");
const metadata = squashfuse.metadata;
const SquashFs = squashfuse.SquashFs;
const assert = std.debug.assert;

pub const Dir = @This();

// Must be a string allocated by `sqfs.allocator`
path: ?[]const u8 = null,

sqfs: *SquashFs,
cur: metadata.Cursor,
offset: u64,
size: u64,
header: Header,

// <https://dr-emann.github.io/squashfs/#directory-table>
const InternalEntry = packed struct(u64) {
    offset: u16,
    inode_delta_offset: i16,

    kind: SquashFs.File.InternalKind,
    _36: u12,

    // One less than the file name length
    name_len: u16,

    // The name data immediately follows
};

pub const Header = extern struct {
    // One less than the number of entries
    entry_count: u32,

    start_block: u32,
    inode_number: u32,
};

fn populateInodeMapIfNull(sqfs: *SquashFs) !void {
    if (sqfs.inode_map != null) return;

    sqfs.inode_map = std.StringHashMap(
        SquashFs.Inode.TableEntry,
    ).init(sqfs.allocator);

    var root = sqfs.root();
    var walker = try root.walk(sqfs.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        try sqfs.inode_map.?.put(
            try sqfs.allocator.dupe(u8, entry.path),
            entry.id,
        );
    }
}

pub const OpenError = std.fs.Dir.OpenError;

//pub fn openFile(dir: *Dir,
//    sub_path: []const u8,
//    )

pub fn openDir(
    dir: *Dir,
    sub_path: []const u8,
    opts: std.fs.Dir.OpenDirOptions,
) OpenError!Dir {
    _ = opts;

    var sqfs = dir.sqfs;

    populateInodeMapIfNull(sqfs) catch return error.SystemResources;

    const resolved = std.fs.path.resolve(
        sqfs.allocator,
        &.{ dir.path.?, sub_path },
    ) catch return error.SystemResources;
    defer sqfs.allocator.free(resolved);

    const inode_entry = sqfs.inode_map.?.get(
        resolved,
    ) orelse return error.FileNotFound;

    const path = sqfs.inode_map.?.getKey(
        resolved,
    ).?;

    return Dir.initFromInodeTableEntry(
        sqfs,
        inode_entry,
        path,
    ) catch |err| {
        // TODO: better errors
        return switch (err) {
            error.NotDir => error.NotDir,
            else => error.SystemResources,
        };
    };
}

pub fn close(dir: *Dir) void {
    dir.* = undefined;
}

// Low-level init function for internal usage
pub fn initFromInodeTableEntry(
    sqfs: *SquashFs,
    table_entry: SquashFs.Inode.TableEntry,
    path: ?[]const u8,
) !Dir {
    const inode = try sqfs.getInode(table_entry);

    if (inode.kind != .directory) return error.NotDir;

    const start_block = inode.xtra.dir.start_block;

    return .{
        .sqfs = sqfs,
        .cur = metadata.Cursor.init(
            sqfs,
            .directory_table,
            .{
                .block = start_block,
                .offset = inode.xtra.dir.offset,
            },
        ),
        .offset = 0,
        .size = inode.xtra.dir.size -| 3,
        .header = std.mem.zeroes(Header),
        .path = path,
    };
}

pub fn initFromInode(sqfs: *SquashFs, inode: *SquashFs.Inode) !Dir {
    if (inode.kind != .directory) return error.NotDir;

    return .{
        .sqfs = sqfs,
        .cur = .{
            .sqfs = sqfs,
            .block = @intCast(inode.xtra.dir.start_block + sqfs.super_block.directory_table_start),
            .offset = inode.xtra.dir.offset,
        },
        .offset = 0,
        .size = @intCast(inode.xtra.dir.size -| 3),
        .header = std.mem.zeroes(Header),
    };
}

pub fn iterate(dir: *const Dir) !Iterator {
    return .{
        .idx = 0,
        .sqfs = dir.sqfs,
        .dir = dir.*,
    };
}

pub const Iterator = struct {
    sqfs: *SquashFs,
    name_buf: [256]u8 = undefined,
    dir: Dir,

    // Entry index relative to the current header
    idx: u32,

    pub const Entry = struct {
        kind: SquashFs.File.Kind,
        name: []u8,

        inode_id: SquashFs.Inode.TableEntry,
        inode_number: u32,
        offset: u64,
    };

    pub fn next(
        it: *Iterator,
    ) !?Iterator.Entry {
        assert(it.idx <= it.dir.header.entry_count);

        // Load a new header
        if (it.idx == it.dir.header.entry_count) {
            if (it.dir.offset == it.dir.size) {
                return null;
            }

            it.dir.offset += @sizeOf(Header);
            //try it.dir.cur.load(&it.dir.header);

            it.dir.header = try it.dir.cur.reader().readStructEndian(
                Header,
                .little,
            );

            it.idx = 0;

            it.dir.header = squashfuse.littleToNative(it.dir.header);

            // Count offset by 1
            it.dir.header.entry_count += 1;
        }

        var internal_entry: InternalEntry = undefined;
        try it.dir.cur.load(&internal_entry);
        internal_entry = squashfuse.littleToNative(internal_entry);
        it.dir.offset += @sizeOf(InternalEntry);

        it.idx += 1;

        const inode_number = @as(i33, it.dir.header.inode_number) + internal_entry.inode_delta_offset;

        const entry = Iterator.Entry{
            .name = it.name_buf[0 .. internal_entry.name_len + 1],
            .kind = internal_entry.kind.toKind(),
            .inode_id = .{
                .block = it.dir.header.start_block,
                .offset = internal_entry.offset,
            },
            .inode_number = @intCast(inode_number),
            .offset = it.dir.offset,
        };

        try it.dir.cur.load(entry.name);
        it.dir.offset += entry.name.len;

        return entry;
    }
};

pub fn walk(self: *Dir, allocator: std.mem.Allocator) !Walker {
    var name_buffer = std.ArrayList(u8).init(allocator);
    errdefer name_buffer.deinit();

    var stack = std.ArrayList(Walker.StackItem).init(allocator);
    errdefer stack.deinit();

    try stack.append(Walker.StackItem{
        .iter = try self.iterate(),
        .dirname_len = 0,
    });

    return Walker{
        .stack = stack,
        .name_buffer = name_buffer,
    };
}

pub const Walker = struct {
    stack: std.ArrayList(StackItem),
    name_buffer: std.ArrayList(u8),

    const StackItem = struct {
        iter: Dir.Iterator,
        dirname_len: usize,
    };

    pub const Entry = struct {
        id: SquashFs.Inode.TableEntry,

        dir: Dir,
        kind: SquashFs.File.Kind,
        path: []const u8,
        basename: []const u8,
    };

    // Copied and slightly modified from Zig stdlib
    // <https://github.com/ziglang/zig/blob/master/lib/std/fs.zig>
    pub fn next(self: *Walker) !?Walker.Entry {
        while (self.stack.items.len != 0) {
            // `top` and `containing` become invalid after appending to `self.stack`
            var top = &self.stack.items[self.stack.items.len - 1];
            var containing = top;
            var dirname_len = top.dirname_len;

            if (try top.iter.next()) |entry| {
                self.name_buffer.shrinkRetainingCapacity(dirname_len);

                if (self.name_buffer.items.len != 0) {
                    try self.name_buffer.append(std.fs.path.sep);
                    dirname_len += 1;
                }

                try self.name_buffer.appendSlice(entry.name);

                if (entry.kind == .directory) {
                    var new_dir = try Dir.initFromInodeTableEntry(
                        top.iter.sqfs,
                        entry.inode_id,
                        null,
                    );

                    {
                        try self.stack.append(StackItem{
                            .iter = try new_dir.iterate(),
                            .dirname_len = self.name_buffer.items.len,
                        });
                        top = &self.stack.items[self.stack.items.len - 1];
                        containing = &self.stack.items[self.stack.items.len - 2];
                    }
                }

                const path = self.name_buffer.items;
                const basename = self.name_buffer.items[dirname_len .. self.name_buffer.items.len - 1];

                return .{
                    .dir = containing.iter.dir,
                    .basename = basename,
                    .id = entry.inode_id,
                    .path = path,
                    .kind = entry.kind,
                };
            }

            _ = self.stack.pop();
        }

        return null;
    }

    pub fn deinit(self: *Walker) void {
        self.stack.deinit();
        self.name_buffer.deinit();
    }
};

pub const IteratorOld = struct {
    sqfs: *SquashFs,
    name_buf: []u8,
    dir: *Dir,

    pub fn next(
        iterator: *IteratorOld,
    ) !?Iterator.Entry {
        var ll_entry: InternalEntry = undefined;
        var entry: Iterator.Entry = undefined;
        var dir = iterator.dir;

        entry.name = iterator.name_buf;

        entry.offset = dir.offset;

        while (dir.header.entry_count == 0) {
            if (dir.offset >= dir.size) {
                return null;
            }

            dir.offset += @sizeOf(Header);
            try dir.cur.load(&dir.header);

            dir.header = squashfuse.littleToNative(dir.header);
            dir.header.entry_count += 1;
        }

        dir.offset += @sizeOf(InternalEntry);
        try dir.cur.load(&ll_entry);

        ll_entry = squashfuse.littleToNative(ll_entry);

        dir.header.entry_count -= 1;

        entry.kind = ll_entry.kind.toKind();

        entry.name.len = ll_entry.name_len + 1;

        entry.inode_id = .{
            .block = dir.header.start_block,
            .offset = ll_entry.offset,
        };

        entry.inode_number = dir.header.inode_number + @as(u16, @intCast(ll_entry.inode_delta_offset));

        dir.offset += entry.name.len;
        try dir.cur.load(entry.name);

        return entry;
    }
};
