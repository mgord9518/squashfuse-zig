// Minimal FUSE wrapper

const std = @import("std");
const os = std.os;
const linux = os.linux;

const c = @cImport({
    @cInclude("fuse.h");
});

pub const FuseError = error{
    InvalidArgument,
    NoMountPoint,
    SetupFailed,
    MountFailed,
    DaemonizeFailed,
    SignalHandlerFailed,
    FileSystemError,
    UnknownError,
};

pub fn FuseErrorFromInt(err: c_int) FuseError!void {
    return switch (err) {
        0 => {},
        1 => FuseError.InvalidArgument,
        2 => FuseError.NoMountPoint,
        3 => FuseError.SetupFailed,
        4 => FuseError.MountFailed,
        5 => FuseError.DaemonizeFailed,
        6 => FuseError.SignalHandlerFailed,
        7 => FuseError.FileSystemError,

        else => FuseError.UnknownError,
    };
}

// TODO: specific to fuse operation
pub const MountError = error{
    NoEntry,
    Io,
    BadFd,
    OutOfMemory,
    PermissionDenied,
    Busy,
    FileExists,
    NotDir,
    IsDir,
    InvalidArgument,
    FTableOverflow,
    TooManyFiles,
    ExecBusy,
    FileTooLarge,
    ReadOnly,
};

pub fn MountErrorToEnum(err: MountError) E {
    return switch (err) {
        MountError.NoEntry => .no_entry,
        MountError.Io => .io,
        MountError.BadFd => .bad_fd,
        MountError.OutOfMemory => .out_of_memory,
        MountError.PermissionDenied => .permission_denied,
        MountError.Busy => .busy,
        MountError.FileExists => .file_exists,
        MountError.NotDir => .not_dir,
        MountError.IsDir => .is_dir,
        MountError.InvalidArgument => .invalid_argument,
        MountError.FTableOverflow => .ftable_overflow,
        MountError.TooManyFiles => .too_many_files,
        MountError.ExecBusy => .exec_busy,
        MountError.FileTooLarge => .file_too_large,
        MountError.ReadOnly => .read_only,
    };
}

extern fn fuse_main_real(argc: c_int, argv: [*]const [*:0]const u8, op: *const OldOperations, op_size: usize, private_data: *const anyopaque) c_int;
pub fn old_main(allocator: std.mem.Allocator, args: []const [:0]const u8, op: *const OldOperations, private_data: anytype) !void {
    var result = try allocator.alloc([*:0]const u8, args.len);
    defer allocator.free(result);

    // Iterate through the slice and convert it to a C char**
    for (args, 0..) |arg, idx| {
        result[idx] = arg.ptr;
    }

    const argc: c_int = @intCast(args.len);
    const op_len = @sizeOf(OldOperations);
    const data_ptr: *const anyopaque = @ptrCast(&private_data);

    const err = fuse_main_real(argc, result.ptr, op, op_len, data_ptr);
    try FuseErrorFromInt(err);
}

pub fn main(allocator: std.mem.Allocator, args: []const [:0]const u8, comptime operations: Operations, private_data: anytype) !void {
    const libfuse_ops = genOps(operations);

    try old_main(allocator, args, &libfuse_ops, private_data);
}

// TODO: add all operations
pub const Operations = struct {
    //    real_opt: Operations,
    open: ?fn (
        path: [:0]const u8,
        fi: *FileInfo,
    ) MountError!void = null,

    readdir: ?fn (
        path: [:0]const u8,
        fd: FillDir,
        fi: *FileInfo,
        flags: ReadDirFlags,
    ) MountError!void = null,

    getattr: ?fn (
        path: [:0]const u8,
        fi: *FileInfo,
    ) MountError!os.Stat = null,

    read: ?fn (
        path: [:0]const u8,
        buf: []u8,
        offset: u64,
        fi: *FileInfo,
    ) MountError!usize = null,

    create: ?fn (
        path: [:0]const u8,
        mode: std.fs.File.Mode,
        fi: *FileInfo,
    ) MountError!void = null,

    readlink: ?fn (
        path: [:0]const u8,
        buf: []u8,
    ) MountError![]const u8 = null,

    getxattr: ?fn (
        path: [:0]const u8,
        name: [:0]const u8,
        buf: []u8,
    ) MountError!void = null,

    opendir: ?fn (
        path: [:0]const u8,
        fi: *FileInfo,
    ) MountError!void = null,

    release: ?fn (
        path: [:0]const u8,
        fi: *FileInfo,
    ) MountError!void = null,

    releasedir: ?fn (
        path: [:0]const u8,
        fi: *FileInfo,
    ) MountError!void = null,
};

