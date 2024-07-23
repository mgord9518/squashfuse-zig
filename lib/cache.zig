const std = @import("std");
const squashfuse = @import("root.zig");
const SquashFs = squashfuse.SquashFs;
const Inode = SquashFs.Inode;
const assert = std.debug.assert;

pub fn Cache(T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,

        entry_idxs: []u64,
        entries: []T,

        data: ?[]u8 = null,
        compressed_data: ?[]u8 = null,

        count: usize,

        pos: usize = 0,

        pub const Options = struct {
            block_size: usize = 0,
        };

        pub const Entry = struct {
            idx: u64,
            entry: T,
        };

        pub fn init(
            allocator: std.mem.Allocator,
            count: usize,
            opts: Options,
        ) !Self {
            var cache = Self{
                .allocator = allocator,
                .count = count,
                .entries = try allocator.alloc(
                    T,
                    count,
                ),
                .entry_idxs = try allocator.alloc(
                    u64,
                    count,
                ),
            };

            if (opts.block_size > 0) {
                cache.data = try allocator.alloc(
                    u8,
                    count * opts.block_size,
                );
                cache.compressed_data = try allocator.alloc(
                    u8,
                    count * opts.block_size,
                );
            }

            @memset(cache.entry_idxs, SquashFs.invalid_block);

            return cache;
        }

        pub fn deinit(cache: *Self) void {
            cache.allocator.free(cache.entry_idxs);
            cache.allocator.free(cache.entries);

            if (cache.data) |data| {
                cache.allocator.free(data);
            }

            if (cache.compressed_data) |compressed_data| {
                cache.allocator.free(compressed_data);
            }
        }

        pub fn get(cache: *Self, id: u64) ?T {
            const ptr = cache.getPtr(id);

            if (ptr) |p| return p.*;

            return null;
        }

        pub fn getPtr(
            cache: *Self,
            id: u64,
        ) ?*T {
            assert(id != SquashFs.invalid_block);

            for (cache.entry_idxs, 0..) |i, idx| {
                if (i == id) {
                    return &cache.entries[idx];
                }
            }

            return null;
        }

        pub fn put(
            cache: *Self,
            id: u64,
            item: T,
        ) void {
            const entry = &cache.entries[cache.pos];
            entry.* = item;

            cache.entry_idxs[cache.pos] = id;

            cache.pos += 1;
            cache.pos %= cache.count;
        }
    };
}
