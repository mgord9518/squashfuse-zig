const std = @import("std");
const io = std.io;
const os = std.os;
const posix = std.posix;
const fs = std.fs;

// TODO: is this always correct?
const S = std.os.linux.S;

const Stat = std.os.linux.Stat;

pub const build_options = @import("build_options");

const squashfuse = @import("../root.zig");
const SquashFs = squashfuse.SquashFs;
const SuperBlock = SquashFs.SuperBlock;

const Inode = @This();

internal: Inode.Internal,
parent: *SquashFs,
kind: SquashFs.File.Kind,
pos: u64 = 0,

pub const TableEntry = packed struct(u64) {
    offset: u16,
    block: u32,
    _: u16 = 0,
};

// TODO: move this into parent inode
pub const Internal = extern struct {
    base: SquashFs.SuperBlock.InodeBase,
    nlink: u32,
    xattr: u32,
    next: SquashFs.MetadataCursor,

    xtra: extern union {
        reg: SuperBlock.LFileInode,
        dev: SuperBlock.LDevInode,
        symlink: SuperBlock.SymLinkInode,
        dir: SuperBlock.LDirInode,
    },
};

fn fragBlock(
    inode: *Inode,
    offset: *u64,
    size: *u64,
) ![]u8 {
    var sqfs = inode.parent;

    if (inode.kind != .file) return error.Error;

    if (inode.internal.xtra.reg.frag_idx == SquashFs.invalid_frag) return error.Error;

    const frag = try sqfs.frag_table.get(
        inode.internal.xtra.reg.frag_idx,
    );

    const block_data = try sqfs.dataCache(
        &sqfs.frag_cache,
        frag.start_block,
        frag.block_header,
    );

    offset.* = inode.internal.xtra.reg.frag_off;
    size.* = inode.internal.xtra.reg.size % sqfs.super_block.block_size;

    return block_data;
}

/// Reads the link target into `buf`
pub fn readLink(inode: *Inode, buf: []u8) ![]const u8 {
    if (inode.kind != .sym_link) {
        // TODO: rename
        return error.NotLink;
    }

    const len = inode.internal.xtra.symlink.size;

    if (len > buf.len) {
        return error.NoSpaceLeft;
    }

    var cur = inode.internal.next;

    try cur.read(buf[0..len]);

    return buf[0..len];
}

pub fn readLinkZ(self: *Inode, buf: []u8) ![:0]const u8 {
    const link_target = try self.readLink(buf[0 .. buf.len - 1]);
    buf[link_target.len] = '\x00';

    return buf[0..link_target.len :0];
}

// TODO: Move these to `SquashFs.File`
pub const ReadError = std.fs.File.ReadError;
pub fn read(self: *Inode, buf: []u8) ReadError!usize {
    const buf_len = try self.pread(
        buf,
        self.pos,
    );

    self.pos += buf_len;

    return buf_len;
}

pub const PReadError = ReadError;
pub fn pread(
    inode: *SquashFs.Inode,
    buf: []u8,
    offset: u64,
) PReadError!usize {
    if (inode.kind == .directory) return error.IsDir;

    var nbuf = buf;
    var sqfs = inode.parent;

    const file_size = inode.internal.xtra.reg.size;
    const block_size = sqfs.super_block.block_size;

    if (offset > file_size) return error.InputOutput;

    if (offset == file_size) return 0;

    // TODO: investigate performance on large files
    var block_list = SquashFs.File.BlockList.init(
        sqfs,
        inode,
    ) catch return error.InputOutput;

    var read_off: usize = @intCast(offset % block_size);

    while (nbuf.len > 0) {
        var block_data: ?[]u8 = null;
        var data_off: u64 = 0;
        var data_size: u64 = 0;
        var take: usize = 0;

        const fragment = block_list.remain == 0;
        if (fragment) {
            if (inode.internal.xtra.reg.frag_idx == SquashFs.invalid_frag) break;

            block_data = inode.fragBlock(
                &data_off,
                &data_size,
            ) catch return error.SystemResources;
        } else {
            // TODO
            block_list.next() catch return error.SystemResources;

            if (block_list.pos + block_size <= offset) continue;

            data_off = 0;
            if (block_list.input_size == 0) {
                data_size = @intCast(file_size - block_list.pos);

                if (data_size > block_size) data_size = block_size;
            } else {
                block_data = sqfs.dataCache(
                    &sqfs.data_cache,
                    block_list.block,
                    block_list.header,
                ) catch return error.SystemResources;

                data_size = block_data.?.len;
            }
        }

        take = @intCast(data_size - read_off);
        if (take > nbuf.len) take = nbuf.len;

        if (block_data) |b| {
            @memcpy(
                nbuf[0..take],
                b[@intCast(data_off + read_off)..][0..take],
            );
        } else {
            @memset(nbuf[0..take], 0);
        }

        read_off = 0;
        nbuf = nbuf[take..];

        if (fragment) break;
    }

    const size = buf.len - nbuf.len;

    if (size == 0) return error.InputOutput;

    return size;
}