pub fn genOps(
    comptime new_ops: Operations,
) OldOperations {
    var ops = OldOperations{};

    // TODO: refactor
    if (new_ops.readdir) |readdir| {
        ops.readdir = struct {
            pub fn fuse_readdir(path: [*:0]const u8, fd: FillDir, off: linux.off_t, fi: *FileInfo, flags: ReadDirFlags) callconv(.C) E {
                const path_slice = std.mem.sliceTo(path, 0);

                _ = off;

                readdir(path_slice, fd, fi, flags) catch |err| {
                    return MountErrorToEnum(err);
                };

                return .success;
            }
        }.fuse_readdir;
    }

    if (new_ops.open) |opene| {
        ops.open = struct {
            pub fn fuse_open(path: [*:0]const u8, fi: *FileInfo) callconv(.C) E {
                const path_slice = std.mem.sliceTo(path, 0);

                opene(path_slice, fi) catch |err| {
                    return MountErrorToEnum(err);
                };

                return .success;
            }
        }.fuse_open;
    }

    if (new_ops.getattr) |getattr| {
        ops.getattr = struct {
            pub fn fuse_getattr(path: [*:0]const u8, stbuf: *os.Stat, fi: *FileInfo) callconv(.C) E {
                const path_slice = std.mem.sliceTo(path, 0);

                stbuf.* = getattr(path_slice, fi) catch |err| {
                    return MountErrorToEnum(err);
                };

                return .success;
            }
        }.fuse_getattr;
    }

    if (new_ops.read) |read| {
        ops.read = struct {
            pub fn fuse_read(path: [*:0]const u8, b: [*]u8, len: usize, offset: os.off_t, fi: *FileInfo) callconv(.C) c_int {
                const path_slice = std.mem.sliceTo(path, 0);

                const bytes_read = read(path_slice, b[0..len], @intCast(offset), fi) catch |err| {
                    return @intFromEnum(MountErrorToEnum(err));
                };

                return @intCast(bytes_read);
            }
        }.fuse_read;
    }

    if (new_ops.create) |create| {
        ops.create = struct {
            pub fn fuse_create(path: [*:0]const u8, mode: std.fs.File.Mode, fi: *FileInfo) callconv(.C) E {
                const path_slice = std.mem.sliceTo(path, 0);

                create(path_slice, mode, fi) catch |err| {
                    return MountErrorToEnum(err);
                };

                return .success;
            }
        }.fuse_create;
    }

    if (new_ops.readlink) |readlink| {
        ops.readlink = struct {
            pub fn fuse_readlink(path: [*:0]const u8, buf: [*]u8, len: usize) callconv(.C) E {
                const path_slice = std.mem.sliceTo(path, 0);

                const link_target = readlink(path_slice, buf[0..len]) catch |err| {
                    return MountErrorToEnum(err);
                };

                buf[link_target.len] = '\x00';

                return .success;
            }
        }.fuse_readlink;
    }

    if (new_ops.getxattr) |getxattr| {
        ops.getxattr = struct {
            pub fn fuse_getxattr(path: [*:0]const u8, name: [*:0]const u8, buf: [*]u8, len: usize) callconv(.C) E {
                const path_slice = std.mem.sliceTo(path, 0);
                const name_slice = std.mem.sliceTo(name, 0);

                getxattr(path_slice, name_slice, buf[0..len]) catch |err| {
                    return MountErrorToEnum(err);
                };

                return .success;
            }
        }.fuse_getxattr;
    }

    if (new_ops.opendir) |opendir| {
        ops.opendir = struct {
            pub fn fuse_opendir(path: [*:0]const u8, fi: *FileInfo) callconv(.C) E {
                const path_slice = std.mem.sliceTo(path, 0);

                opendir(path_slice, fi) catch |err| {
                    return MountErrorToEnum(err);
                };

                return .success;
            }
        }.fuse_opendir;
    }

    if (new_ops.release) |release| {
        ops.release = struct {
            pub fn fuse_release(path: [*:0]const u8, fi: *FileInfo) callconv(.C) E {
                const path_slice = std.mem.sliceTo(path, 0);

                release(path_slice, fi) catch |err| {
                    return MountErrorToEnum(err);
                };

                return .success;
            }
        }.fuse_release;
    }

    if (new_ops.releasedir) |releasedir| {
        ops.releasedir = struct {
            pub fn fuse_releasedir(path: [*:0]const u8, fi: *FileInfo) callconv(.C) E {
                const path_slice = std.mem.sliceTo(path, 0);

                releasedir(path_slice, fi) catch |err| {
                    return MountErrorToEnum(err);
                };

                return .success;
            }
        }.fuse_releasedir;
    }

    return ops;
}

