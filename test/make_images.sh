#!/bin/sh
mksquashfs tree tree_zlib.sqfs -comp gzip -noappend -root-owned
mksquashfs tree tree_xz.sqfs   -comp xz   -noappend -root-owned
mksquashfs tree tree_zstd.sqfs -comp zstd -noappend -root-owned
mksquashfs tree tree_lz4.sqfs  -comp lz4  -noappend -root-owned
mksquashfs tree tree_lzo.sqfs  -comp lzo  -noappend -root-owned
