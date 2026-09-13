unit attvid;
{ ----------------------------------------------------------------------------
  ATBench - the video tests, mode 13h.

  320x200x256 is the one mode of the era that is linear, one byte per pixel and
  free of planar bookkeeping, so a loop over it measures the path to the card
  and nothing else. That is the whole point of this module: the numbers here
  are properties of the *bus*, not of the CPU. An ISA card on a 486 will lose
  to a VLB card on a 386, which no CPU or RAM test in the suite can show.

  Six shapes of traffic, because they diverge wildly on real hardware:

    fill        CPU -> VRAM, no read side. The best case, and on a card with
                write posting the only one that ever looks fast.
    blit        RAM -> VRAM. Adds a read of main memory to every write, so on
                a fast bus it drops towards the RAM copy figure and on ISA it
                barely moves - the bus is still the wall.
    read        VRAM -> CPU. The diagnostic one. Reads cannot be posted or
                combined, so this is where ISA / VLB / PCI separate by an order
                of magnitude, and where a card with no read cache shows it.
    VRAM->VRAM  both ends on the far side of the bus.
    RMW         a read and a write to the same address - the pattern behind
                every transparent sprite of the period.
    scattered   single words at addresses 1026 bytes apart, so no two accesses
                share a burst. Bandwidth says nothing about this; on ISA the
                figure is brutal and it is exactly what a naive putpixel does.

  Widths 8/16/32/MMX are run separately because a 16-bit ISA card splits every
  32-bit access into two bus cycles, so the width sweep measures the bus width
  rather than the CPU's.

  Instruction form is the second axis, run separately from width for the same
  reason: which form is fastest is a property of the machine, not something to
  decide in advance. Each of fill and blit is measured as a REP string move, as
  an unrolled ordinary loop, and through the FPU - an 8-byte FLD/FSTP pair,
  which is what the period's fast blitters used on anything from a 386 up and
  which is still the widest access a machine without MMX has. Reads get a REP
  form too, REP LODSW, which is architecturally legal and on some CPUs of this
  era markedly slower than the loop it would replace. The winner is whichever
  measures fastest; the rest of the table is there to show by how much.

  Addressing. The frame is 64000 bytes and the A000h window is 65536, so every
  offset fits a Word and no kernel needs segment arithmetic. Kernels that read
  main memory load DS themselves; they therefore read every global they need
  *before* touching DS, since the globals live in DGROUP.
  ---------------------------------------------------------------------------- }

interface

uses atharn, atmemx;

{$I at.inc}
{$asmcpu PENTIUM}

type
  TVidReq = (vrAny, vr386, vrFpu, vrMmx);

  TVidTest = record
    Id     : String[8];
    Title  : String[30];
    Metric : String[9];     { 'MB/s' or 'Macc/s' }
    Req    : TVidReq;
    OpsPer : LongWord;      { bytes, or accesses, per unit }
    Kern   : TKernel;
  end;

  TVidTestRes = record
    Ran      : Boolean;
    Skipped  : Boolean;
    Why      : String[28];
    Value    : LongWord;
    SpreadPc : Word;
  end;

const
  MaxVidTests = 24;

var
  VidTests   : array[0..MaxVidTests - 1] of TVidTest;
  VidTestRes : array[0..MaxVidTests - 1] of TVidTestRes;
  VidTestN   : Integer;

  VidReady     : Boolean;
  VidSourceCrc : LongInt;

{ Allocates the two RAM buffers, switches to mode 13h and builds the table.
  False when either step fails; the caller must not run anything then. }
function  VidTestsInit: Boolean;
procedure VidTestsDone;

procedure VidTestRun(I: Integer);

{ Empty when the video path is intact. Verifies the RAM source pattern and
  then does a full round trip - RAM to VRAM and back - comparing CRC32 with
  the source. That second half is what catches a card whose reads return
  garbage, or a kernel that is fast because it addresses the wrong segment. }
function  VidSelfCheck: String;

implementation

