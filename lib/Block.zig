pub const Block = @This();
const std = @import("std");

data: []u8,
data_size: usize = 0,
refcount: u64,
allocator: std.mem.Allocator,

pub fn deinit(block: *Block) void {
    block.allocator.free(block.data);
}

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
