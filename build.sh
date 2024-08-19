#!/bin/sh
# Basic build script for CI
#
# Not recommended to use for normal installs, a simple `zig build` is
# preferable for most cases
#
# REQUIRES: zig tar xz zip

[ -z $OPTIMIZE ] && OPTIMIZE=ReleaseFast
[ -z $ARCH     ] && ARCH=$(uname -m)
[ -z $OS       ] && OS='linux'
[ -z $LIBC     ] && LIBC='musl'

if [ "$OS" = "linux" ]; then
    enable_fuse="true"
else
    enable_fuse="false"
fi

zig build \
    -Doptimize="$OPTIMIZE" \
    -Dtarget="$ARCH-$OS-$LIBC" \
    -Dstrip=true \
    -Dstatic_zlib=true \
    -Duse_libdeflate=true \
    -Dstatic_zstd=true \
    -Dstatic_lz4=true \
    -Dstatic_xz=true \
    -Denable_fuse="$enable_fuse" \
    -Dstatic_fuse=true

if [ "$OS" = "windows" ]; then
    zip -9Xj "squashfuse-$OS-$ARCH.zip" "zig-out/bin/squashfuse.exe"
else
    tar -cf - -C "zig-out/bin" "squashfuse" | xz -9c > "squashfuse-$OS-$ARCH.tar.xz"
fi
