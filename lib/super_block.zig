// SquashFS superblock
// <https://dr-emann.github.io/squashfs/#superblock>

const SquashFs = @import("root.zig").SquashFs;
const compression = @import("compression.zig");

pub const SuperBlock = extern struct {
    magic: [4]u8,
    inode_count: u32,
    modification_time: u32,
    block_size: u32,
    fragment_entry_count: u32,
    compression: compression.Compression,
    block_log: u16,
    flags: Flags,
    id_count: u16,
    version_major: u16,
    version_minor: u16,
    root_inode_id: SquashFs.Inode.TableEntry,
    bytes_used: u64,
    id_table_start: u64,
    xattr_id_table_start: u64,
    inode_table_start: u64,
    directory_table_start: u64,
    fragment_table_start: u64,
    export_table_start: u64,

    pub const Flags = packed struct(u16) {
        uncompressed_inodes: bool,
        uncompressed_data: bool,

        // `check` flag; unused in SquashFS 4.0+
        _2: u1 = undefined,

        uncompressed_fragments: bool,
        no_fragments: bool,
        always_fragments: bool,
        duplicates: bool,
        exportable: bool,
        uncompressed_xattrs: bool,
        no_xattrs: bool,
        compressor_options: bool,
        uncompressed_ids: bool,

        _12: u4 = undefined,
    };

    pub const BaseInode = extern struct {
        kind: u16,
        mode: u16,
        uid: u16,
        guid: u16,
        mtime: u32,
        inode_number: u32,
    };

    pub const DirInode = extern struct {
        base: BaseInode,
        start_block: u32,
        nlink: u32,
        size: u16,
        offset: u16,
        parent_inode: u32,

        pub fn toLong(inode: DirInode) LDirInode {
            return .{
                .start_block = inode.start_block,
                .offset = inode.offset,
                .size = inode.size,
                .i_count = 0,
                .nlink = inode.nlink,
                .xattr = SquashFs.invalid_xattr,
                .base = inode.base,
                .parent_inode = inode.parent_inode,
            };
        }
    };

    pub const FileInode = extern struct {
        base: BaseInode,
        start_block: u32,
        frag_idx: u32,
        frag_off: u32,
        size: u32,

        pub fn toLong(inode: FileInode) LFileInode {
            return .{
                .base = inode.base,
                .start_block = inode.start_block,
                .size = inode.size,
                .sparse = 0,
                .nlink = 1,
                .frag_idx = inode.frag_idx,
                .frag_off = inode.frag_off,
                .xattr = SquashFs.invalid_xattr,
            };
        }
    };

    pub const SymLinkInode = extern struct {
        base: BaseInode,
        nlink: u32,
        size: u32,
    };

    pub const DevInode = extern struct {
        base: BaseInode,
        nlink: u32,
        dev: Device,

        const Device = packed struct(u32) {
            minor_dev: u8,
            major_dev: u12,
            minor_dev_extended: u12,
        };

        pub fn toLong(inode: DevInode) LDevInode {
            return .{
                .base = inode.base,
                .nlink = 1,
                .xattr = SquashFs.invalid_xattr,
                .dev = inode.dev,
            };
        }

        pub fn major(inode: DevInode) u12 {
            return inode.dev.major_dev;
        }

        pub fn minor(inode: DevInode) u20 {
            return (@as(u20, inode.dev.minor_dev_extended) << 8) + inode.dev.minor_dev;
        }
    };

    pub const IpcInode = extern struct {
        base: BaseInode,
        nlink: u32,
    };

    pub const LDirInode = extern struct {
        base: BaseInode,
        nlink: u32,
        size: u32,
        start_block: u32,
        parent_inode: u32,
        i_count: u16,
        offset: u16,
        xattr: u32,
    };

    pub const LFileInode = extern struct {
        base: BaseInode,
        start_block: u64,
        size: u64,
        sparse: u64,
        nlink: u32,
        frag_idx: u32,
        frag_off: u32,
        xattr: u32,
    };

    pub const LDevInode = extern struct {
        base: BaseInode,
        nlink: u32,
        dev: DevInode.Device,
        xattr: u32,

        pub fn major(inode: LDevInode) u12 {
            return inode.dev.major_dev;
        }

        pub fn minor(inode: LDevInode) u16 {
            return (@as(u16, inode.dev.minor_dev_extended) << 8) + inode.dev.minor_dev;
        }
    };

    pub const LIpcInode = extern struct {
        base: BaseInode,
        nlink: u32,
        xattr: u32,
    };
};
