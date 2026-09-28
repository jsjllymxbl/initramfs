#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Pack zImage-dtb + initramfs.cpio.* into the Android boot.img that lk2nd
# expects, asserting the address layout constraints on the way.
#
# 地址布局（这块板 + lk2nd + CONFIG_AUTO_ZRELADDR）：
#
#   * 内核必须落在 0xX0008000（X 为 0x08000000 的整数倍）上，因为解压器用
#     zreladdr = (pc & 0xF8000000) + 0x8000。只有落在这类地址上 zreladdr 才等于
#     自己（原地解压）；否则解压器会先把压缩镜像和 malloc 区搬到自己后面再解压。
#
#   * 那类地址里最小的是 0x80008000，而 0x80000000-0x80200000 是 SMEM 保留区
#     （RPM/SMD/wcnss_pil 都在写它），内核解压进去会砸掉 RPM 通道。所以内核地址的
#     下限是 0x88008000。
#
#   * 原版 lk2nd 的段映射表（platform/msm8960/platform.c 的 mmu_section_table，用
#     arm_mmu_map_section 建，建完不再动）只有 0x80200000+128MB、0x90000000+768MB 和
#     它自己那 1 MiB（0x88f00000），0x88200000-0x90000000 是空洞。把 kernel/ramdisk/
#     tags 放进空洞，lk2nd 的 memmove 会 translation fault → data abort → 复位回
#     fastboot（2026-09-28 用 BASE=0x88000000 实测）。已给 lk2nd 补上映射：拆成
#     0x88200000+13MB 和 0x89000000+112MB 两条（不能一条 126MB 盖过去——表内后写的
#     赢，而 KERNEL_MEMORY 带 XN，会把 lk2nd 自己的代码段变成不可执行）。补映射之后
#     0x88008000 可用，也是本脚本的默认；未补映射的 lk2nd 仍需 ≥0x90008000。
#
#   * 内核加载地址还决定 memstart_addr（PHYS_OFFSET）：内核会丢弃低于自己加载地址
#     的整段内存（"OF: fdt: Ignoring memory range ..."）。所以地址越低可用内存越多
#     ——0x90000000 丢掉 254 MiB，0x88000000 只丢 126 MiB，白捡 128 MiB。这也是唯一
#     能把这些内存要回来的旋钮。
#
#   * 上限：压缩后的内核不能长到 lk2nd 自己那 1 MiB（0x88f00000-0x89000000，
#     MEMBASE/MEMSIZE）上，否则 lk2nd 的 overlap 检查直接拒绝启动。现在 9.7 MiB，
#     还有 ~5 MiB 余量。
#
#   * initrd 与 DTB 必须在内核之上（内核丢弃低于自身加载地址的内存），且离内核至少
#     32 MiB：解压器会把压缩镜像连同它的 malloc/栈搬到自己后面（实测到 +33 MiB），
#     踩坏过放在那儿的 initrd（"invalid magic at start of compressed archive"）。
#
#   * 三者都不能落进 DTS 里 no-map 的 WCNSS 保留区（0x8f000000 + 7 MiB）。
#
#   * BASE 还是 lk2nd 的 SCRATCH_ADDR（target/msm8960/rules.mk）：flash 引导时整个
#     boot.img 会被先读进 0x90000000，kernel/ramdisk/tags 的目标地址天然和镜像自身在
#     内存里重叠。lk2nd 的 boot_linux_from_mmc() 曾先 memmove 内核再搬 ramdisk，而
#     ramdisk 源紧跟内核源之后，内核目标区会盖掉 ramdisk 源的头
#     （(kernel_addr-image_addr)-page_size = 30 KiB）—— fastboot boot 正常（cmd_boot
#     是先搬 ramdisk）、刷进 boot 分区却报 "invalid magic at start of compressed
#     archive" 的根因（2026-09-28 实测确认，已把 lk2nd 的顺序改成和 cmd_boot 一致）。
#     BASE=0x88000000 时内核目标区整体在 scratch 之下，与顺序无关，天然免疫。
#     换用未修复的 lk2nd 且 BASE=0x90000000 时，唯一绕法是把 BASE 抬到
#     scratch+镜像大小之上（≥0x91008000，多丢 16 MiB 内存，且镜像不能长过 16 MiB）。
#
#   * boot 分区开头 512 KiB 是 lk2nd 自己（虚拟出单独的 lk2nd 分区），boot.img 由
#     lk2nd 的 fastboot 自动带 512 KiB 偏移刷入，必须小于分区大小减 512 KiB。
set -euo pipefail

