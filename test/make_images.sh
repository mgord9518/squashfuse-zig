#!/bin/sh

# Change timestamps for some files to test them
touch -a -m -t 201012152359.59 tree/perm_400

# Permissions appear to get screwed up in CI so reset them
chmod 400 tree/perm_400
chmod 644 tree/perm_644
chmod 777 tree/perm_777

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
