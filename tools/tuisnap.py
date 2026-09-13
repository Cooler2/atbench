#!/usr/bin/env python3
"""Photograph ATBench's text screen under QEMU, one keystroke at a time.

runqemu.py answers "did it run" by redirecting output to a file - which is
exactly the case where the UI layer switches itself off (DESIGN 13.5), so it
can never see a menu. This one runs the program on the console instead and
reads the text screen straight out of guest memory at B8000 through the QEMU
monitor, so what comes back is the characters *and* the attributes: whether a
row is highlighted is a fact here, not an impression.

    python tools/tuisnap.py bin/atbench.exe --keys "down down ret"

Keys are QEMU sendkey names: up down left right ret esc pgup pgdn home end,
plus plain digits and letters. Prefix a key with a number to repeat it
("3*down"), and use "." for "take another shot without pressing anything".
"""

import argparse
import os
import re
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fat12 import Fat12                                   # noqa: E402
from runqemu import QEMU, WORK, ensure_fdboot, FDBOOT     # noqa: E402

ROWS, COLS = 25, 80


def build_floppy(exe, args, out_path):
    """Same floppy as runqemu, minus the redirect and minus the poweroff:
    the program has to write to the console for there to be anything to look
    at, and it has to still be sitting in its menu when we get there."""
    ensure_fdboot()
    src = Fat12.load(FDBOOT)

    fd = Fat12()
    fd.set_boot_sector(bytes(src.img[:512]))
    fd.write("KERNEL.SYS", src.read_path(r"\KERNEL.SYS"))
    fd.write("COMMAND.COM", src.read_path(r"\FREEDOS\BIN\COMMAND.COM"))

    fd.write("FDCONFIG.SYS",
             b"FILES=40\r\n"
             b"BUFFERS=20\r\n"
             b"LASTDRIVE=Z\r\n"
             b"SHELL=A:\\COMMAND.COM A:\\ /P=A:\\AUTOEXEC.BAT\r\n")

    name = os.path.basename(exe).upper()
    auto = ("@echo off\r\n"
            "cls\r\n"
            "A:\\%s %s\r\n" % (name, args))
    fd.write("AUTOEXEC.BAT", auto.encode("ascii"))

    with open(exe, "rb") as fh:
        fd.write(name, fh.read())

    fd.save(out_path)
    return out_path


class Monitor:
    PROMPT = b"(qemu) "

    def __init__(self, port, timeout=30):
        deadline = time.time() + timeout
        while True:
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), 5)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.3)
        self.buf = b""
        self._read_to_prompt()

    def _read_to_prompt(self, timeout=30):
        deadline = time.time() + timeout
        while self.PROMPT not in self.buf:
            self.sock.settimeout(max(0.2, deadline - time.time()))
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            self.buf += chunk
        head, _, self.buf = self.buf.partition(self.PROMPT)
        return head.decode("latin-1", "replace")

    def cmd(self, line):
        self.sock.sendall(line.encode("ascii") + b"\n")
        out = self._read_to_prompt()
        # The monitor echoes what it was told, terminal-style; drop that.
        return out.replace(line, "", 1)

    def close(self):
        try:
            self.sock.sendall(b"quit\n")
        except OSError:
            pass
        self.sock.close()


def read_screen(mon):
    """The 25x80 text buffer as a list of (char, attribute) rows."""
    words = []
    # The monitor prints a bounded number of words per command, so ask by the
    # row: 80 words each, 25 times, and the answer is never truncated.
    for row in range(ROWS):
        out = mon.cmd("xp /%dxh 0x%x" % (COLS, 0xB8000 + row * COLS * 2))
        # Only the lines the dump itself produced: the monitor echoes the
        # command back one character at a time, and "0xb800" in that echo
        # looks exactly like a word of screen memory.
        found = []
        for line in out.splitlines():
            m = re.match(r"\s*[0-9a-fA-F]{6,}:\s+(.*)", line)
            if m:
                found.extend(re.findall(r"0x([0-9a-fA-F]{4})", m.group(1)))
        if len(found) != COLS:
            raise RuntimeError("row %d: got %d words, wanted %d\n%s"
                               % (row, len(found), COLS, out))
        words.append([int(w, 16) for w in found])
    return words


def render(words, brief=False):
    """The screen as text, followed by wherever the attributes stop being
    ordinary - which is how a highlighted row proves it is highlighted."""
    lines = ["      +" + "-" * COLS + "+"]
    for y, row in enumerate(words):
        text = "".join(bytes([w & 0xFF]).decode("cp437", "replace")
                       for w in row)
        text = "".join(c if c.isprintable() else " " for c in text)
        if brief and not text.strip():
            continue
        lines.append("   %2d |%s|" % (y, text.rstrip()))
    lines.append("      +" + "-" * COLS + "+")

    lines.append("   attributes other than 07:")
    seen = False
    for y, row in enumerate(words):
        runs, start, cur = [], None, None
        for x in range(COLS + 1):
            a = (row[x] >> 8) if x < COLS else None
            if a != cur:
                if cur is not None and cur != 0x07:
                    runs.append("%d-%d:%02X" % (start, x - 1, cur))
                start, cur = x, a
        if runs:
            seen = True
            lines.append("   %2d   %s" % (y, "  ".join(runs)))
    if not seen:
        lines.append("   (none - the whole screen is plain text)")
    return "\n".join(lines)


def expand(keys, default_wait):
    """"3*down" repeats a key, "1@60" waits 60s for that one before the shot,
    "." takes another shot without pressing anything."""
    out = []
    for tok in keys.replace(",", " ").split():
        wait = default_wait
        if "@" in tok:
            tok, _, w = tok.partition("@")
            wait = float(w)
        n = 1
        if "*" in tok:
            n, _, tok = tok.partition("*")
            n = int(n)
        out.extend([(tok, wait)] * n)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("exe")
    ap.add_argument("--args", default="")
    ap.add_argument("--keys", default="",
                    help="keys to press, one shot taken after each")
    ap.add_argument("--boot", type=int, default=90,
                    help="seconds to wait for the program to appear")
    ap.add_argument("--settle", type=float, default=1.0,
                    help="seconds between a keystroke and its shot")
    ap.add_argument("--wait-for", default="ATBench",
                    help="text that says the program is up")
    ap.add_argument("--brief", action="store_true",
                    help="leave out the blank rows")
    ap.add_argument("--port", type=int, default=45454)
    ap.add_argument("--cpu", default="486")
    ap.add_argument("--mem", default="16")
    opts = ap.parse_args()

    img = os.path.join(WORK, "tui.img")
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
    print("+ " + " ".join(cmd))
    proc = subprocess.Popen(cmd)
    mon = None
    try:
        mon = Monitor(opts.port)

        deadline = time.time() + opts.boot
        while True:
            words = read_screen(mon)
            flat = "".join(bytes([w & 0xFF]).decode("cp437", "replace")
                           for row in words for w in row)
            if opts.wait_for in flat:
                break
            if time.time() > deadline:
                print(render(words, opts.brief))
                raise SystemExit("never saw %r on screen" % opts.wait_for)
            time.sleep(1.0)

        print("\n===== boot =====")
        print(render(words, opts.brief))

        for key, wait in expand(opts.keys, opts.settle):
            if key != ".":
                mon.cmd("sendkey %s" % key)
            time.sleep(wait)
            print("\n===== after %s =====" % key)
            print(render(read_screen(mon), opts.brief))
    finally:
        if mon is not None:
            mon.close()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    main()
