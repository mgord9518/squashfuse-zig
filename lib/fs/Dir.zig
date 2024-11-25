const std = @import("std");
const squashfuse = @import("../root.zig");
const metadata = squashfuse.metadata;
const SquashFs = squashfuse.SquashFs;
const assert = std.debug.assert;

pub const Dir = @This();

// Must be a string allocated by `sqfs.allocator`
path: ?[]const u8 = null,

sqfs: *SquashFs,
size: u64,
id: SquashFs.Inode.TableEntry,

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

pub const OpenError = std.fs.Dir.OpenError;

pub fn readLink(self: Dir, sub_path: []const u8, buffer: []u8) ![]u8 {
    var sqfs = self.sqfs;

    populateInodeMapIfNull(sqfs) catch return error.SystemResources;

    const normalized_sub = normalizePath(
        sqfs.allocator,
        sub_path,
    ) catch return error.SystemResources;
    defer sqfs.allocator.free(normalized_sub);

    const inode_entry = sqfs.inode_map.?.get(
        normalized_sub,
    ) orelse return error.FileNotFound;

    var inode = sqfs.getInode(
        inode_entry,
    ) catch unreachable;

    return inode.readLink(buffer);
}

pub fn stat(self: Dir) !std.fs.File.Stat {
    var inode = self.sqfs.getInode(self.id) catch unreachable;

    return inode.stat();
}

pub fn statC(self: Dir) !std.os.linux.Stat {
    var inode = self.sqfs.getInode(self.id) catch unreachable;

    return inode.statC();
}

pub fn openFile(
    dir: Dir,
    sub_path: []const u8,
    opts: std.fs.File.OpenFlags,
) SquashFs.File.OpenError!SquashFs.File {
    _ = opts;

    var sqfs = dir.sqfs;

    populateInodeMapIfNull(sqfs) catch return error.SystemResources;

    const normalized_sub = normalizePath(
        sqfs.allocator,
        sub_path,
    ) catch return error.SystemResources;
    defer sqfs.allocator.free(normalized_sub);

    const resolved = std.fs.path.resolve(
        sqfs.allocator,
        &.{ dir.path.?, normalized_sub },
    ) catch return error.SystemResources;
    defer sqfs.allocator.free(resolved);

    const inode_entry = sqfs.inode_map.?.get(
        resolved,
    ) orelse return error.FileNotFound;

    var inode = sqfs.getInode(
        inode_entry,
    ) catch unreachable;

    if (inode.kind == .sym_link) {
        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

        const target = inode.readLink(&buf) catch return error.Unexpected;

        const new_inode_entry = sqfs.inode_map.?.get(
            target,
        ) orelse return error.FileNotFound;

        const new_inode = sqfs.getInode(new_inode_entry) catch unreachable;

        return SquashFs.File.initFromInode(new_inode);
    }

    return SquashFs.File.initFromInode(inode);
}

pub fn openDir(
    dir: Dir,
    sub_path: []const u8,
    opts: std.fs.Dir.OpenDirOptions,
) OpenError!Dir {
    _ = opts;

    var sqfs = dir.sqfs;

    populateInodeMapIfNull(sqfs) catch return error.SystemResources;

    const normalized_sub = normalizePath(
        sqfs.allocator,
        sub_path,
    ) catch return error.SystemResources;
    defer sqfs.allocator.free(normalized_sub);

    const resolved = std.fs.path.resolve(
        sqfs.allocator,
        &.{ dir.path.?, normalized_sub },
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

    return .{
        .sqfs = sqfs,
        .id = table_entry,
        .size = inode.xtra.dir.size -| 3,
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
    };
}

pub fn iterate(dir: Dir) !Iterator {
    const inode = try dir.sqfs.getInode(dir.id);

    if (inode.kind != .directory) return error.NotDir;

    return .{
        .idx = 0,
        .offset = 0,
        .sqfs = dir.sqfs,
        .dir = dir,
        .cur = metadata.Cursor.init(
            dir.sqfs,
            .directory_table,
            .{
                .block = inode.xtra.dir.start_block,
                .offset = inode.xtra.dir.offset,
            },
        ),
        .header = .{
            .entry_count = 0,
            .start_block = 0,
            .inode_number = 0,
        },
    };
}

pub const Iterator = struct {
    sqfs: *SquashFs,
    name_buf: [256]u8 = undefined,
    offset: u64,
    dir: Dir,
    cur: metadata.Cursor,
    header: Header,

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
        assert(it.idx <= it.header.entry_count);

        // Load a new header
        if (it.idx == it.header.entry_count) {
            if (it.offset == it.dir.size) {
                return null;
            }

            it.offset += @sizeOf(Header);
            it.header = try it.cur.reader().readStructEndian(
                Header,
                .little,
            );

            // Count offset by 1
            it.header.entry_count += 1;

            it.idx = 0;
        }

        var internal_entry: InternalEntry = undefined;
        try it.cur.load(&internal_entry);
        internal_entry = squashfuse.littleToNative(internal_entry);
        it.offset += @sizeOf(InternalEntry);

        it.idx += 1;

        const inode_number = @as(i33, it.header.inode_number) + internal_entry.inode_delta_offset;

        const entry = Iterator.Entry{
            .name = it.name_buf[0 .. internal_entry.name_len + 1],
            .kind = internal_entry.kind.toKind(),
            .inode_id = .{
                .block = it.header.start_block,
                .offset = internal_entry.offset,
            },
            .inode_number = @intCast(inode_number),
            .offset = it.offset,
        };

        const read_len = try it.cur.reader().readAll(entry.name);
        it.offset += entry.name.len;

        assert(read_len == entry.name.len);

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

// Caller owns returned memory
fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_list = std.ArrayList([]const u8).init(allocator);
    defer path_list.deinit();

    var it = try std.fs.path.componentIterator(path);

    try path_list.append("/");
    while (it.next()) |component| {
        try path_list.append(component.name);
    }

    return try std.fs.path.resolvePosix(
        allocator,
        path_list.items,
    );
}

// TODO: Add inodes as they're accessed
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
            try std.fmt.allocPrint(sqfs.allocator, "/{s}", .{entry.path}),
            entry.id,
        );
    }
}
