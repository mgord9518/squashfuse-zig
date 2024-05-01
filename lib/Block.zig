pub const Block = @This();

data: []u8,
refcount: u64,

/// Describes a SquashFS fragment block
/// <https://dr-emann.github.io/squashfs/#datablocks-and-fragments>
pub const FragmentEntry = extern struct {
    start_block: u64,
    block_header: Block.DataEntry,
    UNUSED: u32 = undefined,
};

/// Describes a SquashFS data block
/// <https://dr-emann.github.io/squashfs/#datablocks-and-fragments>
pub const DataEntry = packed struct {
    // Maximum SquashFS block size is 1MiB, which can be
    // represented by a u20
    size: u20,
    UNUSED: u3 = undefined,
    is_uncompressed: bool,
    UNUSED2: u8 = undefined,
};

/// Describes a SquashFS metadata block
/// <https://dr-emann.github.io/squashfs/#metadata-blocks>
pub const MetadataEntry = packed struct {
    size: u15,
    is_uncompressed: bool,
};
