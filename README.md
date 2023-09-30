# squashfuse-zig
Idomatic Zig bindings for squashfuse and new tools

My main goals for this project are as follows:
 * Make library usage as similar to Zig's stdlib as possible
 * Performant; choose the best compression implementations by default (this
   is already done using libdeflate in place of zlib)
 * Fully-compatible with existing squashfuse tools
 * Keep code as clean as possible
 * Iteratively re-implement squashfuse functionality in Zig, so eventually this
   should be a complete re-implementation. A few functions have been ported
   but the vast majority is still just bindings

With some very basic benchmarking, extracting a zlib-compressed AppImage
(FreeCAD, the largest AppImage I've been able to find so far), takes 3.7
seconds using squashfuse-zig's `squashfuse_tool`. Currently, `squashfs_tool`
is single-thread only.

For reference, `unsquashfs` with multi-threaded decompression takes 1.57 seconds
and single-threaded takes 6.5 seconds.

Surely almost all of the single-threaded performace gain can be chalked up to
using libdeflate, but performance by default is important. I'd like to compare
it to the actual squashfuse's `squashfuse_extract` program to see how it
compares.
