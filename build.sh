#!/bin/sh
# Basic build script for CI
#
# Not recommended to use for normal installs, a simple `zig build` is
# preferable in most cases

[ -z $OPTIMIZE ] && OPTIMIZE=ReleaseFast
[ -z $ARCH     ] && ARCH=$(uname -m)
[ -z $OS       ] && OS='linux'
[ -z $LIBC     ] && LIBC='musl'

target="$ARCH-$OS-$LIBC"

if [ "$LIBC" = 'musl' ]; then
    prefix='.static'
fi

# All compression algos
zig build \
    -Doptimize="$OPTIMIZE" \
    -Dtarget="$target" \
    -Dstrip=true \
    -Dbuild-squashfuse_tool=false \
    -Denable-zlib=true \
    -Duse-libdeflate=true \
    -Denable-zstd=true \
    -Denable-lz4=true \
    -Denable-xz=true \
    -Denable-lzo=true \
    -Duse-system-fuse=false

mv zig-out/bin/squashfuse "squashfuse$prefix.$ARCH"

# ZLIB
zig build \
    -Doptimize="$OPTIMIZE" \
    -Dtarget="$target" \
    -Dstrip=true \
    -Dbuild-squashfuse_tool=false \
    -Denable-zlib=true \
    -Duse-libdeflate=true \
    -Denable-zstd=false \
    -Denable-lz4=false \
    -Denable-xz=false \
    -Denable-lzo=false \
    -Duse-system-fuse=false

mv zig-out/bin/squashfuse "squashfuse_zlib$prefix.$ARCH"

# ZSTD
zig build \
    -Doptimize="$OPTIMIZE" \
    -Dtarget="$target" \
    -Dstrip=true \
    -Dbuild-squashfuse_tool=false \
    -Denable-zlib=false \
    -Denable-zstd=true \
    -Denable-lz4=false \
    -Denable-xz=false \
    -Denable-lzo=false \
    -Duse-system-fuse=false

mv zig-out/bin/squashfuse "squashfuse_zstd$prefix.$ARCH"

# LZ4
zig build \
    -Doptimize="$OPTIMIZE" \
    -Dtarget="$target" \
    -Dstrip=true \
    -Dbuild-squashfuse_tool=false \
    -Denable-zlib=false \
    -Denable-zstd=false \
    -Denable-lz4=true \
    -Denable-xz=false \
    -Denable-lzo=false \
    -Duse-system-fuse=false

mv zig-out/bin/squashfuse "squashfuse_lz4$prefix.$ARCH"

# LZO
zig build \
    -Doptimize="$OPTIMIZE" \
    -Dtarget="$target" \
    -Dstrip=true \
    -Dbuild-squashfuse_tool=false \
    -Denable-zlib=false \
    -Denable-zstd=false \
    -Denable-lz4=false \
    -Denable-xz=false \
    -Denable-lzo=true \
    -Duse-system-fuse=false

mv zig-out/bin/squashfuse "squashfuse_lzo$prefix.$ARCH"

# XZ
zig build \
    -Doptimize="$OPTIMIZE" \
    -Dtarget="$target" \
    -Dstrip=true \
    -Dbuild-squashfuse_tool=false \
    -Denable-zlib=false \
    -Denable-zstd=false \
    -Denable-lz4=false \
    -Denable-xz=true \
    -Denable-lzo=false \
    -Duse-system-fuse=false

mv zig-out/bin/squashfuse "squashfuse_xz$prefix.$ARCH"
