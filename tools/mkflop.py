#!/usr/bin/env python3
"""Build a 1.44M FAT12 floppy image containing the given files in its root.

Used two ways:
  * hand the image to 86Box as drive A: for a quick run inside an emulator;
  * write it to a real floppy (or feed it to a Gotek) to get a build onto
    actual hardware.

The image is data-only - no boot code - so the machine still boots from its
hard disk and you just run A:\\WHATEVER.EXE.

    python mkflop.py out.img FILE [FILE ...]
"""

import os
import struct
import sys

SECTOR = 512
SECTORS = 2880           # 1.44M
RESERVED = 1
FAT_COUNT = 2
FAT_SECTORS = 9
ROOT_ENTRIES = 224
ROOT_SECTORS = ROOT_ENTRIES * 32 // SECTOR      # 14
DATA_START = RESERVED + FAT_COUNT * FAT_SECTORS + ROOT_SECTORS   # 33
DATA_CLUSTERS = SECTORS - DATA_START


def boot_sector(label=b"ATBENCH"):
    bs = bytearray(SECTOR)
    bs[0:3] = b"\xEB\x3C\x90"
    bs[3:11] = b"MSDOS5.0"
    struct.pack_into("<HBHBHHBHHHII", bs, 11,
                     SECTOR,        # bytes per sector
                     1,             # sectors per cluster
                     RESERVED,      # reserved sectors
                     FAT_COUNT,     # number of FATs
                     ROOT_ENTRIES,  # root entries
                     SECTORS,       # total sectors
                     0xF0,          # media descriptor
                     FAT_SECTORS,   # sectors per FAT
                     18,            # sectors per track
                     2,             # heads
                     0,             # hidden sectors
                     0)             # large total sectors
    bs[36] = 0x00                   # drive number
    bs[38] = 0x29                   # extended boot signature
    bs[39:43] = b"\x34\x12\x78\x56"  # volume serial
    bs[43:54] = label.ljust(11)[:11]
    bs[54:62] = b"FAT12   "
    # No boot code: if someone boots from it, say so rather than hanging.
    msg = b"Not a boot disk\r\n"
    bs[62:62 + len(msg)] = msg
    bs[510:512] = b"\x55\xAA"
    return bytes(bs)


def short_name(path):
    """Fold a host filename into an 8.3 entry. Names are already DOS-shaped
    in this project, so anything longer is a mistake worth reporting."""
    base = os.path.basename(path).upper()
    stem, _, ext = base.partition(".")
    if len(stem) > 8 or len(ext) > 3:
        raise SystemExit("mkflop: %r is not a valid 8.3 name" % base)
    return stem.ljust(8)[:8].encode("ascii"), ext.ljust(3)[:3].encode("ascii")


def dir_entry(name8, ext3, first_cluster, size, mtime):
    import time
    t = time.localtime(mtime)
    fat_time = (t.tm_hour << 11) | (t.tm_min << 5) | (t.tm_sec // 2)
    fat_date = ((t.tm_year - 1980) << 9) | (t.tm_mon << 5) | t.tm_mday
    e = bytearray(32)
    e[0:8] = name8
    e[8:11] = ext3
    e[11] = 0x20                                  # archive
    struct.pack_into("<HHHI", e, 22, fat_time, fat_date, first_cluster, size)
    return bytes(e)


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)

    out = sys.argv[1]
    files = sys.argv[2:]

    fat = [0] * (DATA_CLUSTERS + 2)
    fat[0], fat[1] = 0xFF0, 0xFFF

    data = bytearray()
    entries = []
    next_cluster = 2

    for path in files:
        with open(path, "rb") as fh:
            blob = fh.read()
        need = (len(blob) + SECTOR - 1) // SECTOR or 1
        if next_cluster - 2 + need > DATA_CLUSTERS:
            raise SystemExit("mkflop: out of space adding %s" % path)

        first = next_cluster
        for i in range(need):
            c = first + i
            fat[c] = 0xFFF if i == need - 1 else c + 1
        next_cluster += need

        data += blob.ljust(need * SECTOR, b"\x00")
        name8, ext3 = short_name(path)
        entries.append(dir_entry(name8, ext3, first,
                                 len(blob), os.path.getmtime(path)))

    # FAT12: two entries packed into three bytes.
    fat_bytes = bytearray(FAT_SECTORS * SECTOR)
    for i in range(0, len(fat), 2):
        a = fat[i] & 0xFFF
        b = fat[i + 1] & 0xFFF if i + 1 < len(fat) else 0
        off = i * 3 // 2
        if off + 2 < len(fat_bytes):
            fat_bytes[off] = a & 0xFF
            fat_bytes[off + 1] = ((a >> 8) & 0x0F) | ((b & 0x0F) << 4)
            fat_bytes[off + 2] = (b >> 4) & 0xFF

    root = bytearray(ROOT_SECTORS * SECTOR)
    if len(entries) > ROOT_ENTRIES:
        raise SystemExit("mkflop: too many files for the root directory")
    for i, e in enumerate(entries):
        root[i * 32:(i + 1) * 32] = e

    img = bytearray()
    img += boot_sector()
    img += fat_bytes
    img += fat_bytes
    img += root
    img += data
    img = img.ljust(SECTORS * SECTOR, b"\x00")[:SECTORS * SECTOR]

    with open(out, "wb") as fh:
        fh.write(img)

    used = sum((len(open(f, "rb").read()) + SECTOR - 1) // SECTOR
               for f in files)
    print("%s: %d file(s), %d KB used, %d KB free"
          % (out, len(files), used * SECTOR // 1024,
             (DATA_CLUSTERS - used) * SECTOR // 1024))


if __name__ == "__main__":
    main()
