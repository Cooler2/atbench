# ATBench

**A benchmark for real DOS machines, 286 through Pentium MMX — built to run
on the actual hardware, not guessed from a spec sheet.**

*AT as in PC/AT: the line of machines this covers, from the 286 that started
it to the last Socket 7 board that ended it.*

- **Four numbers, not one** — CPU, RAM, video and disk scored separately, so
  you see what a machine is actually good and bad at
- **One binary, every era** — hand-written 16-bit assembly per test, gated by
  runtime CPU detection; the same `.EXE` runs on a 286 and a Pentium MMX, and
  each gets the fastest kernel it can actually execute
- **A real game frame, not a synthetic loop** — a composite test draws an
  actual rotozoomed, sprited game frame in three sizes and reports real FPS
- **Self-checking** — every suite verifies its own output is *correct*, not
  just fast, so a broken kernel can't win by cheating
- **Real hardware first** — built and checked against real DOS machines, not
  just emulators

**Try it if** you collect, restore or tinker with real DOS-era hardware and
want numbers you can trust and compare — not one score to brag about.

```
ATBench report
==============

[System]
CPU: Pentium (586-class), 120 MHz measured
FPU: 387-class (affine, FSIN)  MMX: 0
RAM: 640K conventional, 409K free, XMS 7104K
Video: VGA colour  BIOS: S3 86C775/86C785 Video BIOS. Version 1.0
VBE: 1.2  1024 KB  S3 Incorporated. 86C775/86C785
DOS: 6.22   Disks: 1 floppy, 1 hard

[Summary]
CPU    [################################-.......]    386.4
RAM    [###############################-........]    332.3
Video  [###########################.............]    142.6
Disk   [################################........]    351.9
Frame  [#############################...........]    200.2
```

*(a real run, on a Pentium/120 with an S3 Trio card — the full report has
four more sections like this, one per suite, down to the per-test numbers)*

