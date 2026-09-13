#!/usr/bin/env python3
"""Photograph ATBench's *graphics* screen under QEMU.

tuisnap.py reads the text buffer at B8000, which is the right answer for a
menu and no answer at all for the composite suite: that one leaves text mode
and draws a game frame, and whether the frame looks like anything is not a
question the character cells can be asked.  So this one takes the same route
into the guest - the QEMU monitor - and uses `screendump`, which renders
whatever the emulated card is showing, mode 13h and VBE alike, with no
display attached on the host side.

    python tools/gfxsnap.py bin/atbench.exe --args "/frame std" ^
        --start 8 --shots 12 --interval 2

Shots land in work/shots as PNG, converted here rather than by an image
library, so the tool needs nothing installed that the rest of the project
does not already need.
"""

import argparse
import os
import re
import struct
import subprocess
import sys
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from runqemu import QEMU, WORK                            # noqa: E402
from tuisnap import Monitor, build_floppy, COLS           # noqa: E402

SHOTS = os.path.join(WORK, "shots")


def ppm_to_png(ppm_path, png_path):
    """P6 to PNG. Both formats are eight-bit RGB in row order, so the whole
    conversion is a zlib stream and five chunk headers."""
    with open(ppm_path, "rb") as fh:
        data = fh.read()

    # Header: P6, width, height, maxval - whitespace-separated, and comment
    # lines starting with # may appear between any two of them.
    fields, pos = [], 2
    while len(fields) < 3:
        while pos < len(data) and data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            while data[pos:pos + 1] not in (b"\n", b""):
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(int(data[start:pos]))
    pixels = data[pos + 1:]
    w, h, maxval = fields
    if maxval != 255:
        raise RuntimeError("%s: maxval %d, expected 255" % (ppm_path, maxval))

    raw = bytearray()
    for y in range(h):
        raw.append(0)                       # filter: none
        raw += pixels[y * w * 3:(y + 1) * w * 3]

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload +
                struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    with open(png_path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n")
        fh.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        fh.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        fh.write(chunk(b"IEND", b""))
    return w, h


def top_rows(mon, rows=4):
    """The first few rows of the text screen, as one string. Cheaper than
    tuisnap's whole-screen read by a factor of six, which matters here: the
    poll has to be quick enough that the graphics phase has not been and gone
    by the time the program is noticed."""
    out = []
    for row in range(rows):
        dump = mon.cmd("xp /%dxh 0x%x" % (COLS, 0xB8000 + row * COLS * 2))
        for line in dump.splitlines():
            m = re.match(r"\s*[0-9a-fA-F]{6,}:\s+(.*)", line)
            if m:
                for w in re.findall(r"0x([0-9a-fA-F]{4})", m.group(1)):
                    out.append(chr(int(w, 16) & 0xFF))
    return "".join(out)


def wait_for_program(mon, text, seconds):
    """The program is up when its name is on the text screen. Same witness
    tuisnap uses, and it has to happen before any key is sent or the keys go
    to the FreeDOS prompt."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            if text in top_rows(mon):
                return True
        except RuntimeError:
            pass
        time.sleep(0.5)
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("exe")
    ap.add_argument("--args", default="")
    ap.add_argument("--keys", default="",
                    help="QEMU sendkey names to press once the program is up")
    ap.add_argument("--start", type=float, default=5.0,
                    help="seconds to wait after the keys before the first shot")
    ap.add_argument("--shots", type=int, default=10)
    ap.add_argument("--interval", type=float, default=2.0)
    ap.add_argument("--boot", type=int, default=90)
    ap.add_argument("--wait-for", default="ATBench")
    ap.add_argument("--tag", default="shot")
    ap.add_argument("--port", type=int, default=45455)
    ap.add_argument("--cpu", default="486")
    ap.add_argument("--mem", default="16")
    opts = ap.parse_args()

    os.makedirs(SHOTS, exist_ok=True)
    img = os.path.join(WORK, "gfx.img")
    build_floppy(opts.exe, opts.args, img)

    cmd = [QEMU,
           "-M", "pc",
           "-cpu", opts.cpu,
           "-m", opts.mem,
           "-drive", "file=%s,format=raw,if=floppy,cache=writethrough" % img,
           "-boot", "a",
           "-display", "none",
           "-no-reboot",
           "-rtc", "base=localtime",
           "-monitor", "tcp:127.0.0.1:%d,server,nowait" % opts.port]
    print("+", " ".join(cmd))
    proc = subprocess.Popen(cmd)
    made = []
    try:
        mon = Monitor(opts.port)
        if not wait_for_program(mon, opts.wait_for, opts.boot):
            print("the program never appeared on the text screen")
        for tok in opts.keys.replace(",", " ").split():
            mon.cmd("sendkey %s" % tok)
            time.sleep(0.4)

        time.sleep(opts.start)
        for i in range(opts.shots):
            ppm = os.path.join(SHOTS, "%s%02d.ppm" % (opts.tag, i))
            png = os.path.join(SHOTS, "%s%02d.png" % (opts.tag, i))
            mon.cmd("screendump %s" % ppm.replace("\\", "/"))
            if os.path.exists(ppm):
                w, h = ppm_to_png(ppm, png)
                os.remove(ppm)
                made.append(png)
                print("   %s  %dx%d" % (png, w, h))
            else:
                print("   %s: screendump produced nothing" % ppm)
            time.sleep(opts.interval)
        mon.close()
    finally:
        time.sleep(1)
        proc.kill()
    print("\n%d shots in %s" % (len(made), SHOTS))


if __name__ == "__main__":
    main()
