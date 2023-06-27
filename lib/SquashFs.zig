const std = @import("std");
const os = std.os;
const span = std.mem.span;
const expect = std.testing.expect;
const fs = std.fs;
const xz = std.compress.xz;

const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("stat.h"); // squashfuse (not system) stat header
    @cInclude("squashfuse.h");
    @cInclude("common.h");
});

pub const SquashFsError = error{
    Error, // Generic error
    InvalidFormat, // Unknown file format
    InvalidVersion, // Unsupported version
    InvalidCompression, // Unsupported compression algorithm
    UnsupportedFeature, // Unsupported feature
};

// Converts a C error code to a Zig error enum
fn SquashFsErrorFromInt(err: c_uint) SquashFsError!void {
    return switch (err) {
        0 => {},
        2 => SquashFsError.InvalidFormat,
        3 => SquashFsError.InvalidVersion,
        4 => SquashFsError.InvalidCompression,
        5 => SquashFsError.UnsupportedFeature,

        else => SquashFsError.Error,
    };
}

pub const InodeId = c.sqfs_inode_id;

pub const SquashFs = struct {
    internal: c.sqfs,
    version: Version,
    file: fs.File,

    pub const Version = struct {
        major: i32,
        minor: i32,
    };

    pub fn init(allocator: std.mem.Allocator, path: []const u8, offset: u64) !SquashFs {
        _ = allocator;
        var sqfs = SquashFs{
            .internal = undefined,
            .version = undefined,
            .file = try std.fs.cwd().openFile(path, .{}),
        };

        // Populate internal squashfuse struct
        try SquashFsErrorFromInt(c.sqfs_init(&sqfs.internal, sqfs.file.handle, offset));

        // Set version
        c.sqfs_version(&sqfs.internal, &sqfs.version.major, &sqfs.version.minor);

        return sqfs;
    }

    pub inline fn deinit(sqfs: *SquashFs) void {
        c.sqfs_destroy(&sqfs.internal);
        sqfs.file.close();
    }

    // Another small wrapper, this shouldn't be used unless necessary (stuff
    // missing from the bindings)
    pub inline fn getInode(sqfs: *SquashFs, id: InodeId) !Inode {
        var sqfs_inode: c.sqfs_inode = undefined;

        try SquashFsErrorFromInt(c.sqfs_inode_get(&sqfs.internal, &sqfs_inode, id));

        return Inode{ .internal = sqfs_inode, .parent = sqfs, .kind = @enumFromInt(sqfs_inode.base.inode_type) };
    }

    pub inline fn getRootInode(sqfs: *SquashFs) Inode {
        return sqfs.getInode(
            sqfs.internal.sb.root_inode,
        ) catch unreachable;
    }

    // TODO: implement as seekable stream and remove offset in `read` method
    pub const Inode = struct {
        internal: c.sqfs_inode,
        parent: *SquashFs,
        kind: File.Kind,

        /// Reads the link target into `buf`
        pub fn readLink(self: *Inode, buf: []u8) !void {
            var size = buf.len;

            try SquashFsErrorFromInt(c.sqfs_readlink(&self.parent.internal, &self.internal, buf.ptr, &size));
        }

        /// Wrapper of `sqfs_read_range`
        /// Use for reading one byte buffer at a time
        /// Retruns a slice of the read bytes
        pub fn read(self: *Inode, buf: []u8, off: usize) !usize {
            // squashfuse writes the amount of bytes read back into the `buffer
            // length` variable, so we create that here
            var buf_len: c.sqfs_off_t = @intCast(buf.len);

            const err = c.sqfs_read_range(&self.parent.internal, &self.internal, @intCast(off), &buf_len, @ptrCast(buf));

            try SquashFsErrorFromInt(err);

            return @intCast(buf_len);
        }

        pub const Reader = std.io.Reader(Inode, std.os.ReadError, read);

        pub fn reader(self: *Inode) Reader {
            return .{ .context = self };
        }

        pub inline fn stat(self: *Inode) !fs.File.Stat {
            const st = try self.statC();

            return fs.File.Stat.fromSystem(st);
        }

        // Like `Inode.stat` but returns the OS native stat format
        pub fn statC(self: *Inode) !os.Stat {
            var st = std.mem.zeroes(os.Stat);

            const err = c.sqfs_stat(&self.parent.internal, &self.internal, @ptrCast(&st));
            try SquashFsErrorFromInt(err);

            return st;
        }

        pub fn iterate(self: *Inode) !Iterator {
            // TODO: error handling
            // squashfuse already does errors, which get caught by
            // `SquashFsErrorFromInt` but it's probably better to handle them
            // in Zig as I plan on slowly reimplementing a lot of functions
            //if (self.kind != .Directory)

            // Open dir
            // TODO: add offset
            var dir: c.sqfs_dir = undefined;
            try SquashFsErrorFromInt(c.sqfs_dir_open(&self.parent.internal, &self.internal, &dir, 0));

            return .{ .dir = self.*, .internal = dir, .parent = self.parent };
        }

        pub const Iterator = struct {
            dir: Inode,
            internal: c.sqfs_dir,
            parent: *SquashFs,

            pub const Entry = struct {
                id: InodeId,
                parent: *SquashFs,

                name: []const u8,
                kind: File.Kind,

                pub inline fn inode(self: *const Entry) Inode {
                    var sqfs_inode: c.sqfs_inode = undefined;

                    // This should never fail
                    // if it does, something went very wrong (like messing with
                    // the inode ID)
                    const err = c.sqfs_inode_get(
                        &self.parent.internal,
                        &sqfs_inode,
                        self.id,
                    );
                    if (err != 0) unreachable;

                    return Inode{
                        .internal = sqfs_inode,
                        .parent = self.parent,
                        .kind = self.kind,
                    };
                }
            };

            /// Wraps `sqfs_dir_next`
            /// Returns an entry for the next inode in the directory
            pub fn next(self: *Iterator) !?Entry {
                // Initialize an entry and its name buffer
                var sqfs_dir_entry: c.sqfs_dir_entry = undefined;
                var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

                sqfs_dir_entry.name = &buf;

                var err: c.sqfs_err = undefined;

                const found = c.sqfs_dir_next(
                    &self.parent.internal,
                    &self.internal,
                    &sqfs_dir_entry,
                    &err,
                );
                try SquashFsErrorFromInt(err);

                if (!found) return null;

                return .{
                    .id = sqfs_dir_entry.inode,
                    .name = sqfs_dir_entry.name[0..sqfs_dir_entry.name_size],
                    .kind = @enumFromInt(sqfs_dir_entry.type),
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
                id: InodeId,
                parent: *SquashFs,

                dir: Inode,
                kind: File.Kind,
                path: []const u8,
                basename: []const u8,

                pub inline fn inode(self: *const Entry) Inode {
                    var sqfs_inode: c.sqfs_inode = undefined;

                    // This should never fail
                    // if it does, something went very wrong
                    const err = c.sqfs_inode_get(&self.parent.internal, &sqfs_inode, self.id);
                    if (err != 0) unreachable;

                    return Inode{ .internal = sqfs_inode, .parent = self.parent, .kind = self.kind };
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
                            try self.name_buffer.append(std.fs.path.sep);
                            dirname_len += 1;
                        }

                        try self.name_buffer.appendSlice(entry.name);

                        if (entry.kind == .Directory) {
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

                        return .{
                            .dir = containing.iter.dir,
                            .basename = self.name_buffer.items[dirname_len..],
                            .id = entry.id,
                            .parent = entry.parent,
                            .path = self.name_buffer.items,
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
                .File => {
                    var f = try cwd.createFile(dest, .{});
                    defer f.close();

                    var off: usize = 0;
                    const fsize: usize = self.internal.xtra.reg.file_size;

                    while (off < fsize) {
                        const read_bytes = try self.read(buf, off);
                        off += read_bytes;

                        _ = try f.write(buf[0..read_bytes]);
                    }

                    // Change the mode of the file to match the inode contained in the
                    // SquashFS image
                    const st = try self.stat();
                    try f.chmod(st.mode);
                },

                .Directory => {
                    try cwd.makeDir(dest);
                },

                // TODO: implement for other types
                else => @panic("NEI for file type"),
            }
        }
    };

    pub const File = struct {
        pub const Kind = enum(u8) {
            Directory = 1,
            File,
            SymLink,
            BlockDevice,
            CharacterDevice,
            NamedPipe,
            UnixDomainSocket,

            // Not really sure what these are tbh, but squashfuse has entries for
            // them
            LDirectory,
            LFile,
            LSymLink,
            LBlockDevice,
            LCharacterDevice,
            LNamedPipe,
            LUnixDomainSocket,
        };
    };
};

// Expose a C function to utilize Zig's stdlib XZ implementation
export fn zig_xz_decode(in: [*]u8, in_size: usize, out: [*]u8, out_size: *usize) callconv(.C) usize {
    var stream = std.io.fixedBufferStream(in[0..in_size]);

    var allocator = std.heap.c_allocator;

    var decompressor = xz.decompress(
        allocator,
        stream.reader(),
    ) catch return 1;

    defer decompressor.deinit();

    var buf = out[0..out_size.*];

    out_size.* = decompressor.read(buf) catch return 2;

    return 0;
}