uses atcpuid, attime;

const
  FrameBytes  = 64000;      { 320*200 }
  HalfFrame   = 32000;      { VRAM->VRAM needs source and destination to be
                              disjoint inside one 64K window }
  VgaSeg      = $A000;

  Iter16      = FrameBytes div 16;    { loops moving 16 bytes per pass }
  Iter32      = FrameBytes div 32;    { ... and 32 bytes per pass }
  FrameWords  = FrameBytes div 2;
  FrameDwords = FrameBytes div 4;
  HalfWords   = HalfFrame div 2;

  ScatStride  = 1026;       { even, so a word access never straddles the end of
                              the window; not a power of two, so the walk keeps
                              landing in a different burst }
  ScatIter    = 512;
  ScatPerUnit = ScatIter * 8;

  { 1.0 as an IEEE double, low byte first. The FPU fill needs a value in
    st(0), and this one is normal and exactly representable, so FLD and FST
    round-trip it without raising anything even once. Written as bytes rather
    than as a Double so that no floating-point code has to be generated for a
    machine that may not have an FPU to run it on. }
  FpuOne : array[0..7] of Byte = ($00, $00, $00, $00, $00, $00, $F0, $3F);

var
  Source    : TFarBuf;      { pattern; every blit reads it, nothing writes it }
  Dest      : TFarBuf;      { scratch; VRAM->RAM lands here }
  SourceSeg : Word;
  DestSeg   : Word;
  ScatAt    : Word;         { carried between calls so the walk keeps moving }
  OldMode   : Byte;

procedure SetMode(Mode: Byte); assembler;
asm
    mov ah, 00h
    mov al, Mode
    int 10h
end;

function CurrentMode: Byte; assembler;
asm
    mov ah, 0Fh
    int 10h
end;

{ ------------------------------------------------------------------- fills }

{ One unit is one full mode-13h frame for every kernel below except the
  VRAM->VRAM copy (half a frame) and the scattered walk (ScatPerUnit
  accesses). }

procedure KFill8(Units: Word); assembler;
asm
    push di
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov es, ax
    mov al, 5Ah
    cld
  @@frame:
    xor di, di
    mov cx, FrameBytes
    rep stosb
    dec dx
    jnz @@frame
  @@x:
    pop es
    pop di
end;

procedure KFill16(Units: Word); assembler;
asm
    push di
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov es, ax
    mov ax, 5A5Ah
    cld
  @@frame:
    xor di, di
    mov cx, FrameWords
    rep stosw
    dec dx
    jnz @@frame
  @@x:
    pop es
    pop di
end;

procedure KFill32(Units: Word); assembler;
asm
    push di
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov es, ax
    mov eax, 5A5A5A5Ah
    cld
  @@frame:
    xor di, di
    mov cx, FrameDwords
    rep stosd
    dec dx
    jnz @@frame
  @@x:
    pop es
    pop di
end;

procedure KFillQ(Units: Word); assembler;
asm
    push di
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov es, ax
    pxor mm0, mm0
    pxor mm1, mm1
    pxor mm2, mm2
    pxor mm3, mm3
  @@frame:
    xor di, di
    mov cx, Iter32
  @@inner:
    movq es:[di], mm0
    movq es:[di+8], mm1
    movq es:[di+16], mm2
    movq es:[di+24], mm3
    add di, 32
    dec cx
    jnz @@inner
    dec dx
    jnz @@frame
    emms
  @@x:
    pop es
    pop di
end;

{ The same two fills written as ordinary unrolled loops. REP STOS is
  microcoded, and whether the microcode beats a plain loop depends on the CPU
  and on whether the card posts writes - a question this pair answers instead
  of assuming. }

procedure KFillL16(Units: Word); assembler;
asm
    push di
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov es, ax
    mov bx, 5A5Ah
  @@frame:
    xor di, di
    mov cx, Iter16
  @@inner:
    mov es:[di], bx
    mov es:[di+2], bx
    mov es:[di+4], bx
    mov es:[di+6], bx
    mov es:[di+8], bx
    mov es:[di+10], bx
    mov es:[di+12], bx
    mov es:[di+14], bx
    add di, 16
    dec cx
    jnz @@inner
    dec dx
    jnz @@frame
  @@x:
    pop es
    pop di