pub const SeekableStream = io.SeekableStream(
    Inode,
    SeekError,
    GetSeekPosError,
    seekTo,
    seekBy,
    getPos,
    getEndPos,
);

pub const setEndPos = @compileError("setEndPos not possible for SquashFS (read-only filesystem)");

pub const GetSeekPosError = posix.SeekError || posix.FStatError;
pub const SeekError = posix.SeekError || error{InvalidSeek};

// TODO: handle invalid seeks
pub fn seekTo(self: *Inode, pos: u64) SeekError!void {
    const end = self.getEndPos() catch return SeekError.Unseekable;

    if (pos > end) {
        return SeekError.InvalidSeek;
    }

    self.pos = pos;
}

pub fn seekBy(self: *Inode, pos: i64) SeekError!void {
    self.pos += pos;
}

pub fn seekFromEnd(self: *Inode, pos: i64) SeekError!void {
    const end = self.getEndPos() catch return SeekError.Unseekable;
    self.pos = end + pos;
}

pub fn getPos(self: *const Inode) GetSeekPosError!u64 {
    return self.pos;
}

pub fn getEndPos(self: *const Inode) GetSeekPosError!u64 {
    return self.internal.xtra.reg.size;
}

pub const Reader = io.Reader(Inode, os.ReadError, read);

pub fn reader(self: *Inode) Reader {
    return .{ .context = self };
}

fn getId(sqfs: *SquashFs, idx: u16) !u32 {
    const id = try sqfs.id_table.get(idx);

    return std.mem.littleToNative(
        u32,
        id,
    );
}

pub fn stat(inode: *Inode) !fs.File.Stat {
    const mtime = @as(i128, inode.internal.base.mtime) * std.time.ns_per_s;

    return .{
        // TODO
        .inode = 0,
        .size = switch (inode.kind) {
            .file => inode.internal.xtra.reg.size,
            .sym_link => inode.internal.xtra.symlink.size,
            .directory => inode.internal.xtra.dir.size,
            else => 0,
        },

        // Only exists on posix platforms
        .mode = if (fs.File.Mode == u0) 0 else inode.internal.base.mode,

        .kind = switch (inode.kind) {
            .block_device => .block_device,
            .character_device => .character_device,
            .directory => .directory,
            .named_pipe => .named_pipe,
            .sym_link => .sym_link,
            .file => .file,
            .unix_domain_socket => .unix_domain_socket,
        },

        .atime = mtime,
        .ctime = mtime,
        .mtime = mtime,
    };
}

// Like `Inode.stat` but returns the OS native stat format
pub fn statC(inode: *Inode) !Stat {
    var st = std.mem.zeroes(Stat);

    st.mode = inode.internal.base.mode;
    st.nlink = @intCast(inode.internal.nlink);

    st.atim.tv_sec = @intCast(inode.internal.base.mtime);
    st.ctim.tv_sec = @intCast(inode.internal.base.mtime);
    st.mtim.tv_sec = @intCast(inode.internal.base.mtime);

    switch (inode.kind) {
        .file => {
            st.size = @intCast(inode.internal.xtra.reg.size);
            st.blocks = @divTrunc(st.size, 512);
        },
        .block_device, .character_device => {
            st.rdev = @as(u32, @bitCast(inode.internal.xtra.dev.dev));
        },
        .sym_link => {
            st.size = @intCast(inode.internal.xtra.symlink.size);
        },
        else => {},
    }

    st.blksize = @intCast(inode.parent.super_block.block_size);

    st.uid = try getId(inode.parent, inode.internal.base.uid);
    st.gid = try getId(inode.parent, inode.internal.base.guid);

    return st;
}

pub fn iterate(self: *Inode) !Iterator {
    // TODO: add offset
    const dir = try SquashFs.Dir.initFromInode(
        self.parent,
        self,
    );

    return .{
        .dir = self.*,
        .internal = dir,
        .parent = self.parent,
    };
}

