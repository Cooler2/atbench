#!/usr/bin/env python3
"""Minimal FAT12 reader/writer for 1.44M floppy images.

Enough to build a bootable test floppy and to read back whatever the program
under test wrote to it. No subdirectories, no long names - a DOS floppy from
1994 does not need them.
"""

import os
import struct
import time

SECTOR = 512


class Fat12:
    def __init__(self, data=None):
        if data is None:
            data = self._blank()
        self.img = bytearray(data)
        (self.bps, self.spc, self.reserved, self.nfats, self.root_entries,
         self.total, self.media, self.spf) = struct.unpack_from("<HBHBHHBH",
                                                                self.img, 11)
        self.fat_off = self.reserved * self.bps
        self.root_off = (self.reserved + self.nfats * self.spf) * self.bps
        self.data_off = self.root_off + self.root_entries * 32
        self.clusters = (self.total - self.data_off // self.bps) // self.spc

    # ------------------------------------------------------------- creation

    @staticmethod
    def _blank(sectors=2880, spf=9, root_entries=224):
        img = bytearray(sectors * SECTOR)
        img[0:3] = b"\xEB\x3C\x90"
        img[3:11] = b"MSDOS5.0"
        struct.pack_into("<HBHBHHBHHHII", img, 11,
                         SECTOR, 1, 1, 2, root_entries, sectors,
                         0xF0, spf, 18, 2, 0, 0)
        img[36] = 0x00
        img[38] = 0x29
        img[39:43] = b"\x34\x12\x78\x56"
        img[43:54] = b"ATBENCH"
        img[54:62] = b"FAT12   "
        img[510:512] = b"\x55\xAA"
        # FAT id in both copies
        for n in range(2):
            off = (1 + n * spf) * SECTOR
            img[off:off + 3] = b"\xF0\xFF\xFF"
        return img

    @classmethod
    def load(cls, path):
        with open(path, "rb") as fh:
            return cls(fh.read())

    def save(self, path):
        with open(path, "wb") as fh:
            fh.write(self.img)

    # ------------------------------------------------------------- FAT access

    def _get(self, c):
        off = self.fat_off + c * 3 // 2
        v = self.img[off] | (self.img[off + 1] << 8)
        return (v >> 4) if (c & 1) else (v & 0xFFF)

    def _set(self, c, val):
        for n in range(self.nfats):
            off = (self.reserved + n * self.spf) * self.bps + c * 3 // 2
            v = self.img[off] | (self.img[off + 1] << 8)
            if c & 1:
                v = (v & 0x000F) | ((val & 0xFFF) << 4)
            else:
                v = (v & 0xF000) | (val & 0xFFF)
            self.img[off] = v & 0xFF
            self.img[off + 1] = (v >> 8) & 0xFF

    def _free_clusters(self):
        return [c for c in range(2, self.clusters + 2) if self._get(c) == 0]

    # ------------------------------------------------------ directory access

    def _entries(self):
        for i in range(self.root_entries):
            off = self.root_off + i * 32
            e = self.img[off:off + 32]
            if e[0] == 0x00:
                return
            if e[0] == 0xE5 or (e[11] & 0x08):      # deleted or volume label
                continue
            yield i, e

    def listdir(self):
        out = []
        for _, e in self._entries():
            name = e[0:8].decode("latin1").rstrip()
            ext = e[8:11].decode("latin1").rstrip()
            clus, size = struct.unpack_from("<HI", e, 26)
            out.append((name + ("." + ext if ext else ""), size, clus))
        return out

    def _chain_bytes(self, clus):
        out = bytearray()
        guard = 0
        while 2 <= clus < 0xFF8 and guard < self.clusters + 2:
            off = self.data_off + (clus - 2) * self.spc * self.bps
            out += self.img[off:off + self.spc * self.bps]
            clus = self._get(clus)
            guard += 1
        return bytes(out)

    def read_path(self, path):
        """Read a file that may live in a subdirectory, e.g.
        '\\FREEDOS\\BIN\\COMMAND.COM'. Only needed to harvest pieces out of a
        stock FreeDOS image; our own floppies are flat."""
        parts = [p for p in path.upper().replace("/", "\\").split("\\") if p]
        blob = bytes(self.img[self.root_off:self.data_off])
        for depth, part in enumerate(parts):
            found = None
            for i in range(0, len(blob), 32):
                e = blob[i:i + 32]
                if not e or e[0] == 0x00:
                    break
                if e[0] == 0xE5 or (e[11] & 0x08):
                    continue
                name = e[0:8].decode("latin1").rstrip()
                ext = e[8:11].decode("latin1").rstrip()
                if name + ("." + ext if ext else "") == part:
                    found = e
                    break
            if found is None:
                return None
            clus, size = struct.unpack_from("<HI", found, 26)
            if depth == len(parts) - 1:
                return self._chain_bytes(clus)[:size]
            if not (found[11] & 0x10):
                return None
            blob = self._chain_bytes(clus)
        return None

    def read(self, filename):
        want = filename.upper()
        for _, e in self._entries():
            name = e[0:8].decode("latin1").rstrip()
            ext = e[8:11].decode("latin1").rstrip()
            full = name + ("." + ext if ext else "")
            if full != want:
                continue
            clus, size = struct.unpack_from("<HI", e, 26)
            out = bytearray()
            guard = 0
            while 2 <= clus < 0xFF8 and guard < self.clusters + 2:
                off = self.data_off + (clus - 2) * self.spc * self.bps
                out += self.img[off:off + self.spc * self.bps]
                clus = self._get(clus)
                guard += 1
            return bytes(out[:size])
        return None

    def write(self, filename, blob, mtime=None):
        """Add a file to the root directory. Replaces an existing entry."""
        name = os.path.basename(filename).upper()
        stem, _, ext = name.partition(".")
        if len(stem) > 8 or len(ext) > 3:
            raise ValueError("%r is not a valid 8.3 name" % name)
        name8 = stem.ljust(8)[:8].encode("ascii")
        ext3 = ext.ljust(3)[:3].encode("ascii")

        self.delete(name)

        need = max(1, (len(blob) + self.spc * self.bps - 1)
                   // (self.spc * self.bps))
        free = self._free_clusters()
        if len(free) < need:
            raise IOError("no room for %s (%d clusters needed, %d free)"
                          % (name, need, len(free)))
        chain = free[:need]

        for i, c in enumerate(chain):
            self._set(c, 0xFFF if i == need - 1 else chain[i + 1])
            off = self.data_off + (c - 2) * self.spc * self.bps
            piece = blob[i * self.spc * self.bps:(i + 1) * self.spc * self.bps]
            self.img[off:off + self.spc * self.bps] = \
                piece.ljust(self.spc * self.bps, b"\x00")

        slot = self._free_slot()
        t = time.localtime(mtime if mtime else time.time())
        fat_time = (t.tm_hour << 11) | (t.tm_min << 5) | (t.tm_sec // 2)
        fat_date = ((t.tm_year - 1980) << 9) | (t.tm_mon << 5) | t.tm_mday
        e = bytearray(32)
        e[0:8] = name8
        e[8:11] = ext3
        e[11] = 0x20
        struct.pack_into("<HHHI", e, 22, fat_time, fat_date, chain[0],
                         len(blob))
        off = self.root_off + slot * 32
        self.img[off:off + 32] = e

    def _free_slot(self):
        for i in range(self.root_entries):
            off = self.root_off + i * 32
            if self.img[off] in (0x00, 0xE5):
                return i
        raise IOError("root directory full")

    def delete(self, filename):
        want = filename.upper()
        for i, e in list(self._entries()):
            name = e[0:8].decode("latin1").rstrip()
            ext = e[8:11].decode("latin1").rstrip()
            if name + ("." + ext if ext else "") != want:
                continue
            clus, _ = struct.unpack_from("<HI", e, 26)
            guard = 0
            while 2 <= clus < 0xFF8 and guard < self.clusters + 2:
                nxt = self._get(clus)
                self._set(clus, 0)
                clus = nxt
                guard += 1
            self.img[self.root_off + i * 32] = 0xE5
            return True
        return False

    def set_boot_sector(self, boot):
        """Take boot code from another image but keep our own BPB, so the
        geometry stays whatever we built."""
        bpb = bytes(self.img[11:62])
        self.img[0:SECTOR] = boot[:SECTOR]
        self.img[11:62] = bpb
