/*
 * Copyright (c) 2012 Dave Vasilevsky <dave@vasilevsky.ca>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR(S) ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
#include "swap.h"

#ifndef HAVE_ASM_BYTEORDER_H
#define SWAP(BITS) \
	void sqfs_swapin##BITS(uint##BITS##_t *v) { \
		int i; \
		uint8_t *c = (uint8_t*)v; \
		uint##BITS##_t r = 0; \
		for (i = sizeof(*v) - 1; i >= 0; --i) { \
			r <<= 8; \
			r += c[i]; \
		} \
		*v = r; \
	}

SWAP(16)
SWAP(32)
SWAP(64)
#undef SWAP
#endif

void sqfs_swap16(uint16_t *n) {
	*n = (*n >> 8) + (*n << 8);
}

#include "squashfs_fs.h"

void sqfs_swapin_super_block(struct squashfs_super_block *s){
sqfs_swapin32_internal(&s->s_magic);
sqfs_swapin32_internal(&s->inodes);
sqfs_swapin32_internal(&s->mkfs_time);
sqfs_swapin32_internal(&s->block_size);
sqfs_swapin32_internal(&s->fragments);
sqfs_swapin16_internal(&s->compression);
sqfs_swapin16_internal(&s->block_log);
sqfs_swapin16_internal(&s->flags);
sqfs_swapin16_internal(&s->no_ids);
sqfs_swapin16_internal(&s->s_major);
sqfs_swapin16_internal(&s->s_minor);
sqfs_swapin64_internal(&s->root_inode);
sqfs_swapin64_internal(&s->bytes_used);
sqfs_swapin64_internal(&s->id_table_start);
sqfs_swapin64_internal(&s->xattr_id_table_start);
sqfs_swapin64_internal(&s->inode_table_start);
sqfs_swapin64_internal(&s->directory_table_start);
sqfs_swapin64_internal(&s->fragment_table_start);
sqfs_swapin64_internal(&s->lookup_table_start);
}
void sqfs_swapin_dir_index(struct squashfs_dir_index *s){
sqfs_swapin32_internal(&s->index);
sqfs_swapin32_internal(&s->start_block);
sqfs_swapin32_internal(&s->size);
}
void sqfs_swapin_base_inode(struct squashfs_base_inode *s){
sqfs_swapin16_internal(&s->inode_type);
sqfs_swapin16_internal(&s->mode);
sqfs_swapin16_internal(&s->uid);
sqfs_swapin16_internal(&s->guid);
sqfs_swapin32_internal(&s->mtime);
sqfs_swapin32_internal(&s->inode_number);
}
void sqfs_swapin_ipc_inode(struct squashfs_ipc_inode *s){
sqfs_swapin16_internal(&s->inode_type);
sqfs_swapin16_internal(&s->mode);
sqfs_swapin16_internal(&s->uid);
sqfs_swapin16_internal(&s->guid);
sqfs_swapin32_internal(&s->mtime);
sqfs_swapin32_internal(&s->inode_number);
sqfs_swapin32_internal(&s->nlink);
}
void sqfs_swapin_lipc_inode(struct squashfs_lipc_inode *s){
sqfs_swapin16_internal(&s->inode_type);
sqfs_swapin16_internal(&s->mode);
sqfs_swapin16_internal(&s->uid);
sqfs_swapin16_internal(&s->guid);
sqfs_swapin32_internal(&s->mtime);
sqfs_swapin32_internal(&s->inode_number);
sqfs_swapin32_internal(&s->nlink);
sqfs_swapin32_internal(&s->xattr);
}
void sqfs_swapin_dev_inode(struct squashfs_dev_inode *s){
sqfs_swapin16_internal(&s->inode_type);
sqfs_swapin16_internal(&s->mode);
sqfs_swapin16_internal(&s->uid);
sqfs_swapin16_internal(&s->guid);
sqfs_swapin32_internal(&s->mtime);
sqfs_swapin32_internal(&s->inode_number);
sqfs_swapin32_internal(&s->nlink);
sqfs_swapin32_internal(&s->rdev);
}
void sqfs_swapin_ldev_inode(struct squashfs_ldev_inode *s){
sqfs_swapin16_internal(&s->inode_type);
sqfs_swapin16_internal(&s->mode);
sqfs_swapin16_internal(&s->uid);
sqfs_swapin16_internal(&s->guid);
sqfs_swapin32_internal(&s->mtime);
sqfs_swapin32_internal(&s->inode_number);
sqfs_swapin32_internal(&s->nlink);
sqfs_swapin32_internal(&s->rdev);
sqfs_swapin32_internal(&s->xattr);
}
void sqfs_swapin_symlink_inode(struct squashfs_symlink_inode *s){
sqfs_swapin16_internal(&s->inode_type);
sqfs_swapin16_internal(&s->mode);
sqfs_swapin16_internal(&s->uid);
sqfs_swapin16_internal(&s->guid);
sqfs_swapin32_internal(&s->mtime);
sqfs_swapin32_internal(&s->inode_number);
sqfs_swapin32_internal(&s->nlink);
sqfs_swapin32_internal(&s->symlink_size);
}
void sqfs_swapin_reg_inode(struct squashfs_reg_inode *s){
sqfs_swapin16_internal(&s->inode_type);
sqfs_swapin16_internal(&s->mode);
sqfs_swapin16_internal(&s->uid);
sqfs_swapin16_internal(&s->guid);
sqfs_swapin32_internal(&s->mtime);
sqfs_swapin32_internal(&s->inode_number);
sqfs_swapin32_internal(&s->start_block);
sqfs_swapin32_internal(&s->fragment);
sqfs_swapin32_internal(&s->offset);
sqfs_swapin32_internal(&s->file_size);
}
void sqfs_swapin_lreg_inode(struct squashfs_lreg_inode *s){
sqfs_swapin16_internal(&s->inode_type);
sqfs_swapin16_internal(&s->mode);
sqfs_swapin16_internal(&s->uid);
sqfs_swapin16_internal(&s->guid);
sqfs_swapin32_internal(&s->mtime);
sqfs_swapin32_internal(&s->inode_number);
sqfs_swapin64_internal(&s->start_block);
sqfs_swapin64_internal(&s->file_size);
sqfs_swapin64_internal(&s->sparse);
sqfs_swapin32_internal(&s->nlink);
sqfs_swapin32_internal(&s->fragment);
sqfs_swapin32_internal(&s->offset);
sqfs_swapin32_internal(&s->xattr);
}
void sqfs_swapin_dir_inode(struct squashfs_dir_inode *s){
sqfs_swapin16_internal(&s->inode_type);
sqfs_swapin16_internal(&s->mode);
sqfs_swapin16_internal(&s->uid);
sqfs_swapin16_internal(&s->guid);
sqfs_swapin32_internal(&s->mtime);
sqfs_swapin32_internal(&s->inode_number);
sqfs_swapin32_internal(&s->start_block);
sqfs_swapin32_internal(&s->nlink);
sqfs_swapin16_internal(&s->file_size);
sqfs_swapin16_internal(&s->offset);
sqfs_swapin32_internal(&s->parent_inode);
}
void sqfs_swapin_ldir_inode(struct squashfs_ldir_inode *s){
sqfs_swapin16_internal(&s->inode_type);
sqfs_swapin16_internal(&s->mode);
sqfs_swapin16_internal(&s->uid);
sqfs_swapin16_internal(&s->guid);
sqfs_swapin32_internal(&s->mtime);
sqfs_swapin32_internal(&s->inode_number);
sqfs_swapin32_internal(&s->nlink);
sqfs_swapin32_internal(&s->file_size);
sqfs_swapin32_internal(&s->start_block);
sqfs_swapin32_internal(&s->parent_inode);
sqfs_swapin16_internal(&s->i_count);
sqfs_swapin16_internal(&s->offset);
sqfs_swapin32_internal(&s->xattr);
}
void sqfs_swapin_dir_entry(struct squashfs_dir_entry *s){
sqfs_swapin16_internal(&s->offset);
sqfs_swapin16_internal(&s->inode_number);
sqfs_swapin16_internal(&s->type);
sqfs_swapin16_internal(&s->size);
}
void sqfs_swapin_dir_header(struct squashfs_dir_header *s){
sqfs_swapin32_internal(&s->count);
sqfs_swapin32_internal(&s->start_block);
sqfs_swapin32_internal(&s->inode_number);
}
void sqfs_swapin_fragment_entry(struct squashfs_fragment_entry *s){
sqfs_swapin64_internal(&s->start_block);
sqfs_swapin32_internal(&s->size);
}
void sqfs_swapin_xattr_entry(struct squashfs_xattr_entry *s){
sqfs_swapin16_internal(&s->type);
sqfs_swapin16_internal(&s->size);
}
void sqfs_swapin_xattr_val(struct squashfs_xattr_val *s){
sqfs_swapin32_internal(&s->vsize);
}
void sqfs_swapin_xattr_id(struct squashfs_xattr_id *s){
sqfs_swapin64_internal(&s->xattr);
sqfs_swapin32_internal(&s->count);
sqfs_swapin32_internal(&s->size);
}
void sqfs_swapin_xattr_id_table(struct squashfs_xattr_id_table *s){
sqfs_swapin64_internal(&s->xattr_table_start);
sqfs_swapin32_internal(&s->xattr_ids);
sqfs_swapin32_internal(&s->unused);
}
