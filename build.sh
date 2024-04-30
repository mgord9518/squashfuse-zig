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
    -Denable-zlib=true \
    -Duse-libdeflate=true \
    -Denable-zstd=true \
    -Denable-lz4=true \
    -Denable-xz=true \
    -Denable-lzo=true \
    -Denable-fuse="$enable_fuse" \
    -Duse-system-fuse=false

if [ "$OS" = "windows" ]; then
    zip -9Xj "squashfuse-$OS-$ARCH.zip" "zig-out/bin/squashfuse.exe"
else
    tar -cf - -C "zig-out/bin" "squashfuse" | xz -9c > "squashfuse-$OS-$ARCH.tar.xz"
fi