end;

procedure KFillL32(Units: Word); assembler;
asm
    push di
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov es, ax
    mov ebx, 5A5A5A5Ah
  @@frame:
    xor di, di
    mov cx, Iter32
  @@inner:
    mov es:[di], ebx
    mov es:[di+4], ebx
    mov es:[di+8], ebx
    mov es:[di+12], ebx
    mov es:[di+16], ebx
    mov es:[di+20], ebx
    mov es:[di+24], ebx
    mov es:[di+28], ebx
    add di, 32
    dec cx
    jnz @@inner
    dec dx
    jnz @@frame
  @@x:
    pop es
    pop di
end;

{ Eight bytes per store, which on a machine with no MMX is the widest write
  there is. FNINIT first, so the stack is empty and every exception masked no
  matter what the last x87 test left behind; the constant is loaded while DS
  still points at DGROUP, which here it always does. }
procedure KFillF(Units: Word); assembler;
asm
    push di
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    fninit
    fld qword ptr [FpuOne]
    mov ax, VgaSeg
    mov es, ax
  @@frame:
    xor di, di
    mov cx, Iter32
  @@inner:
    fst qword ptr es:[di]
    fst qword ptr es:[di+8]
    fst qword ptr es:[di+16]
    fst qword ptr es:[di+24]
    add di, 32
    dec cx
    jnz @@inner
    dec dx
    jnz @@frame
    fninit
  @@x:
    pop es
    pop di
end;

{ -------------------------------------------------------------- RAM -> VRAM }

procedure KBlit16(Units: Word); assembler;
asm
    push si
    push di
    push ds
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov es, ax
    mov ax, SourceSeg     { while DS still points at DGROUP }
    mov ds, ax
    cld
  @@frame:
    xor si, si
    xor di, di
    mov cx, FrameWords
    rep movsw
    dec dx
    jnz @@frame
  @@x:
    pop es
    pop ds
    pop di
    pop si
end;

procedure KBlit32(Units: Word); assembler;
asm
    push si
    push di
    push ds
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov es, ax
    mov ax, SourceSeg
    mov ds, ax
    cld
  @@frame:
    xor si, si
    xor di, di
    mov cx, FrameDwords
    rep movsd
    dec dx
    jnz @@frame
  @@x:
    pop es
    pop ds
    pop di
    pop si
end;

procedure KBlitQ(Units: Word); assembler;
asm
    push si
    push di
    push ds
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov es, ax
    mov ax, SourceSeg
    mov ds, ax
  @@frame:
    xor si, si
    xor di, di
    mov cx, Iter32
  @@inner:
    movq mm0, [si]
    movq mm1, [si+8]
    movq mm2, [si+16]
    movq mm3, [si+24]
    movq es:[di], mm0
    movq es:[di+8], mm1
    movq es:[di+16], mm2
    movq es:[di+24], mm3
    add si, 32
    add di, 32
    dec cx
    jnz @@inner
    dec dx
    jnz @@frame
    emms
  @@x:
    pop es
    pop ds
    pop di
    pop si
end;

{ The loop forms of the blit. As with the fills, the constants are all literal
  so nothing in the inner loop needs DGROUP, which has been given away to the
  source segment. }

