#!/bin/sh

for comp in 'gzip' 'xz' 'zstd' 'lz4' 'lzo'; do
    name="$comp"

    # For some reason mksquashfs calls SquashFS zlib compression gzip despite
    # not actually being in a gzip container
    [ "$name" = "gzip" ] && name="zlib"

    mksquashfs "tree/" \
        "tree_$name.sqfs" \
        -comp "$comp" \
        -noappend \
        -root-owned \
        -quiet
done
