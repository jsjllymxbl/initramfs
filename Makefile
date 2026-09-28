# SPDX-License-Identifier: GPL-2.0
#
# initramfs and boot.img for the Xiaomi Mi 2 (aries, APQ8064) running a
# mainline kernel and booted through lk2nd.
#
#   make                init + initramfs + boot.img
#   make init           compile the Rust /init into root/init
#   make initramfs      pack root/ into initramfs.cpio.lz4
#   make boot.img       pack zImage-dtb + initramfs into boot.img
#   make verify         re-run every check on what is on disk, no rebuild
#   make clean          drop the build products (firmware/ stays)
#   make help           the long version
#
# Inputs this Makefile does not build (put them in this directory):
#   zImage-dtb          kernel zImage with the aries DTB appended
#   firmware/           what becomes /lib/firmware inside the initramfs
#
# Everything below can be overridden on the command line:
#   make CMDLINE="console=tty0 ignore_loglevel" COMPRESS=gzip

SHELL := /bin/bash
.SUFFIXES:
.DEFAULT_GOAL := all

# Directory holding this Makefile.
SRC := $(patsubst %/,%,$(dir $(realpath $(lastword $(MAKEFILE_LIST)))))

# ---------------------------------------------------------------- device ----
# p23 is userdata in Xiaomi's factory GPT (p21 system, p22 cache).
USERDATA_PART  ?= /dev/mmcblk0p23
# Directory inside userdata that holds the distro.
DISTRO_SUBDIR  ?= rootfs
# Filesystem of userdata as Xiaomi's Android 5.0 image ships it.
ROOTFS_FSTYPE  ?= ext4
# Seconds to wait before powering off after a failed boot (0 = immediately).
SHUTDOWN_DELAY ?= 15

# ----------------------------------------------------------------- build ----
RUST_TARGET       ?= armv7-unknown-linux-musleabihf
# initramfs compression: lz4 (legacy frame), gzip or none.
COMPRESS          ?= lz4
# Reproducible archives: unchanged content => byte-identical boot.img.
SOURCE_DATE_EPOCH ?= 0

# boot.img address layout.  The reasoning behind these numbers is in the header
# of scripts/pack-bootimg.sh (which asserts them) and in the README - do not
# change them without reading that first.
#
# BASE doubles as PHYS_OFFSET: the kernel throws away everything below its own
# load address ("OF: fdt: Ignoring memory range ..."), so lowering it is the only
# way to get memory back.  0x88000000 is the floor (zreladdr + SMEM) and needs an
# lk2nd that maps the 0x88200000-0x90000000 mmu hole (patched 2026-09-28,
# platform/msm8960/platform.c); compared to 0x90000000 it recovers 128 MiB, and
# keeps the kernel destination below lk2nd's scratch buffer (see pack-bootimg.sh).
BASE           ?= 0x88000000
KERNEL_OFFSET  ?= 0x00008000
RAMDISK_OFFSET ?= 0x04000000
TAGS_OFFSET    ?= 0x05000000
PAGESIZE       ?= 2048
BOARD          ?= aries

# fw_devlink=permissive and the three *_ignore_unused flags are mandatory on
# APQ8064; log_buf_len=2M is what makes the failure log (which init dumps to
# userdata) worth reading.  drm.debug=0x1f is a bring-up leftover.
CMDLINE ?= console=ttyMSM0,115200n8 console=tty0 earlycon log_buf_len=2M consoleblank=0 \
           drm.debug=0x1f clk_ignore_unused pd_ignore_unused regulator_ignore_unused \
           fw_devlink=permissive no_console_suspend printk.always_kmsg_dump=1 \
           lk2nd.pass-ramoops=keep

# ----------------------------------------------------------------- paths ----
ROOT         := $(SRC)/root
INIT_DIR     := $(SRC)/init
INIT_BIN     := $(ROOT)/init
FIRMWARE_SRC := $(SRC)/firmware
FIRMWARE_DST := $(ROOT)/lib/firmware
ZIMAGE_DTB   := $(SRC)/zImage-dtb
MKBOOTIMG    := $(SRC)/scripts/mkbootimg.py
PACK_BOOTIMG := $(SRC)/scripts/pack-bootimg.sh
BOOTIMG      ?= $(SRC)/boot.img