PROG=${0##*/}

KERNEL=
RAMDISK=
OUTPUT=
MKBOOTIMG=
CMDLINE=
CHECK_ONLY=0

BASE=0x88000000
KERNEL_OFFSET=0x00008000
RAMDISK_OFFSET=0x04000000
TAGS_OFFSET=0x05000000
PAGESIZE=2048
BOARD=aries

# Minimum initrd-to-kernel distance; anything closer and the decompressor can
# trample the initrd.
MIN_GAP=$((32 * 1024 * 1024))
CMDLINE_MAX=1024

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

human() { awk -v b="$1" 'BEGIN { printf "%.2f MiB", b / 1048576 }'; }

usage() {
    cat <<EOF
用法: $PROG --kernel zImage-dtb --ramdisk initramfs.cpio.lz4 -o boot.img [选项]

选项:
  --kernel FILE           已拼接 DTB 的 ARM zImage
  --ramdisk FILE          initramfs 归档（gzip/lz4/未压缩 cpio 均可）
  --output FILE, -o FILE  输出的 boot.img
  --cmdline STR           内核命令行
  --base ADDR             基地址（默认 $BASE）
  --kernel-offset ADDR    默认 $KERNEL_OFFSET
  --ramdisk-offset ADDR   默认 $RAMDISK_OFFSET
  --tags-offset ADDR      默认 $TAGS_OFFSET
  --pagesize N            默认 $PAGESIZE
  --board NAME            默认 $BOARD
  --mkbootimg FILE        打包脚本（默认 <repo>/scripts/mkbootimg.py）
  --check-only            只做全部校验、不生成 boot.img（make verify 用）
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        --kernel)         KERNEL=${2:?}; shift 2 ;;
        --ramdisk)        RAMDISK=${2:?}; shift 2 ;;
        --output|-o)      OUTPUT=${2:?}; shift 2 ;;
        --cmdline)        CMDLINE=${2-}; shift 2 ;;
        --base)           BASE=${2:?}; shift 2 ;;
        --kernel-offset)  KERNEL_OFFSET=${2:?}; shift 2 ;;
        --ramdisk-offset) RAMDISK_OFFSET=${2:?}; shift 2 ;;
        --tags-offset)    TAGS_OFFSET=${2:?}; shift 2 ;;
        --pagesize)       PAGESIZE=${2:?}; shift 2 ;;
        --board)          BOARD=${2:?}; shift 2 ;;
        --mkbootimg)      MKBOOTIMG=${2:?}; shift 2 ;;
        --check-only)     CHECK_ONLY=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) die "未知选项：$1（用 --help 看用法）" ;;
    esac
done

[ -n "$KERNEL" ]  || die "缺少 --kernel"
[ -n "$RAMDISK" ] || die "缺少 --ramdisk"
[ -f "$KERNEL" ]  || die "$KERNEL 不存在"
[ -f "$RAMDISK" ] || die "$RAMDISK 不存在"

# --check-only stops here, so neither the packer nor python3 is needed for it.
if [ "$CHECK_ONLY" != 1 ]; then
    [ -n "$OUTPUT" ] || die "缺少 --output"
    if [ -z "$MKBOOTIMG" ]; then
        MKBOOTIMG=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)/mkbootimg.py
    fi
    [ -f "$MKBOOTIMG" ] || die "$MKBOOTIMG 不存在"
    command -v python3 >/dev/null || die "缺少 python3"
fi

# ---------- 镜像头校验 ----------
# ARM zImage 在偏移 0x24 有 magic 0x016f2818；FDT 在偏移 0 有 magic 0xd00dfeed。
# 逐字节比较，避免依赖本机字节序。
magic_at() { od -An -tx1 -j "$2" -N "${3:-4}" "$1" | tr -d ' \n'; }

[ "$(magic_at "$KERNEL" 36)" = "18286f01" ] ||
    die "$KERNEL 不是 ARM zImage（偏移 0x24 的 magic 是 '$(magic_at "$KERNEL" 36)'）"

