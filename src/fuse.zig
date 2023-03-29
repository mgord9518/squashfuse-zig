// Minimal FUSE wrapper

const std = @import("std");
const os = std.os;
const linux = os.linux;

const c = @cImport({
    @cDefine("_FILE_OFFSET_BITS", "64"); // Required for FUSE
    @cDefine("FUSE_USE_VERSION", "30");
    @cInclude("fuse3/fuse.h");
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

extern fn fuse_main_real(argc: c_int, argv: [*]const [*:0]const u8, op: *const Operations, op_size: usize, private_data: *const anyopaque) c_int;
pub fn main(allocator: std.mem.Allocator, args: []const [:0]const u8, op: *const Operations, private_data: anytype) !void {
    var result = try allocator.alloc([*:0]const u8, args.len);

    // Iterate through the slice and convert it to a C char**
    for (args, 0..) |arg, idx| {
        result[idx] = arg.ptr;
    }

    const argc = @intCast(c_int, args.len);
    const op_len = @sizeOf(Operations);
    const data_ptr = @ptrCast(*const anyopaque, &private_data);

    const err = fuse_main_real(argc, result.ptr, op, op_len, data_ptr);
    try FuseErrorFromInt(err);
}

pub inline fn context() *Context {
    return c.fuse_get_context();
}

// Convenience function to fetch FUSE private data without casting
pub inline fn privateDataAs(comptime T: type) T {
    return @ptrCast(*T, @alignCast(@alignOf(T), context().private_data)).*;
}

pub const ReadDirFlags = c.fuse_readdir_flags;
pub const ConnectionInfo = c.fuse_conn_info;
pub const Config = c.fuse_config;
pub const Context = c.fuse_context;
pub const PollHandle = c.fuse_pollhandle;
pub const BufVec = c.fuse_bufvec;

pub const StatVfs = c.struct_statvfs;

// Not sure how safe this is yet
// This creates a struct
pub const FillDir = packed struct {
    buf: *anyopaque,
    internal: *const fn (*anyopaque, [*:0]const u8, ?*const os.Stat, linux.off_t, Flags) callconv(.C) c_int,
    off: linux.off_t,

    pub const Flags = enum(c_int) {
        normal = 0,
        plus = 2,
    };

    // Adds an entry to the filldir
    // This should be used if adding the entire directory with a single call to
    // the readdir implementation
    pub fn add(self: *const FillDir, name: [*:0]const u8, st: ?*const os.Stat) !void {
        try self.addEx(name, st, .normal);
    }

    pub fn addEx(self: *const FillDir, name: [*:0]const u8, st: ?*const os.Stat, flags: Flags) !void {
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

pub const Operations = extern struct {
    getattr: ?*const fn ([*:0]const u8, *os.Stat, *FileInfo) E = null,
    readlink: ?*const fn ([*:0]const u8, []u8) E = null,
    mknod: ?*const fn ([*:0]const u8, linux.mode_t, linux.dev_t) E = null,
    mkdir: ?*const fn ([*:0]const u8, linux.mode_t) E = null,
    unlink: ?*const fn ([*:0]const u8) E = null,
    rmdir: ?*const fn ([*:0]const u8) E = null,
    symlink: ?*const fn ([*:0]const u8, [*:0]const u8) E = null,
    rename: ?*const fn ([*:0]const u8, [*:0]const u8, RenameFlags) E = null,
    link: ?*const fn ([*:0]const u8, [*:0]const u8) E = null,
    chmod: ?*const fn ([*:0]const u8, linux.mode_t, *FileInfo) E = null,
    chown: ?*const fn ([*:0]const u8, linux.uid_t, linux.gid_t, *FileInfo) E = null,
    truncate: ?*const fn ([*:0]const u8, linux.off_t, *FileInfo) E = null,
    open: ?*const fn ([*:0]const u8, *FileInfo) E = null,
    //read: ?*const fn ([*:0]const u8, [*]u8, usize, linux.off_t, *FileInfo) callconv(.C) c_int = null,
    read: ?*const fn ([*:0]const u8, []u8, linux.off_t, *FileInfo) c_int = null,
    write: ?*const fn ([*:0]const u8, []const u8, linux.off_t, *FileInfo) c_int = null,
    statfs: ?*const fn ([*:0]const u8, *StatVfs) E = null,
    flush: ?*const fn ([*:0]const u8, *FileInfo) E = null,
    release: ?*const fn ([*:0]const u8, *FileInfo) E = null,
    fsync: ?*const fn ([*:0]const u8, c_int, *FileInfo) E = null,

    setxattr: ?*const fn ([*:0]const u8, [*:0]const u8, []const u8, c_int) E = null,
    getxattr: ?*const fn ([*:0]const u8, [*:0]const u8, []u8) E = null,
    listxattr: ?*const fn ([*:0]const u8, []u8) E = null,

    removexattr: ?*const fn ([*:0]const u8, [*:0]const u8) E = null,
    opendir: ?*const fn ([*:0]const u8, *FileInfo) E = null,
    readdir: ?*const fn ([*:0]const u8, FillDir, *FileInfo, ReadDirFlags) E = null,

    releasedir: ?*const fn ([*:0]const u8, *FileInfo) E = null,
    fsyncdir: ?*const fn ([*:0]const u8, c_int, *FileInfo) E = null,
    access: ?*const fn ([*:0]const u8, c_int) E = null,
    init: ?*const fn (*ConnectionInfo, *Config) ?*anyopaque = null,

    destroy: ?*const fn (*anyopaque) void = null,
    create: ?*const fn ([*:0]const u8, linux.mode_t, *FileInfo) E = null,
    lock: ?*const fn ([*:0]const u8, *FileInfo, LockFlags, *linux.Flock) c_int = null,
    utimens: ?*const fn ([*:0]const u8, *const [2]linux.timespec, *FileInfo) c_int = null,
    bmap: ?*const fn ([*:0]const u8, usize, *u64) c_int = null,

    ioctl: ?*const fn ([*:0]const u8, c_int, *anyopaque, *FileInfo, c_uint, *anyopaque) c_int = null,
    poll: ?*const fn ([*:0]const u8, *FileInfo, *PollHandle, *c_uint) c_int = null,
    write_buf: ?*const fn ([*:0]const u8, *BufVec, linux.off_t, *FileInfo) c_int = null,
    read_buf: ?*const fn ([*:0]const u8, [*c][*c]BufVec, usize, linux.off_t, *FileInfo) c_int = null,
    flock: ?*const fn ([*:0]const u8, *FileInfo, c_int) c_int = null,
    fallocate: ?*const fn ([*:0]const u8, c_int, linux.off_t, linux.off_t, *FileInfo) c_int = null,
    copy_file_range: ?*const fn ([*:0]const u8, *FileInfo, linux.off_t, [*:0]const u8, *FileInfo, linux.off_t, usize, c_int) isize = null,
    lseek: ?*const fn ([*:0]const u8, linux.off_t, c_int, *FileInfo) linux.off_t = null,
};

// FUSE uses negated values of system errno
// Debating on whether they should match the C enum or follow Zig naming
// conventions
pub const E = enum(c_int) {
    success = 0,
    no_entry = -@intCast(c_int, @enumToInt(std.os.E.NOENT)),
    io = -@intCast(c_int, @enumToInt(std.os.E.IO)),
    bad_fd = -@intCast(c_int, @enumToInt(std.os.E.BADF)),
    out_of_memory = -@intCast(c_int, @enumToInt(std.os.E.NOMEM)),
    permission_denied = -@intCast(c_int, @enumToInt(std.os.E.ACCES)),
    busy = -@intCast(c_int, @enumToInt(std.os.E.BUSY)),
    file_exists = -@intCast(c_int, @enumToInt(std.os.E.EXIST)),
    not_dir = -@intCast(c_int, @enumToInt(std.os.E.NOTDIR)),
    is_dir = -@intCast(c_int, @enumToInt(std.os.E.ISDIR)),
    invalid_argument = -@intCast(c_int, @enumToInt(std.os.E.INVAL)),
    ftable_overflow = -@intCast(c_int, @enumToInt(std.os.E.NFILE)),
    too_many_files = -@intCast(c_int, @enumToInt(std.os.E.MFILE)),
    exec_busy = -@intCast(c_int, @enumToInt(std.os.E.TXTBSY)),
    file_too_large = -@intCast(c_int, @enumToInt(std.os.E.FBIG)),
    read_only = -@intCast(c_int, @enumToInt(std.os.E.ROFS)),
};

//pub const E = enum(c_int) {
//    SUCCESS = 0,
//    NOENT = -@intCast(c_int, @enumToInt(std.os.E.NOENT)),
//    IO = -@intCast(c_int, @enumToInt(std.os.E.IO)),
//    BADF = -@intCast(c_int, @enumToInt(std.os.E.BADF)),
//    NOMEM = -@intCast(c_int, @enumToInt(std.os.E.NOMEM)),
//    ACCES = -@intCast(c_int, @enumToInt(std.os.E.ACCES)),
//    BUSY = -@intCast(c_int, @enumToInt(std.os.E.BUSY)),
//    EXIST = -@intCast(c_int, @enumToInt(std.os.E.EXIST)),
//    NOTDIR = -@intCast(c_int, @enumToInt(std.os.E.NOTDIR)),
//    ISDIR = -@intCast(c_int, @enumToInt(std.os.E.ISDIR)),
//    INVAL = -@intCast(c_int, @enumToInt(std.os.E.INVAL)),
//    NFILE = -@intCast(c_int, @enumToInt(std.os.E.NFILE)),
//    MFILE = -@intCast(c_int, @enumToInt(std.os.E.MFILE)),
//    TXTBSY = -@intCast(c_int, @enumToInt(std.os.E.TXTBSY)),
//    FBIG = -@intCast(c_int, @enumToInt(std.os.E.FBIG)),
//    ROFS = -@intCast(c_int, @enumToInt(std.os.E.ROFS)),
//};