pub const Iterator = struct {
    dir: Inode,
    internal: SquashFs.Dir,
    parent: *SquashFs,
    // SquashFS has max name length of 256. Add another byte for null
    name_buf: [257]u8 = undefined,

    pub const Entry = struct {
        id: Inode.TableEntry,
        parent: *SquashFs,

        name: [:0]const u8,
        kind: SquashFs.File.Kind,

        pub inline fn inode(self: *const Entry) Inode {
            // This should never fail
            // if it does, something went very wrong (like messing with
            // the inode ID)
            return SquashFs.getInode(
                self.parent,
                self.id,
            ) catch unreachable;
        }
    };

    /// Returns an entry for the next inode in the directory
    pub fn next(self: *Iterator) !?Entry {
        var iterator = SquashFs.Dir.IteratorOld{
            .name_buf = &self.name_buf,
            .sqfs = self.parent,
            .dir = &self.internal,
        };

        const sqfs_dir_entry = try iterator.next() orelse return null;

        self.name_buf[sqfs_dir_entry.name.len] = '\x00';

        return .{
            .id = sqfs_dir_entry.inode,
            .name = self.name_buf[0..sqfs_dir_entry.name.len :0],
            .kind = sqfs_dir_entry.kind,
            .parent = self.parent,
        };
    }
};

pub fn walk(self: *Inode, allocator: std.mem.Allocator) !Walker {
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
        iter: Inode.Iterator,
        dirname_len: usize,
    };

    pub const Entry = struct {
        id: Inode.TableEntry,
        parent: *SquashFs,

        dir: Inode,
        kind: SquashFs.File.Kind,
        path: [:0]const u8,
        basename: []const u8,

        pub inline fn inode(self: *const Entry) Inode {
            return SquashFs.getInode(
                self.parent,
                self.id,
            ) catch unreachable;
        }
    };

    // Copied and slightly modified from Zig stdlib
    // <https://github.com/ziglang/zig/blob/master/lib/std/fs.zig>
    pub fn next(self: *Walker) !?Entry {
        while (self.stack.items.len != 0) {
            // `top` and `containing` become invalid after appending to `self.stack`
            var top = &self.stack.items[self.stack.items.len - 1];
            var containing = top;
            var dirname_len = top.dirname_len;

            if (try top.iter.next()) |entry| {
                self.name_buffer.shrinkRetainingCapacity(dirname_len);

                if (self.name_buffer.items.len != 0) {
                    try self.name_buffer.append(fs.path.sep);
                    dirname_len += 1;
                }

                try self.name_buffer.appendSlice(entry.name);

                if (entry.kind == .directory) {
                    var new_dir = entry.inode();

                    {
                        try self.stack.append(StackItem{
                            .iter = try new_dir.iterate(),
                            .dirname_len = self.name_buffer.items.len,
                        });
                        top = &self.stack.items[self.stack.items.len - 1];
                        containing = &self.stack.items[self.stack.items.len - 2];
                    }
                }

                try self.name_buffer.append('\x00');

                const path = self.name_buffer.items[0 .. self.name_buffer.items.len - 1 :0];
                const basename = self.name_buffer.items[dirname_len .. self.name_buffer.items.len - 1 :0];

                return .{
                    .dir = containing.iter.dir,
                    .basename = basename,
                    .id = entry.id,
                    .parent = entry.parent,
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

/// Extracts an inode from the SquashFS image to `dest` using the buffer
pub fn extract(self: *Inode, buf: []u8, dest: []const u8) !void {
    const cwd = fs.cwd();

    switch (self.kind) {
        .file => {
            var f = try cwd.createFile(dest, .{});
            defer f.close();

            var off: usize = 0;
            const fsize: u64 = self.internal.xtra.reg.size;

            while (off < fsize) {
                const read_bytes = try self.read(buf);
                off += read_bytes;

                _ = try f.write(buf[0..read_bytes]);
            }

            // Change the mode of the file to match the inode contained
            // in the SquashFS image
            if (std.fs.has_executable_bit) {
                const st = try self.stat();
                try f.chmod(st.mode);
            }
        },

        .directory => {
            try cwd.makeDir(dest);
            // TODO: Why does this cause BADF?
            if (false and std.fs.has_executable_bit) {
                var d = try cwd.openDir(dest, .{});
                defer d.close();

                const st = try self.stat();
                try d.chmod(st.mode);
            }
        },

        .sym_link => {
            var link_target_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

            const link_target = try self.readLink(&link_target_buf);

            // TODO: check if dir
            // TODO: why does it make a difference? squashfuse appears
            // to just call `symlink` on the target
            try cwd.symLink(
                link_target,
                dest,
                .{ .is_directory = false },
            );
        },

        .block_device, .character_device => {
            const dev = self.internal.xtra.dev;

            var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const path = try std.fmt.bufPrintZ(&path_buf, "{s}", .{dest});

            _ = std.os.linux.mknod(path, dev.major(), dev.minor());
        },

        // TODO: implement for other types
        else => {
            var panic_buf: [256]u8 = undefined;

            const panic_str = try std.fmt.bufPrint(
                &panic_buf,
                "Inode.extract not yet implemented for file type `{s}`",
                .{@tagName(self.kind)},
            );

            @panic(panic_str);
        },
    }
}
