#!/usr/bin/env python3
"""Minimal Android boot.img packer (header v0/v1/v2).

Layout follows the header that LK / lk2nd parses (app/aboot/bootimg.h):
    magic[8]
    kernel_size, kernel_addr
    ramdisk_size, ramdisk_addr
    second_size, second_addr
    tags_addr, page_size
    header_version, os_version
    name[16]
    cmdline[512]
    id[32]
    extra_cmdline[1024]
    [v1] recovery_dtbo_size, recovery_dtbo_offset(u64), header_size
    [v2] dtb_size, dtb_addr(u64)
"""

import argparse
import hashlib
import os
import struct

BOOT_MAGIC = b"ANDROID!"


def align(value, page):
    return (value + page - 1) // page * page


def num(value):
    return int(value, 0)


def os_version_encode(version, patch_level):
    """os_version field: A.B.C in bits 31..11, year-2000 in bits 10..4, month
    in bits 3..0."""
    if version in ("", "0"):
        return 0
    a, b, c = (int(x) for x in version.split("."))
    year, month = (int(x) for x in patch_level.split("-")[:2])
    version_bits = ((a & 0x7F) << 14) | ((b & 0x7F) << 7) | (c & 0x7F)
    date_bits = ((year - 2000) & 0x7F) << 4 | (month & 0xF)
    return (version_bits << 11) | date_bits


def read(path):
    if path is None:
        return b""
    with open(path, "rb") as fh:
        return fh.read()


def main():
    ap = argparse.ArgumentParser(description="pack an Android boot.img")
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--ramdisk")
    ap.add_argument("--second")
    ap.add_argument("--dtb")
    ap.add_argument("--recovery_dtbo")
    ap.add_argument("--cmdline", default="")
    ap.add_argument("--board", default="")
    ap.add_argument("--base", default="0x80000000")
    ap.add_argument("--kernel_offset", default="0x00008000")
    ap.add_argument("--ramdisk_offset", default="0x01000000")
    ap.add_argument("--second_offset", default="0x00f00000")
    ap.add_argument("--tags_offset", default="0x00000100")
    ap.add_argument("--dtb_offset", default="0x01f00000")
    ap.add_argument("--pagesize", type=int, default=2048)
    ap.add_argument("--header_version", type=int, default=0, choices=(0, 1, 2))
    ap.add_argument("--os_version", default="")
    ap.add_argument("--os_patch_level", default="2026-09")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()

    kernel = read(args.kernel)
    ramdisk = read(args.ramdisk)
    second = read(args.second)
    dtb = read(args.dtb)
    recovery_dtbo = read(args.recovery_dtbo)

    page = args.pagesize
    base = num(args.base)

    kernel_addr = base + num(args.kernel_offset)
    ramdisk_addr = base + num(args.ramdisk_offset)
    second_addr = base + num(args.second_offset)
    tags_addr = base + num(args.tags_offset)
    dtb_addr = base + num(args.dtb_offset)

    cmdline = args.cmdline.encode()
    if len(cmdline) > 512 + 1024:
        raise SystemExit("cmdline too long")
    cmdline += b"\x00" * (512 + 1024 - len(cmdline))
    cmdline_field, extra_cmdline = cmdline[:512], cmdline[512:]

    header = bytearray()
    header += BOOT_MAGIC
    header += struct.pack(
        "<10I",
        len(kernel),
        kernel_addr,
        len(ramdisk),
        ramdisk_addr,
        len(second),
        second_addr,
        tags_addr,
        page,
        args.header_version,
        os_version_encode(args.os_version, args.os_patch_level),
    )
    header += args.board.encode()[:16].ljust(16, b"\x00")
    header += cmdline_field
    header += b"\x00" * 32  # id (sha1) - optional, left empty
    header += extra_cmdline

    if args.header_version >= 1:
        header += struct.pack("<I", len(recovery_dtbo))
        header += struct.pack("<Q", 0)
        header += struct.pack("<I", align(len(header), page))
    if args.header_version >= 2:
        header += struct.pack("<I", len(dtb))
        header += struct.pack("<Q", dtb_addr)

    header_size = align(len(header), page)
    header += b"\x00" * (header_size - len(header))

    sha = hashlib.sha1()
    for blob in (kernel, ramdisk, second, dtb):
        sha.update(blob)
        padding = align(len(blob), page) - len(blob)
        sha.update(b"\x00" * padding)
    struct.pack_into("<32s", header, 576, sha.digest()[:32])

    out = bytearray(header)
    for blob in (kernel, ramdisk, second, recovery_dtbo, dtb):
        out += blob
        out += b"\x00" * (align(len(blob), page) - len(blob))

    with open(args.output, "wb") as fh:
        fh.write(out)

    print(
        "wrote %s: kernel=%d ramdisk=%d dtb=%d total=%d bytes (%.1f MiB)"
        % (args.output, len(kernel), len(ramdisk), len(dtb), len(out), len(out) / 1048576)
    )
    print(
        "kernel_addr=0x%08x ramdisk_addr=0x%08x tags_addr=0x%08x pagesize=%d"
        % (kernel_addr, ramdisk_addr, tags_addr, page)
    )


if __name__ == "__main__":
    main()