procedure KBlitL16(Units: Word); assembler;
asm
    push si
    push di
    push ds
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov es, ax
    mov ax, SourceSeg     { while DS still points at DGROUP }
    mov ds, ax
  @@frame:
    xor si, si
    xor di, di
    mov cx, Iter16
  @@inner:
    mov ax, [si]
    mov es:[di], ax
    mov ax, [si+2]
    mov es:[di+2], ax
    mov ax, [si+4]
    mov es:[di+4], ax
    mov ax, [si+6]
    mov es:[di+6], ax
    mov ax, [si+8]
    mov es:[di+8], ax
    mov ax, [si+10]
    mov es:[di+10], ax
    mov ax, [si+12]
    mov es:[di+12], ax
    mov ax, [si+14]
    mov es:[di+14], ax
    add si, 16
    add di, 16
    dec cx
    jnz @@inner
    dec dx
    jnz @@frame
  @@x:
    pop es
    pop ds
    pop di
    pop si
end;

procedure KBlitL32(Units: Word); assembler;
asm
    push si
    push di
    push ds
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov es, ax
    mov ax, SourceSeg
    mov ds, ax
  @@frame:
    xor si, si
    xor di, di
    mov cx, Iter32
  @@inner:
    mov eax, [si]
    mov es:[di], eax
    mov eax, [si+4]
    mov es:[di+4], eax
    mov eax, [si+8]
    mov es:[di+8], eax
    mov eax, [si+12]
    mov es:[di+12], eax
    mov eax, [si+16]
    mov es:[di+16], eax
    mov eax, [si+20]
    mov es:[di+20], eax
    mov eax, [si+24]
    mov es:[di+24], eax
    mov eax, [si+28]
    mov es:[di+28], eax
    add si, 32
    add di, 32
    dec cx
    jnz @@inner
    dec dx
    jnz @@frame
  @@x:
    pop es
    pop ds
    pop di
    pop si
end;

{ The FPU blit, four loads then four stores rather than alternating pairs, so
  the loads have somewhere to go while a store is still in flight. FSTP pops,
  so the stores run backwards through the group.

  FLD/FSTP on doubles, not FILD/FISTP on integers. The integer pair would be
  bit-exact for every possible input where this one alters a signalling NaN
  into a quiet one, but it is also several times slower on a 486, and this
  test exists to find the fastest way to move bytes. Nothing depends on the
  bytes it moves: the round-trip self-check uses the string-move kernel, and
  the source pattern is only ever read. }
procedure KBlitF(Units: Word); assembler;
asm
    push si
    push di
    push ds
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    fninit
    mov ax, VgaSeg
    mov es, ax
    mov ax, SourceSeg
    mov ds, ax
  @@frame:
    xor si, si
    xor di, di
    mov cx, Iter32
  @@inner:
    fld qword ptr [si]
    fld qword ptr [si+8]
    fld qword ptr [si+16]
    fld qword ptr [si+24]
    fstp qword ptr es:[di+24]
    fstp qword ptr es:[di+16]
    fstp qword ptr es:[di+8]
    fstp qword ptr es:[di]
    add si, 32
    add di, 32
    dec cx
    jnz @@inner
    dec dx
    jnz @@frame
    fninit
  @@x:
    pop es
    pop ds
    pop di
    pop si
end;

{ ------------------------------------------------------------- VRAM -> CPU }

{ The value read is thrown away. That is legitimate here: the bus cycle has
  already happened by the time the register is overwritten, and no compiler
  gets a chance to notice, because none of this is compiled. }

procedure KRead16(Units: Word); assembler;
asm
    push si
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov es, ax
  @@frame:
    xor si, si
    mov cx, Iter16
  @@inner:
    mov ax, es:[si]
    mov ax, es:[si+2]
    mov ax, es:[si+4]
    mov ax, es:[si+6]
    mov ax, es:[si+8]
    mov ax, es:[si+10]
    mov ax, es:[si+12]
    mov ax, es:[si+14]
    add si, 16
    dec cx
    jnz @@inner
    dec dx
    jnz @@frame
  @@x:
    pop es
    pop si
end;

procedure KRead32(Units: Word); assembler;
asm
    push si
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov es, ax
  @@frame:
    xor si, si
    mov cx, Iter32
  @@inner:
    mov eax, es:[si]
    mov eax, es:[si+4]
    mov eax, es:[si+8]
    mov eax, es:[si+12]
    mov eax, es:[si+16]
    mov eax, es:[si+20]
    mov eax, es:[si+24]
    mov eax, es:[si+28]
    add si, 32
    dec cx
    jnz @@inner
    dec dx
    jnz @@frame
  @@x:
    pop es
    pop si
