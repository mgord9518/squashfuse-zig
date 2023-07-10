const std = @import("std");
const os = std.os;
const span = std.mem.span;
const expect = std.testing.expect;
const fs = std.fs;
const squashfuse = @import("lib/SquashFs.zig");

pub const SquashFsError = squashfuse.SquashFsError;
pub const InodeId = squashfuse.InodeId;
pub const SquashFs = squashfuse.SquashFs;