**Status: iteration 1 in progress.** CPU, RAM and video suites are implemented
and validated on real hardware; disk and the composite frame suite pass their
correctness checks under QEMU and are still waiting on a wider spread of real
machines. See [Known issues](#known-issues) below.

## Quick start

Don't want to set up a toolchain? Every push builds `atbench.exe` in CI with
the same recipe below — grab it from the latest GitHub Actions run, or from a
tagged Release.

### Building from source

Cross-compiled with the official FPC 3.2.2 i8086-msdos cross-compiler, 16-bit
real mode DOS, `-Cp80286` so the compiler never emits an opcode newer than a
286 — anything past that is hand-written `asm`, dispatched at runtime after
the CPU is identified.

The [official cross-compiler package](https://sourceforge.net/projects/freepascal/files/msdos/3.2.2/)
ships the medium memory model RTL only; this project needs the large model
(`build.bat` explains why). Building it is a one-time step, done from the
[FPC 3.2.2 source package](https://sourceforge.net/projects/freepascal/files/Source/3.2.2/):

```
make -C rtl clean all OS_TARGET=msdos CPU_TARGET=i8086 SUB_TARGET=large \
  OPT="-WmLarge -Cp80286 -n -CX -XX" PP=<path to ppcross8086>
```

`-n -CX -XX` are part of the recipe, not decoration: with no `fpc.cfg` to
supply them the system unit's code does not fit in one 64K code segment and
the build stops at `Code segment too large` - which is why a machine whose
own config already says `-CX` builds this and a clean one does not.

Copy the resulting `rtl/units/i8086-msdos/*.ppu`, `*.a` and `*.o` into
`<fpc root>/units/i8086-msdos-large/rtl`, next to `bin/<host>/ppcross8086`.
The `.o` files are the start-up code - `prt0l.o` is this model's - and
nothing links without them. On a Linux host three more details differ, and
`.github/workflows/build.yml` handles all three, so read it as the working
reference: the Makefile assembles that start-up code by calling `msdos-nasm`
(a symlink to plain `nasm` is enough), it appends the target's `.exe` to
whatever `PP` names and wants that path absolute, and it leaves the units in
`rtl/units/msdos` rather than `rtl/units/i8086-msdos`. Once
the toolchain is in place (`build.bat` looks for it under a few common
roots, or point `ATFPC` at it):

```
build atbench
```

produces `bin\atbench.exe`. Three ways to run it, in increasing order of how
much the numbers mean:

**Headless under QEMU**, for "does it run, does it crash, is the logic
right" — QEMU's *timings* are meaningless, this is a correctness loop:

```
python tools\runqemu.py bin\atbench.exe --args "/auto /fdd /emu" --cpu pentium2
```

**86Box**, for real chipsets and video cards with plausible timings.

**Real hardware** — the only source of numbers worth keeping. Write a plain
FAT12 floppy with `tools\mkflop.py`, run `ATBENCH.EXE` from the hard disk (the
disk suite exercises whichever drive it's given), and either drive the menu
by hand or script it:

```
python tools\mkflop.py work\at.img bin\atbench.exe
ATBENCH /auto /label 486DX2-66 turbo on /notes Abit AB-PI4, 256K L2 WB
```

`/cpu`, `/ram`, `/video`, `/disk` or `/auto` pick suites; `/frame low|std|high`
runs one tier of the composite frame suite (kept out of `/auto` — the tier is
a decision about the machine in front of you, not something to guess);
`/safe` skips the XMS/EMS/VBE probes that hand control to someone else's
resident code; `/emu` marks a run as emulated, since nothing detects that on
its own.

## Test suites

| unit | what it measures | tests |
|---|---|---|
| `src/attcpu.pas` | integer 16/32-bit, strings, branches, x87, MMX | 33 |
| `src/attmem.pas` | cache curve, access methods, scattered access, latency | 54 |
| `src/attvid.pas` | mode 13h fill, blit, read, read-modify-write, scattered | 21 |
| `src/attvbe.pas` | VESA bank switch cost, two ways | — |
| `src/attdsk.pas` | sequential, block sweep, cache, random I/O | 13 |
| `src/attcmp.pas` | a game frame, drawn in three sizes (see below) | 3 tiers |
| `src/atscore.pas` | turns the above into five indices, integer-only | — |

`src/attime.pas`, `atmemx.pas`, `atharn.pas`, `atcpuid.pas` and `atsys.pas`
are the timing, memory, adaptive-measurement, CPU-detection and system-probe
foundations the suites above are built on. `atui.pas`/`atrep.pas`/`atdb.pas`
are the text UI, the on-screen and `REPORT.TXT` report, and the numbered
`DB\NNNN.ATR` run records.

The harness's own correctness, checked on every QEMU run:

```
repeatability   add8 vs add8 : 1.0032   (want 1.00)
linearity      add8 / add8x2 : 1.9960   (want 2.00)
absolute        1 ms kernel  :    996/s (want ~1000)
```

Linearity has to hold regardless of machine speed — 2.00 on a 286 and a
Pentium alike. Absolute pins the whole thing to real time.

## Why not just one number

Most old-machine benchmarks reduce everything to a single score, which makes
two machines comparable and tells you nothing about *why*. ATBench keeps
CPU, RAM, video and disk apart on purpose: a machine that's fast at RAM and
slow at video has two numbers and an actual answer to "what should I upgrade",
not one number that averages the question away.

Inside each category, a "slot" is a task, not an instruction — "fill the
screen" is one slot with several candidate kernels (`REP STOS` at three
widths, an unrolled loop, x87 `FST`, MMX `MOVQ`), and the machine is scored on
whichever it ran fastest. MMX earns points exactly where it moves more bytes
and nowhere else — there's deliberately no MMX bonus slot, and a category
missing a kernel it has no hardware for (x87 on an FPU-less 286) is marked
partial rather than silently averaged over a shorter list.

Every suite carries a self-check so a kernel that's fast because it computed
the wrong thing fails instead of scoring well: the CPU suite cross-checks a
fixed-point/x87 kernel pair against `sin`/`cos`, the video suite blits a
pattern to VRAM and CRC32s it back, and the composite frame suite's output CRC
must be identical on a 286 and a Pentium MMX, since frame content depends only
on which of eight fixed slots is drawn.

## The composite frame suite

The four suites above each measure one part of the machine — which is exactly
what makes them impossible to add up into "how fast is this machine,
overall". `attcmp` answers that with a workload instead of an instruction: the
frame a game of 1994 drew, in the proportions it drew it — a rotozoomed
texture, masked sprites, a few magnifying lenses, two rows of text, then the
present to the card. Frames per second is the headline, and unlike an average
of four indices it's a measurement, not an opinion about weights.

| tier | viewport | texture | sprites | lenses |
|---|---|---|---|---|
| low | 256x200, mode 13h | 128x128 | 24 of 16x16 | none |
| std | 320x200, mode 13h | 256x256 | 50 of 16x16 | 3 of 40x40 |
| high | 512x480, VBE 101h | 256x256 | 100 of 32x32 | 4 of 48x48 |

The low tier has no lenses on purpose — the gather behind one is four
unpredictable samples per pixel, a good share of the frame time on a machine
that needs the smallest tier, spent on exactly the machine that can least
afford it. The frame is drawn twice on the mode 13h tiers, once through a RAM
back buffer and once straight into video memory, and the machine is credited
with whichever is faster — which turns the report into "how should a game be
written on this machine" instead of an assumption.

The full reasoning — why the lens magnification curve is shaped the way it
is, why the texture never exceeds 64K, why the disk suite doesn't use the
harness, why a video BIOS that leaves interrupts disabled needed its own
recovery path — lives in [DESIGN.md](DESIGN.md) (the author's own working
notes, in Russian).

## Layout

```
src/       units that make up the benchmark
spike/     throwaway programs that validate one thing each
tools/     host-side Python helpers (floppy images, headless runs)
bin/       built .EXE files (not tracked)
work/      compiler scratch, floppy images, extracted results (not tracked)
```

| file | what it does |
|---|---|
| `tools/fat12.py` | read/write FAT12 floppy images: build, inject files, read results back |
| `tools/mkflop.py` | make a plain data floppy for transferring builds to hardware |
| `tools/runqemu.py` | build a bootable FreeDOS floppy, run it headless in QEMU, extract the output |
| `tools/tuisnap.py` | photograph the text UI under QEMU, one keystroke at a time |
| `tools/gfxsnap.py` | photograph the graphics screen, mode 13h or VBE, under QEMU |

## Known issues

- The composite frame suite and the disk suite are validated under QEMU but
  still need a wider spread of real hardware to trust their real-world
  numbers.
- A Pentium-133/MVP3 machine hangs partway through a run; narrowed down to
  the neighbourhood of the RDTSC-based clock-speed probe, not yet root-caused.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