# initramfs: 内核只认 lib/decompress.c 里 compressed_formats[] 列的几种 magic，
# 外加未压缩的 newc cpio。归档没打全或压根是空的，在这里就报错，而不是刷进去
# 之后卡在 "Initramfs unpacking failed"。
RAMDISK_MAGIC=$(magic_at "$RAMDISK" 0 6)
case $RAMDISK_MAGIC in
    1f8b*)           RAMDISK_TYPE=gzip ;;
    02214c18*)       RAMDISK_TYPE='lz4 (legacy)' ;;
    04224d18*)       RAMDISK_TYPE='lz4' ;;
    425a68*)         RAMDISK_TYPE=bzip2 ;;
    5d0000*)         RAMDISK_TYPE=lzma ;;
    fd377a585a00*)   RAMDISK_TYPE=xz ;;
    894c*)           RAMDISK_TYPE=lzo ;;
    28b52ffd*)       RAMDISK_TYPE=zstd ;;
    303730373031*|303730373032*) RAMDISK_TYPE='cpio (uncompressed)' ;;
    *) die "$RAMDISK 不是内核认识的 initramfs（magic=$RAMDISK_MAGIC）" ;;
esac

# ---------- 地址布局断言 ----------
# 见脚本头部注释。这些都是硬约束，违反任何一条都会做出一个刷进去也起不来的
# boot.img，所以在打包前全部断言掉。
LK2ND_ADDR=0x88f00000         # lk2nd 自己（MEMBASE + MEMSIZE = 1 MiB）
LK2ND_SIZE=$((1024 * 1024))
WCNSS_ADDR=0x8f000000         # DTS 里 no-map 的 WCNSS 固件区
WCNSS_SIZE=$((7 * 1024 * 1024))
MEM_NODE_ADDR=0x80200000      # 内存节点起点，用来算丢了多少内存
# 解压器把自己的镜像 + malloc + 栈搬到解压后的内核后面，实测到内核地址 +33 MiB
DECOMPRESSOR_FOOTPRINT=$((MIN_GAP + 0x200000))

KADDR=$((BASE + KERNEL_OFFSET))
RADDR=$((BASE + RAMDISK_OFFSET))
TADDR=$((BASE + TAGS_OFFSET))
KSIZE=$(stat -c %s "$KERNEL")
RSIZE=$(stat -c %s "$RAMDISK")

(( KADDR == (KADDR & 0xF8000000) + 0x8000 )) ||
    die "kernel_addr=0x$(printf %08x "$KADDR") 不满足 zreladdr=(pc & 0xF8000000)+0x8000：解压器会把内核搬到别处再解压"

(( KADDR >= 0x88008000 )) ||
    die "kernel_addr=0x$(printf %08x "$KADDR") 太低：再往下 zreladdr 就落到 0x80008000 的 SMEM 保留区里了"

(( RADDR > KADDR )) || die "ramdisk_addr 必须在内核之上（内核会丢弃低于自身加载地址的整段内存）"
(( TADDR > KADDR )) || die "tags_addr 必须在内核之上"
(( RADDR - KADDR >= MIN_GAP )) ||
    die "initrd 离内核只有 $(( (RADDR - KADDR) / 1048576 )) MiB，解压器的工作区会踩坏它"

# [addr, addr+size) 与 [region_addr, region_addr+region_size) 不能有任何重叠
check_outside() {
    local what=$1 addr=$2 size=$3 region=$4 region_addr=$5 region_size=$6
    if (( addr < region_addr + region_size && addr + size > region_addr )); then
        die "$what=0x$(printf %08x "$addr") (+0x$(printf %x "$size")) 和 $region（0x$(printf %08x "$region_addr")-0x$(printf %08x $((region_addr + region_size)))）重叠"
    fi
}

# lk2nd 自己那 1 MiB：压缩后的内核整段都在里面的话它会直接拒绝启动（它的
# check_aboot_addr_range_overlap）。解压后的内核盖上去没关系 —— 那时 lk2nd 早就跳走了。
check_outside kernel  "$KADDR" "$KSIZE" "lk2nd" "$LK2ND_ADDR" "$LK2ND_SIZE"
check_outside ramdisk "$RADDR" "$RSIZE" "lk2nd" "$LK2ND_ADDR" "$LK2ND_SIZE"
check_outside tags    "$TADDR" 65536    "lk2nd" "$LK2ND_ADDR" "$LK2ND_SIZE"