end;

procedure KReadQ(Units: Word); assembler;
asm
    push si
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov es, ax
  @@frame:
    xor si, si
    mov cx, Iter32
  @@inner:
    movq mm0, es:[si]
    movq mm1, es:[si+8]
    movq mm2, es:[si+16]
    movq mm3, es:[si+24]
    add si, 32
    dec cx
    jnz @@inner
    dec dx
    jnz @@frame
    emms
  @@x:
    pop es
    pop si
end;

{ REP LODSW: the one string instruction that reads without writing anywhere.
  Intel calls it not useful rather than illegal, and on several CPUs of this
  era it is slower than the plain loop above - which is the sort of thing this
  table exists to show rather than to be told. }
procedure KReadR(Units: Word); assembler;
asm
    push si
    push ds
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov ds, ax
    cld
  @@frame:
    xor si, si
    mov cx, FrameWords
    rep lodsw
    dec dx
    jnz @@frame
  @@x:
    pop ds
    pop si
end;

{ -------------------------------------------------- VRAM -> RAM, VRAM -> VRAM }

procedure KToRam(Units: Word); assembler;
asm
    push si
    push di
    push ds
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, DestSeg       { while DS still points at DGROUP }
    mov es, ax
    mov ax, VgaSeg
    mov ds, ax
    cld
  @@frame:
    xor si, si
    xor di, di
    mov cx, FrameWords
    rep movsw
    dec dx
    jnz @@frame
  @@x:
    pop es
    pop ds
    pop di
    pop si
end;

procedure KVtoV(Units: Word); assembler;
asm
    push si
    push di
    push ds
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov es, ax
    mov ds, ax
    cld
  @@frame:
    xor si, si
    mov di, HalfFrame
    mov cx, HalfWords
    rep movsw
    dec dx
    jnz @@frame
  @@x:
    pop es
    pop ds
    pop di
    pop si
end;

{ --------------------------------------------------------- read-modify-write }

{ Counted as two bytes of bus traffic per byte of frame, because that is what
  crosses the bus. Comparing this against the fill of the same width shows how
  much of the cost is the read half. }
procedure KRmw(Units: Word); assembler;
asm
    push si
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov es, ax
    mov bx, 0101h
  @@frame:
    xor si, si
    mov cx, Iter16
  @@inner:
    mov ax, es:[si]
    add ax, bx
    mov es:[si], ax
    mov ax, es:[si+2]
    add ax, bx
    mov es:[si+2], ax
    mov ax, es:[si+4]
    add ax, bx
    mov es:[si+4], ax
    mov ax, es:[si+6]
    add ax, bx
    mov es:[si+6], ax
    mov ax, es:[si+8]
    add ax, bx
    mov es:[si+8], ax
    mov ax, es:[si+10]
    add ax, bx
    mov es:[si+10], ax
    mov ax, es:[si+12]
    add ax, bx
    mov es:[si+12], ax
    mov ax, es:[si+14]
    add ax, bx
    mov es:[si+14], ax
    add si, 16
    dec cx
    jnz @@inner
    dec dx
    jnz @@frame
  @@x:
    pop es
    pop si
end;

{ ---------------------------------------------------------- scattered writes }

{ SI wraps inside the 64K window on its own, and the stride is even, so no
  access ever straddles the end of it. Where the walk stopped is kept, so
  consecutive calls do not re-tread the same addresses. }