pub inline fn context() *Context {
    return c.fuse_get_context();
}

// Convenience function to fetch FUSE private data without casting
pub inline fn privateDataAs(comptime T: type) T {
    return @as(*T, @ptrCast(@alignCast(context().private_data))).*;
}

pub const ReadDirFlags = c.fuse_readdir_flags;
pub const ConnectionInfo = c.fuse_conn_info;
pub const Config = c.fuse_config;
pub const Context = c.fuse_context;
pub const PollHandle = c.fuse_pollhandle;
pub const BufVec = c.fuse_bufvec;

pub const StatVfs = c.struct_statvfs;

pub const FillDir = packed struct {
    buf: *anyopaque,
    internal: *const fn (*anyopaque, [*:0]const u8, ?*const os.Stat, linux.off_t, Flags) callconv(.C) c_int,

    pub const Flags = enum(c_int) {
        normal = 0,
        plus = 2,
    };

    // Adds an entry to the filldir
    // This should be used if adding the entire directory with a single call to
    // the readdir implementation
    pub fn add(self: *const FillDir, name: [*:0]const u8, st: ?*const os.Stat) MountError!void {
        try self.addEx(name, st, .normal);
    }

    pub fn addEx(self: *const FillDir, name: [*:0]const u8, st: ?*const os.Stat, flags: Flags) MountError!void {
        // TODO: error handling
        //const ret = self.internal(self.buf, name, st, 0, flags);
        _ = self.internal(self.buf, name, st, 0, flags);
    }

    // Adds an entry to the filldir
    // This should be used if adding entries to readdir are done one by one
    pub fn addWithOffset(self: *const FillDir, name: [*:0]const u8, st: ?*const os.Stat) bool {
        try self.addWithOffsetEx(name, st, .normal);
    }

    pub fn addWithOffsetEx(self: *const FillDir, name: [*:0]const u8, st: ?*const os.Stat, flags: Flags) bool {
        _ = self.internal(self.buf, name, st, self.off, flags);
    }
};

pub const FileInfo = packed struct {
    flags: c_int,
    write_page: bool,
    direct_io: bool,
    keep_cache: bool,
    flush: bool,
    nonseekable: bool,
    cache_readdir: bool,
    no_flush: bool,
    padding: u24,
    handle: u64,
    lock_owner: u64,
    poll_events: u32,
};

pub const RenameFlags = enum(c_uint) {
    // Defined in /usr/include/linux/fs.h
    no_replace = 1,
    exchange = 2,
};

pub const LockFlags = enum(c_int) {
    // Defined in /usr/include/asm-generic/fcntl.h
    get_lock = 5,
    set_lock = 6,
    set_lock_wait = 7,
};