# ----------------------------------------------------------- compression ----
ifeq ($(COMPRESS),lz4)
  RAMDISK_EXT  := lz4
  COMPRESS_CMD := lz4 -l -9 -c -q
else ifeq ($(COMPRESS),gzip)
  RAMDISK_EXT  := gz
  COMPRESS_CMD := gzip -9 -n
else ifeq ($(COMPRESS),none)
  RAMDISK_EXT  := cpio
  COMPRESS_CMD := cat
else
  $(error COMPRESS 只能是 lz4、gzip 或 none，当前是 '$(COMPRESS)')
endif
RAMDISK := $(SRC)/initramfs.cpio.$(RAMDISK_EXT)

# Newer cpio can zero the inode/device numbers; together with the normalised
# timestamps that makes "same content => byte-identical archive" hold.
CPIO_REPRO := $(shell cpio --help 2>&1 | grep -q -- '--reproducible' && echo --reproducible)

# Shared by `boot.img` and `verify`.
PACK_ARGS = \
    --kernel $(ZIMAGE_DTB) \
    --ramdisk $(RAMDISK) \
    --output $(BOOTIMG) \
    --cmdline '$(CMDLINE)' \
    --base $(BASE) \
    --kernel-offset $(KERNEL_OFFSET) \
    --ramdisk-offset $(RAMDISK_OFFSET) \
    --tags-offset $(TAGS_OFFSET) \
    --pagesize $(PAGESIZE) \
    --board $(BOARD) \
    --mkbootimg $(MKBOOTIMG)

# ----------------------------------------------------------------- rules ----
.PHONY: all init firmware initramfs boot.img verify clean help

all: $(BOOTIMG)

# ---------------------------------------------------------------- /init -----
# cargo tracks the real dependencies (including build.rs and the ARIES_*
# environment), so simply ask it every time.  `install -C` then keeps root/init
# untouched when the binary did not change, which is what keeps the cpio (and
# therefore boot.img) bit-identical between builds.
init:
	cd $(INIT_DIR) && \
	    ARIES_USERDATA_PART='$(USERDATA_PART)' \
	    ARIES_DISTRO_SUBDIR='$(DISTRO_SUBDIR)' \
	    ARIES_ROOTFS_FSTYPE='$(ROOTFS_FSTYPE)' \
	    ARIES_SHUTDOWN_DELAY='$(SHUTDOWN_DELAY)' \
	    cargo build --release --target $(RUST_TARGET)
	install -C -D -m 0755 $(INIT_DIR)/target/$(RUST_TARGET)/release/init $(INIT_BIN)
	@printf '==> init: root/init (%s)\n' "$$(du -h $(INIT_BIN) | cut -f1)"

# ------------------------------------------------------------- firmware -----
# firmware/ ships with the repository (provenance in the README); it just has to
# end up in the initramfs as /lib/firmware.
firmware:
	@test -n "$$(find $(FIRMWARE_SRC) -type f -print -quit)" || { \
	    echo "ERROR: $(FIRMWARE_SRC) 是空的（固件随仓库分发，检查 git 是否完整）" >&2; exit 1; }
	rm -rf $(FIRMWARE_DST)
	install -d -m 0755 $(FIRMWARE_DST)
	cp -a $(FIRMWARE_SRC)/. $(FIRMWARE_DST)/
	@printf '==> firmware: %s files (%s) -> lib/firmware\n' \
	    "$$(find $(FIRMWARE_DST) -type f | wc -l)" \
	    "$$(du -sh $(FIRMWARE_DST) | cut -f1)"

