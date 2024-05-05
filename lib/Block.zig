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
pub const DataEntry = packed struct(u32) {
    size: u24,
    is_uncompressed: bool,
    UNUSED: u7 = undefined,
};

/// Describes a SquashFS metadata block
/// <https://dr-emann.github.io/squashfs/#metadata-blocks>
pub const MetadataEntry = packed struct(u16) {
    size: u15,
    is_uncompressed: bool,
};