pub const OldOperations = extern struct {
    getattr: ?*const fn ([*:0]const u8, *os.Stat, *FileInfo) callconv(.C) E = null,
    readlink: ?*const fn ([*:0]const u8, [*]u8, usize) callconv(.C) E = null,
    mknod: ?*const fn ([*:0]const u8, linux.mode_t, linux.dev_t) callconv(.C) E = null,
    mkdir: ?*const fn ([*:0]const u8, linux.mode_t) callconv(.C) E = null,
    unlink: ?*const fn ([*:0]const u8) callconv(.C) E = null,
    rmdir: ?*const fn ([*:0]const u8) callconv(.C) E = null,
    symlink: ?*const fn ([*:0]const u8, [*:0]const u8) callconv(.C) E = null,
    rename: ?*const fn ([*:0]const u8, [*:0]const u8, RenameFlags) callconv(.C) E = null,
    link: ?*const fn ([*:0]const u8, [*:0]const u8) callconv(.C) E = null,
    chmod: ?*const fn ([*:0]const u8, linux.mode_t, *FileInfo) callconv(.C) E = null,
    chown: ?*const fn ([*:0]const u8, linux.uid_t, linux.gid_t, *FileInfo) callconv(.C) E = null,
    truncate: ?*const fn ([*:0]const u8, linux.off_t, *FileInfo) callconv(.C) E = null,
    open: ?*const fn ([*:0]const u8, *FileInfo) callconv(.C) E = null,
    read: ?*const fn ([*:0]const u8, [*]u8, usize, linux.off_t, *FileInfo) callconv(.C) c_int = null,
    //read: ?*const fn ([*:0]const u8, []u8, linux.off_t, *FileInfo) c_int = null,
    write: ?*const fn ([*:0]const u8, [*]const u8, usize, linux.off_t, *FileInfo) callconv(.C) c_int = null,
    statfs: ?*const fn ([*:0]const u8, *StatVfs) callconv(.C) E = null,
    flush: ?*const fn ([*:0]const u8, *FileInfo) callconv(.C) E = null,
    release: ?*const fn ([*:0]const u8, *FileInfo) callconv(.C) E = null,
    fsync: ?*const fn ([*:0]const u8, c_int, *FileInfo) callconv(.C) E = null,

    setxattr: ?*const fn ([*:0]const u8, [*:0]const u8, [*]const u8, usize, c_int) callconv(.C) E = null,
    getxattr: ?*const fn ([*:0]const u8, [*:0]const u8, [*]u8, usize) callconv(.C) E = null,
    listxattr: ?*const fn ([*:0]const u8, [*]u8, usize) callconv(.C) E = null,

    removexattr: ?*const fn ([*:0]const u8, [*:0]const u8) callconv(.C) E = null,
    opendir: ?*const fn ([*:0]const u8, *FileInfo) callconv(.C) E = null,
    readdir: ?*const fn ([*:0]const u8, FillDir, linux.off_t, *FileInfo, ReadDirFlags) callconv(.C) E = null,

    releasedir: ?*const fn ([*:0]const u8, *FileInfo) callconv(.C) E = null,
    fsyncdir: ?*const fn ([*:0]const u8, c_int, *FileInfo) callconv(.C) E = null,
    access: ?*const fn ([*:0]const u8, c_int) callconv(.C) E = null,
    init: ?*const fn (*ConnectionInfo, *Config) callconv(.C) ?*anyopaque = null,

    destroy: ?*const fn (*anyopaque) callconv(.C) void = null,
    create: ?*const fn ([*:0]const u8, linux.mode_t, *FileInfo) callconv(.C) E = null,
    lock: ?*const fn ([*:0]const u8, *FileInfo, LockFlags, *linux.Flock) callconv(.C) c_int = null,
    utimens: ?*const fn ([*:0]const u8, *const [2]linux.timespec, *FileInfo) callconv(.C) c_int = null,
    bmap: ?*const fn ([*:0]const u8, usize, *u64) callconv(.C) c_int = null,

    ioctl: ?*const fn ([*:0]const u8, c_int, *anyopaque, *FileInfo, c_uint, *anyopaque) callconv(.C) c_int = null,
    poll: ?*const fn ([*:0]const u8, *FileInfo, *PollHandle, *c_uint) callconv(.C) c_int = null,
    write_buf: ?*const fn ([*:0]const u8, *BufVec, linux.off_t, *FileInfo) callconv(.C) c_int = null,
    read_buf: ?*const fn ([*:0]const u8, [*c][*c]BufVec, usize, linux.off_t, *FileInfo) callconv(.C) c_int = null,
    flock: ?*const fn ([*:0]const u8, *FileInfo, c_int) callconv(.C) c_int = null,
    fallocate: ?*const fn ([*:0]const u8, c_int, linux.off_t, linux.off_t, *FileInfo) callconv(.C) c_int = null,
    copy_file_range: ?*const fn ([*:0]const u8, *FileInfo, linux.off_t, [*:0]const u8, *FileInfo, linux.off_t, usize, c_int) callconv(.C) isize = null,
    lseek: ?*const fn ([*:0]const u8, linux.off_t, c_int, *FileInfo) callconv(.C) linux.off_t = null,
};