# ------------------------------------------------------------ initramfs -----
# `set -o pipefail` matters: without it a cpio failure is masked by the
# compressor's exit status and a truncated archive gets packaged happily.
initramfs: init firmware
	install -d -m 0755 $(ROOT)/dev $(ROOT)/proc $(ROOT)/sys $(ROOT)/tmp $(ROOT)/run $(ROOT)/mnt
	@echo "==> initramfs: packing $(patsubst $(SRC)/%,%,$(RAMDISK))"
	@set -e -o pipefail; \
	find $(ROOT) -exec touch -h -d @$(SOURCE_DATE_EPOCH) {} + ; \
	( cd $(ROOT) && find . -mindepth 1 -print0 | \
	    cpio -o -H newc --quiet -R 0:0 --null $(CPIO_REPRO) ) | \
	    $(COMPRESS_CMD) > $(RAMDISK).tmp ; \
	mv -f $(RAMDISK).tmp $(RAMDISK) ; \
	printf '    %s entries, %s\n' \
	    "$$(find $(ROOT) -mindepth 1 | wc -l)" "$$(du -h $(RAMDISK) | cut -f1)"

# -------------------------------------------------------------- boot.img ----
# zImage-dtb is an input, not something this Makefile produces: the kernel tree
# builds zImage and the DTB, appending one to the other is one `cat` away (see
# README "快速开始").  Here we only package the two blobs lk2nd wants.
boot.img: $(BOOTIMG)

$(BOOTIMG): $(ZIMAGE_DTB) initramfs
	$(PACK_BOOTIMG) $(PACK_ARGS)

$(ZIMAGE_DTB):
	@echo "ERROR: 缺少 zImage-dtb（内核 zImage 拼上 aries DTB）" >&2
	@echo "       把 zImage-dtb 放到 Makefile 同目录再 make（怎么拼见 README「快速开始」）" >&2
	@exit 1

# Re-run every check pack-bootimg.sh makes, on whatever is on disk right now.
verify:
	@test -f $(ZIMAGE_DTB) || { echo "ERROR: 缺少 zImage-dtb（放到 Makefile 同目录）" >&2; exit 1; }
	@test -f $(RAMDISK)   || { echo "ERROR: 缺少 $(patsubst $(SRC)/%,%,$(RAMDISK))，先 make" >&2; exit 1; }
	@$(PACK_BOOTIMG) --check-only $(PACK_ARGS)

# ----------------------------------------------------------------- clean ----
clean:
	rm -rf $(ROOT) $(INIT_DIR)/target
	rm -f $(SRC)/initramfs.cpio.* $(BOOTIMG) $(BOOTIMG).tmp

# ------------------------------------------------------------------ help ----
help:
	@echo '用法: make [目标] [变量=值 ...]'
	@echo ''
	@echo '目标:'
	@echo '  all (默认)     构建 $(patsubst $(SRC)/%,%,$(BOOTIMG))（= init + initramfs + 打包）'
	@echo '  init           只编译 Rust /init 到 root/init'
	@echo '  initramfs      组装 root/ 并打包成 $(patsubst $(SRC)/%,%,$(RAMDISK))'
	@echo '  boot.img       打包 zImage-dtb + initramfs 成可引导镜像'
	@echo '  verify         只校验现有产物（内核 magic、地址布局、cmdline、initramfs 格式）'
	@echo '  clean          删除构建产物（firmware/ 和 zImage-dtb 保留）'
	@echo ''
	@echo '变量（也可以写成 make 变量=值）:'
	@echo '  USERDATA_PART=$(USERDATA_PART)   DISTRO_SUBDIR=$(DISTRO_SUBDIR)'
	@echo '  ROOTFS_FSTYPE=$(ROOTFS_FSTYPE)   SHUTDOWN_DELAY=$(SHUTDOWN_DELAY)'
	@echo '  COMPRESS=$(COMPRESS)   CMDLINE="..."   BASE=$(BASE)   BOOTIMG=$(BOOTIMG)'
	@echo ''
	@echo '输入文件: zImage-dtb（内核 + DTB）、firmware/。'
	@echo '地址布局的推导见 README.md 与 scripts/pack-bootimg.sh 头部注释。'