procedure KScatW(Units: Word); assembler;
asm
    push si
    push es
    mov dx, Units
    or  dx, dx
    jz  @@x
    mov ax, VgaSeg
    mov es, ax
    mov si, ScatAt
    mov bx, 5A5Ah
  @@unit:
    mov cx, ScatIter
  @@inner:
    mov es:[si], bx
    add si, ScatStride
    mov es:[si], bx
    add si, ScatStride
    mov es:[si], bx
    add si, ScatStride
    mov es:[si], bx
    add si, ScatStride
    mov es:[si], bx
    add si, ScatStride
    mov es:[si], bx
    add si, ScatStride
    mov es:[si], bx
    add si, ScatStride
    mov es:[si], bx
    add si, ScatStride
    dec cx
    jnz @@inner
    dec dx
    jnz @@unit
    mov ScatAt, si
  @@x:
    pop es
    pop si
end;

{ ---------------------------------------------------------------- the table }

procedure AddTest(const AId, ATitle, AMetric: String; AReq: TVidReq;
                  AOpsPer: LongWord; AKern: TKernel);
begin
  if VidTestN >= MaxVidTests then Exit;
  VidTests[VidTestN].Id     := AId;
  VidTests[VidTestN].Title  := ATitle;
  VidTests[VidTestN].Metric := AMetric;
  VidTests[VidTestN].Req    := AReq;
  VidTests[VidTestN].OpsPer := AOpsPer;
  VidTests[VidTestN].Kern   := AKern;
  Inc(VidTestN);
end;

procedure InitTable;
begin
  VidTestN := 0;
  AddTest('fill8',  'VRAM fill REP 8-bit',   'MB/s',  vrAny, FrameBytes,     @KFill8);
  AddTest('fill16', 'VRAM fill REP 16-bit',  'MB/s',  vrAny, FrameBytes,     @KFill16);
  AddTest('fill32', 'VRAM fill REP 32-bit',  'MB/s',  vr386, FrameBytes,     @KFill32);
  AddTest('fillL16','VRAM fill loop 16-bit', 'MB/s',  vrAny, FrameBytes,     @KFillL16);
  AddTest('fillL32','VRAM fill loop 32-bit', 'MB/s',  vr386, FrameBytes,     @KFillL32);
  AddTest('fillF',  'VRAM fill FPU 64-bit',  'MB/s',  vrFpu, FrameBytes,     @KFillF);
  AddTest('fillq',  'VRAM fill MMX',         'MB/s',  vrMmx, FrameBytes,     @KFillQ);
  AddTest('blit16', 'RAM to VRAM REP 16-bit','MB/s',  vrAny, FrameBytes,     @KBlit16);
  AddTest('blit32', 'RAM to VRAM REP 32-bit','MB/s',  vr386, FrameBytes,     @KBlit32);
  AddTest('blitL16','RAM to VRAM loop 16-bit','MB/s', vrAny, FrameBytes,     @KBlitL16);
  AddTest('blitL32','RAM to VRAM loop 32-bit','MB/s', vr386, FrameBytes,     @KBlitL32);
  AddTest('blitF',  'RAM to VRAM FPU 64-bit','MB/s',  vrFpu, FrameBytes,     @KBlitF);
  AddTest('blitq',  'RAM to VRAM MMX',       'MB/s',  vrMmx, FrameBytes,     @KBlitQ);
  AddTest('read16', 'VRAM read loop 16-bit', 'MB/s',  vrAny, FrameBytes,     @KRead16);
  AddTest('read32', 'VRAM read loop 32-bit', 'MB/s',  vr386, FrameBytes,     @KRead32);
  AddTest('readR',  'VRAM read REP LODSW',   'MB/s',  vrAny, FrameBytes,     @KReadR);
  AddTest('readq',  'VRAM read MMX',         'MB/s',  vrMmx, FrameBytes,     @KReadQ);
  AddTest('toram',  'VRAM to RAM 16-bit',    'MB/s',  vrAny, FrameBytes,     @KToRam);
  AddTest('v2v',    'VRAM to VRAM 16-bit',   'MB/s',  vrAny, HalfFrame,      @KVtoV);
  AddTest('rmw',    'VRAM read-modify-write','MB/s',  vrAny, FrameBytes * 2, @KRmw);
  AddTest('scatw',  'VRAM scattered writes', 'Macc/s',vrAny, ScatPerUnit,    @KScatW);
