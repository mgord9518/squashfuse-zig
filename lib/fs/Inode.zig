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
const metadata = squashfuse.metadata;
const SquashFs = squashfuse.SquashFs;
const SuperBlock = SquashFs.SuperBlock;

const Inode = @This();

parent: *SquashFs,
kind: SquashFs.File.Kind,
pos: u64 = 0,

base: SquashFs.SuperBlock.InodeBase,
xattr: u32,
next: metadata.Cursor,

xtra: union(enum) {
    reg: SuperBlock.LFileInode,
    dev: SuperBlock.LDevInode,
    symlink: SuperBlock.SymLinkInode,
    dir: SuperBlock.LDirInode,
    nlink: u32,
},

pub const TableEntry = packed struct(u64) {
    offset: u16,
    block: u32,
    _: u16 = 0,
};

/// Reads the link target into `buf`
pub fn readLink(inode: *Inode, buf: []u8) ![]const u8 {
    if (inode.kind != .sym_link) {
        // TODO: rename
        return error.NotLink;
    }

    const len = inode.xtra.symlink.size;

    if (len > buf.len) {
        return error.NoSpaceLeft;
    }

    var cur = inode.next;

    _ = try cur.read(buf[0..len]);

    return buf[0..len];
}

pub fn readLinkZ(self: *Inode, buf: []u8) ![:0]const u8 {
    const link_target = try self.readLink(buf[0 .. buf.len - 1]);
    buf[link_target.len] = '\x00';

    return buf[0..link_target.len :0];
}

fn getId(sqfs: *SquashFs, idx: u16) !u32 {
    const id = try sqfs.id_table.get(idx);

    return std.mem.littleToNative(
        u32,
        id,
    );
}

pub fn stat(inode: *Inode) !fs.File.Stat {
    const mtime = @as(i128, inode.base.mtime) * std.time.ns_per_s;

    // zig fmt: off
    const mode = inode.base.mode | @as(std.posix.mode_t, switch (inode.kind) {
        .file         => S.IFREG,
        .directory    => S.IFDIR,
        .sym_link     => S.IFLNK,
        .named_pipe   => S.IFIFO,
        .block_device => S.IFBLK,
        .character_device   => S.IFCHR,
        .unix_domain_socket => S.IFSOCK,
        else => 0,
    });
    // zig fmt: on

    return .{
        // TODO
        .inode = 0,
        .size = switch (inode.kind) {
            .file => inode.xtra.reg.size,
            .sym_link => inode.xtra.symlink.size,
            .directory => inode.xtra.dir.size,
            else => 0,
        },

        // Only exists on posix platforms
        .mode = if (fs.File.Mode == u0) 0 else mode,

        .kind = switch (inode.kind) {
            .block_device => .block_device,
            .character_device => .character_device,
            .directory => .directory,
            .named_pipe => .named_pipe,
            .sym_link => .sym_link,
            .file => .file,
            .unix_domain_socket => .unix_domain_socket,

            else => .unknown,
        },

        .atime = mtime,
        .ctime = mtime,
        .mtime = mtime,
    };
}

// Like `Inode.stat` but returns the OS native stat format
pub fn statC(inode: *Inode) !Stat {
    var st = std.mem.zeroes(Stat);

    // zig fmt: off
    st.mode = inode.base.mode | @as(u32, switch (inode.kind) {
        .file         => S.IFREG,
        .directory    => S.IFDIR,
        .sym_link     => S.IFLNK,
        .named_pipe   => S.IFIFO,
        .block_device => S.IFBLK,
        .character_device   => S.IFCHR,
        .unix_domain_socket => S.IFSOCK,
        else => 0,
    });
    // zig fmt: on

    //st.nlink = @intCast(inode.nlink);
    st.nlink = switch (inode.xtra) {
        .reg => |reg| reg.nlink,
        .dir => |dir| dir.nlink,
        .dev => |dev| dev.nlink,
        .nlink => |nlink| nlink,

        else => 1,
    };

    st.atim.tv_sec = @intCast(inode.base.mtime);
    st.ctim.tv_sec = @intCast(inode.base.mtime);
    st.mtim.tv_sec = @intCast(inode.base.mtime);

    switch (inode.kind) {
        .file => {
            st.size = @intCast(inode.xtra.reg.size);
            st.blocks = @divTrunc(st.size, 512);
        },
        .block_device, .character_device => {
            st.rdev = @as(u32, @bitCast(inode.xtra.dev.dev));
        },
        .sym_link => {
            st.size = @intCast(inode.xtra.symlink.size);
        },
        else => {},
    }

    st.blksize = @intCast(inode.parent.super_block.block_size);

    st.uid = try getId(inode.parent, inode.base.uid);
    st.gid = try getId(inode.parent, inode.base.guid);

    return st;
}

/// Extracts an inode from the SquashFS image to `dest` using the buffer
pub fn extract(self: *Inode, dest: []const u8) !void {
    const cwd = fs.cwd();

    switch (self.kind) {
        .file => {
            var f = try cwd.createFile(dest, .{});
            defer f.close();

            var file = SquashFs.File.initFromInode(self.*);

            const fsize: u64 = self.xtra.reg.size;

            while (file.pos < fsize) {
                const block = try file.preadNoCopy(file.pos);
                _ = try f.write(block);
                file.pos += block.len;
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
            const dev = self.xtra.dev;

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
