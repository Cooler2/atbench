#!/usr/bin/env python3
"""Run a ATBench build headlessly under QEMU and bring its output back.

Builds a bootable FreeDOS floppy holding the program under test, boots QEMU
with no display, waits for the guest to power itself off, then reads whatever
the program wrote back out of the floppy image.

QEMU's timings are meaningless for benchmarking - this exists to answer
"does it run, does it crash, is the logic right", which is exactly what is
hard to check from a Windows host. Real numbers come from 86Box and from
actual hardware.

    python tools/runqemu.py bin/spike1.exe [--args "/auto"] [--get OUT.TXT]
"""

import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fat12 import Fat12                                   # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(ROOT, "work")
FDBOOT = os.path.join(WORK, "fdboot.img")
QEMU_CANDIDATES = (
    r"D:\Programs\QEMU\qemu-system-i386.exe",
    r"G:\qemu\qemu-system-i386.exe",
)
QEMU = os.environ.get("ATBENCH_QEMU") or next(
    (path for path in QEMU_CANDIDATES if os.path.exists(path)),
    QEMU_CANDIDATES[0])
FDZIP = r"G:\86Box\DiskImages\FD14-FloppyEdition.zip"


def ensure_fdboot():
    if os.path.exists(FDBOOT):
        return
    import zipfile
    os.makedirs(WORK, exist_ok=True)
    with zipfile.ZipFile(FDZIP) as z:
        with open(FDBOOT, "wb") as fh:
            fh.write(z.read("144m/x86BOOT.img"))


def build_floppy(exe, args, out_path, capture):
    ensure_fdboot()
    src = Fat12.load(FDBOOT)

    fd = Fat12()
    fd.set_boot_sector(bytes(src.img[:512]))

    # KERNEL.SYS first, so it lands on contiguous clusters starting at 2.
    fd.write("KERNEL.SYS", src.read_path(r"\KERNEL.SYS"))
    fd.write("COMMAND.COM", src.read_path(r"\FREEDOS\BIN\COMMAND.COM"))
    fd.write("FDAPM.COM", src.read_path(r"\FREEDOS\BIN\FDAPM.COM"))

    fd.write("FDCONFIG.SYS",
             b"FILES=40\r\n"
             b"BUFFERS=20\r\n"
             b"LASTDRIVE=Z\r\n"
             b"SHELL=A:\\COMMAND.COM A:\\ /P=A:\\AUTOEXEC.BAT\r\n")

    # Console output is redirected into a file on the floppy itself; after the
    # guest powers off we read it straight back out of the image. No serial
    # console, no scraping - and it exercises the same DOS file I/O the
    # benchmark's own report writer will use.
    name = os.path.basename(exe).upper()
    auto = ("@echo off\r\n"
            "A:\\%s %s > A:\\OUT.TXT\r\n"
            "FDAPM POWEROFF\r\n" % (name, args))
    fd.write("AUTOEXEC.BAT", auto.encode("ascii"))

    with open(exe, "rb") as fh:
        fd.write(name, fh.read())

    fd.save(out_path)
    return out_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("exe")
    ap.add_argument("--args", default="/auto")
    ap.add_argument("--get", action="append", default=[],
                    help="extra file to extract from the floppy afterwards")
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--attempts", type=int, default=3)
    ap.add_argument("--cpu", default="486")
    ap.add_argument("--mem", default="16")
    opts = ap.parse_args()
    if "OUT.TXT" not in opts.get:
        opts.get.insert(0, "OUT.TXT")

    img = os.path.join(WORK, "run.img")

    # cache=writethrough so the image on the host stays current even if we
    # have to kill the guest - otherwise a hung run tells us nothing at all.
    cmd = [QEMU,
           "-M", "pc",
           "-cpu", opts.cpu,
           "-m", opts.mem,
           "-drive", "file=%s,format=raw,if=floppy,cache=writethrough" % img,
           "-boot", "a",
           "-display", "none",
           "-no-reboot",
           "-rtc", "base=localtime"]

    # Booting FreeDOS under QEMU stalls occasionally - roughly one run in
    # three - somewhere before our program starts. It is a host-side flake,
    # not something the guest program did, so just start over.
    rc, killed = -1, True
    for attempt in range(1, opts.attempts + 1):
        build_floppy(opts.exe, opts.args, img, opts.get)
        if attempt == 1:
            print("+", " ".join(cmd))
        t0 = time.time()
        try:
            rc = subprocess.call(cmd, timeout=opts.timeout)
            killed = rc != 0
        except subprocess.TimeoutExpired:
            rc, killed = -1, True
        print("attempt %d: qemu exit=%s killed=%s elapsed=%.1fs"
              % (attempt, rc, killed, time.time() - t0))
        if not killed:
            break
        if attempt < opts.attempts:
            print("   guest never powered off - retrying")

    fd = Fat12.load(img)
    print("\nfloppy contents after the run:")
    for n, s, _ in fd.listdir():
        print("   %-14s %8d" % (n, s))

    for want in opts.get:
        if "\\" in want or "/" in want:
            blob = fd.read_path(want)
        else:
            blob = fd.read(want)
        print("\n----- %s -----" % want)
        if blob is None:
            print("(not produced)")
        else:
            sys.stdout.write(blob.decode("cp437", "replace"))
            dest = os.path.join(WORK,
                                os.path.basename(want.replace("\\", "/")))
            with open(dest, "wb") as fh:
                fh.write(blob)

    if killed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
