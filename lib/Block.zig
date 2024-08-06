// TODO: move this stuff

pub const Block = @This();
const std = @import("std");

/// Describes a SquashFS fragment block
/// <https://dr-emann.github.io/squashfs/#datablocks-and-fragments>
pub const FragmentEntry = extern struct {
    start_block: u64,
    block_header: Block.DataEntry,

    _96: u32 = undefined,
};

/// Describes a SquashFS data block
/// <https://dr-emann.github.io/squashfs/#datablocks-and-fragments>
pub const DataEntry = packed struct(u32) {
    // Currently 1MiB max, may be likely will be extended in the future
    size: u24,

    is_uncompressed: bool,

    _25: u7 = undefined,
};

/// Describes a SquashFS metadata block
/// <https://dr-emann.github.io/squashfs/#metadata-blocks>
pub const MetadataEntry = packed struct(u16) {
    size: u15,
    is_uncompressed: bool,
};