# WCNSS 保留区里跑着 WiFi 固件，连解压器的工作区都不能压进去。
check_outside kernel  "$KADDR" "$DECOMPRESSOR_FOOTPRINT" "WCNSS 保留区" "$WCNSS_ADDR" "$WCNSS_SIZE"
check_outside ramdisk "$RADDR" "$RSIZE"                  "WCNSS 保留区" "$WCNSS_ADDR" "$WCNSS_SIZE"
check_outside tags    "$TADDR" 65536                     "WCNSS 保留区" "$WCNSS_ADDR" "$WCNSS_SIZE"

# 段映射空洞（0x88200000-0x90000000，见头部注释）在 2026-09-28 之后的 lk2nd 里已有
# 映射（两条：0x88200000+13MB、0x89000000+112MB），不再警告；若换回未补映射的 lk2nd，
# kernel/ramdisk/tags 落在空洞里会 data abort 复位回 fastboot。

# ---------- cmdline 长度 ----------
CLEN=${#CMDLINE}
(( CLEN <= CMDLINE_MAX )) || die "cmdline 有 $CLEN 字节，超过内核 COMMAND_LINE_SIZE($CMDLINE_MAX)"
(( CLEN <= 512 )) || warn "cmdline 有 $CLEN 字节，会溢到 mkbootimg 的 extra_cmdline 字段（>512 由 lk2nd 拼接，注意其行为）"

# ---------- 打包 ----------
if [ "$CHECK_ONLY" = 1 ]; then
    log "校验通过：zImage + $RAMDISK_TYPE initramfs，地址布局/长度都没问题"
    printf '  %-12s %s (%s)\n' "kernel"  "$KERNEL"  "$(human "$(stat -c %s "$KERNEL")")"
    printf '  %-12s %s (%s)\n' "ramdisk" "$RAMDISK" "$(human "$(stat -c %s "$RAMDISK")")"
    printf '  %-12s %s\n' "initramfs" "$RAMDISK_TYPE"
    printf '  %-12s %d B\n' "cmdline" "$CLEN"
    printf '  %-12s 0x%08x（内核从这儿往上的内存才认，丢掉 %s MiB）\n' \
        "memstart" "$BASE" "$(( (BASE - MEM_NODE_ADDR) / 1048576 ))"
    exit 0
fi

# 先写临时文件再 mv，失败时不会留下半截 boot.img
python3 "$MKBOOTIMG" \
    --kernel "$KERNEL" \
    --ramdisk "$RAMDISK" \
    --cmdline "$CMDLINE" \
    --base "$BASE" \
    --kernel_offset "$KERNEL_OFFSET" \
    --ramdisk_offset "$RAMDISK_OFFSET" \
    --tags_offset "$TAGS_OFFSET" \
    --pagesize "$PAGESIZE" \
    --board "$BOARD" \
    -o "$OUTPUT.tmp" >/dev/null

# 回读包头：mkbootimg 若哪天写错格式，这里立刻报错而不是刷机时才发现
[ "$(magic_at "$OUTPUT.tmp" 0 8)" = "414e44524f494421" ] || die "boot magic 不是 'ANDROID!'"
[ "$(stat -c %s "$OUTPUT.tmp")" -gt "$(stat -c %s "$KERNEL")" ] || die "boot.img 比内核还小，明显不对"

mv -f "$OUTPUT.tmp" "$OUTPUT"

# ---------- 小结 ----------
printf '\n'
log "boot.img: $OUTPUT ($(human "$(stat -c %s "$OUTPUT")"))"
printf '  %-12s %s (%s)\n' "kernel"   "$KERNEL"  "$(human "$(stat -c %s "$KERNEL")")"
printf '  %-12s %s (%s, %s)\n' "ramdisk" "$RAMDISK" "$(human "$(stat -c %s "$RAMDISK")")" "$RAMDISK_TYPE"
printf '  %-12s 0x%08x\n' "kernel_addr" "$KADDR"
printf '  %-12s 0x%08x\n' "ramdisk_addr" "$RADDR"
printf '  %-12s 0x%08x\n' "tags_addr" "$TADDR"
printf '  %-12s 0x%08x（丢掉 %s MiB，内核只认这之上的内存）\n' \
    "memstart" "$BASE" "$(( (BASE - MEM_NODE_ADDR) / 1048576 ))"
printf '  %-12s %d B\n'   "cmdline" "$CLEN"
printf '\n  fastboot boot %s\n\n' "$OUTPUT"