// FUSE uses negated values of system errno
// Debating on whether they should match the C enum or follow Zig naming
// conventions
pub const E = enum(c_int) {
    success = 0,
    no_entry = -@as(c_int, @intCast(@intFromEnum(std.os.E.NOENT))),
    io = -@as(c_int, @intCast(@intFromEnum(std.os.E.IO))),
    bad_fd = -@as(c_int, @intCast(@intFromEnum(std.os.E.BADF))),
    out_of_memory = -@as(c_int, @intCast(@intFromEnum(std.os.E.NOMEM))),
    permission_denied = -@as(c_int, @intCast(@intFromEnum(std.os.E.ACCES))),
    busy = -@as(c_int, @intCast(@intFromEnum(std.os.E.BUSY))),
    file_exists = -@as(c_int, @intCast(@intFromEnum(std.os.E.EXIST))),
    not_dir = -@as(c_int, @intCast(@intFromEnum(std.os.E.NOTDIR))),
    is_dir = -@as(c_int, @intCast(@intFromEnum(std.os.E.ISDIR))),
    invalid_argument = -@as(c_int, @intCast(@intFromEnum(std.os.E.INVAL))),
    ftable_overflow = -@as(c_int, @intCast(@intFromEnum(std.os.E.NFILE))),
    too_many_files = -@as(c_int, @intCast(@intFromEnum(std.os.E.MFILE))),
    exec_busy = -@as(c_int, @intCast(@intFromEnum(std.os.E.TXTBSY))),
    file_too_large = -@as(c_int, @intCast(@intFromEnum(std.os.E.FBIG))),
    read_only = -@as(c_int, @intCast(@intFromEnum(std.os.E.ROFS))),
};

//pub const E = enum(c_int) {
//    SUCCESS = 0,
//    NOENT = -@intCast(c_int, @intFromEnum(std.os.E.NOENT)),
//    IO = -@intCast(c_int, @intFromEnum(std.os.E.IO)),
//    BADF = -@intCast(c_int, @intFromEnum(std.os.E.BADF)),
//    NOMEM = -@intCast(c_int, @intFromEnum(std.os.E.NOMEM)),
//    ACCES = -@intCast(c_int, @intFromEnum(std.os.E.ACCES)),
//    BUSY = -@intCast(c_int, @intFromEnum(std.os.E.BUSY)),
//    EXIST = -@intCast(c_int, @intFromEnum(std.os.E.EXIST)),
//    NOTDIR = -@intCast(c_int, @intFromEnum(std.os.E.NOTDIR)),
//    ISDIR = -@intCast(c_int, @intFromEnum(std.os.E.ISDIR)),
//    INVAL = -@intCast(c_int, @intFromEnum(std.os.E.INVAL)),
//    NFILE = -@intCast(c_int, @intFromEnum(std.os.E.NFILE)),
//    MFILE = -@intCast(c_int, @intFromEnum(std.os.E.MFILE)),
//    TXTBSY = -@intCast(c_int, @intFromEnum(std.os.E.TXTBSY)),
//    FBIG = -@intCast(c_int, @intFromEnum(std.os.E.FBIG)),
//    ROFS = -@intCast(c_int, @intFromEnum(std.os.E.ROFS)),
//};