end;

{ ------------------------------------------------------------------ driving }

function VidTestsInit: Boolean;
var I: Integer;
begin
  VidTestsInit := False;
  VidReady := False;
  VidTestN := 0;
  Source.Base := 0;
  Dest.Base := 0;
  if not FarAlloc(FrameBytes, Source) then Exit;
  if not FarAlloc(FrameBytes, Dest) then
  begin
    FarFree(Source);
    Exit;
  end;
  FarPattern(Source, $1357);
  FarFill(Dest, 0);
  SourceSeg := Source.Base;
  DestSeg   := Dest.Base;
  VidSourceCrc := FarCrc32(Source);
  ScatAt := 0;

  OldMode := CurrentMode;
  SetMode($13);
  { The mode set went through the video BIOS, and the clock may not have
    survived it. }
  TimerReassert;
  InitTable;
  for I := 0 to VidTestN - 1 do
  begin
    VidTestRes[I].Ran := False;
    VidTestRes[I].Skipped := False;
    VidTestRes[I].Why := '';
    VidTestRes[I].Value := 0;
    VidTestRes[I].SpreadPc := 0;
  end;
  VidReady := True;
  VidTestsInit := True;
end;

procedure VidTestsDone;
begin
  if not VidReady then Exit;
  SetMode(OldMode and $7F);
  TimerReassert;
  FarFree(Dest);
  FarFree(Source);
  VidReady := False;
end;

function VidSelfCheck: String;
var Bad: LongInt; S: String;
begin
  VidSelfCheck := '';
  if not VidReady then begin VidSelfCheck := 'video setup failed'; Exit end;

  Bad := FarVerify(Source, $1357);
  if Bad <> -1 then
  begin
    Str(Bad, S);
    VidSelfCheck := 'RAM source changed at byte ' + S;
    Exit;
  end;

  { One frame out, one frame back. }
  KBlit16(1);
  FarFill(Dest, 0);
  KToRam(1);
  if FarCrc32(Dest) <> VidSourceCrc then
    VidSelfCheck := 'VRAM round trip mismatch';
end;

function Supported(const T: TVidTest; var Why: String): Boolean;
begin
  Why := '';
  case T.Req of
    vr386: begin
             Supported := CpuClass >= cc80386;
             if CpuClass < cc80386 then Why := 'needs 386 or up';
           end;
    vrFpu: begin
             Supported := HasFpu;
             if not HasFpu then Why := 'no FPU';
           end;
    vrMmx: begin
             Supported := HasMmx;
             if not HasMmx then Why := 'no MMX';
           end;
  else
    Supported := True;
  end;
end;

procedure VidTestRun(I: Integer);
var
  R   : TBenchResult;
  Why : String;
begin
  if (I < 0) or (I >= VidTestN) or (not VidReady) then Exit;

  VidTestRes[I].Ran := False;
  VidTestRes[I].Skipped := False;
  VidTestRes[I].Value := 0;

  if not Supported(VidTests[I], Why) then
  begin
    VidTestRes[I].Skipped := True;
    VidTestRes[I].Why := Why;
    Exit;
  end;

  R := RunBench(VidTests[I].Kern);
  if not R.Ok then
  begin
    VidTestRes[I].Skipped := True;
    if R.Aborted then VidTestRes[I].Why := 'cancelled'
    else if R.TooFast then VidTestRes[I].Why := 'too fast to time'
    else if R.Overrun then VidTestRes[I].Why := 'took too long'
    else VidTestRes[I].Why := 'no result';
    Exit;
  end;

  VidTestRes[I].Ran := True;
  VidTestRes[I].Value := R.Rate * VidTests[I].OpsPer;
  VidTestRes[I].SpreadPc := R.SpreadPc;
end;

begin
  VidTestN := 0;
  VidReady := False;
  Source.Base := 0;
  Dest.Base := 0;
end.
