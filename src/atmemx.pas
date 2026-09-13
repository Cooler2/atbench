unit atmemx;
{ ----------------------------------------------------------------------------
  ATBench - large buffers outside the 64K data segment.

  Every buffer that matters to a benchmark is larger than a segment (a single
  320x200 texture is already 62.5K), so none of them can be a Pascal variable
  and all of them are addressed by explicit segment arithmetic. Benchmark
  kernels are assembler anyway and load ES/DS themselves, so this costs
  nothing and keeps the addressing honest: a buffer here is a base segment
  plus a size, and FarSegAt turns an offset into the segment to load.

  Where the bytes come from depends on the memory model, and the two families
  are arranged in opposite ways by the FPC startup code (prt0comn.asm).

  In the near-data models it shrinks the program's own DOS block to
  DGROUP + 64K with INT 21h AH=4Ah, keeps a near heap inside DGROUP, and
  leaves the rest of conventional memory to DOS. A program that wants a big
  buffer there has to ask DOS for it with AH=48h, so that is what this unit
  does in those models.

  In the far-data models - large is the one we build, see build.bat for why -
  it does the opposite, and by design: the block is not shrunk, and everything
  above the stack is registered as the RTL heap. The conclusion is simply that
  in this model the heap is where memory lives. GetMem is good for far more
  than a segment here - PtrUInt is 32-bit, and MaxAvail on a 640K machine
  answers in the hundreds of kilobytes - so FarAlloc below is GetMem plus the
  rounding that turns the result into a paragraph address. Asking DOS instead
  would mean first taking the memory away from the heap, which is a fight with
  the RTL and a way to hand out memory the heap is still using.
  ---------------------------------------------------------------------------- }

interface

{$I at.inc}

{$if defined(FPC_MM_COMPACT) or defined(FPC_MM_LARGE) or defined(FPC_MM_HUGE)}
  {$define AT_FAR_DATA}
{$endif}

type
  TFarBuf = record
    Base : Word;      { segment of byte 0; the offset is always 0 }
    Para : Word;      { size in paragraphs }
    Size : LongInt;   { size in bytes }
{$ifdef AT_FAR_DATA}
    { What GetMem returned, which is what FreeMem has to be given back. Base
      is that address rounded up to a paragraph, so the two are not the same
      pointer and the raw one cannot be recovered from it. }
    Raw     : Pointer;
    RawSize : LongInt;
{$endif}
  end;

const
  ChunkBytes = 32768;   { unit of work for the far helpers: fits a Word count
                          with room to spare and never straddles a segment
                          boundary when started from a paragraph address }

{ --- allocation ---------------------------------------------------------- }

function  FarMaxAvail: LongInt;
function  FarAlloc(Bytes: LongInt; var B: TFarBuf): Boolean;
procedure FarFree(var B: TFarBuf);

{ Segment to use when addressing byte Ofs of B with a zero offset.
  Ofs must be a multiple of 16 for the result to be exact. }
function  FarSegAt(const B: TFarBuf; Ofs: LongInt): Word;

{ --- content ------------------------------------------------------------- }

procedure FarFill(const B: TFarBuf; Value: Byte);

{ Writes a position-dependent pseudo-random pattern, then checks it. Verify
  returns the byte offset of the first mismatch, or -1 when the buffer is
  intact. Unlike a constant fill this catches segment-arithmetic mistakes:
  if two chunks alias each other, the pattern will not match. }
procedure FarPattern(const B: TFarBuf; Seed: Word);
function  FarVerify(const B: TFarBuf; Seed: Word): LongInt;

function  FarCrc32(const B: TFarBuf): LongInt;

{ The same CRC32, taken a piece at a time from near memory instead of all at
  once from a far buffer. There is one caller and one reason for it: the
  program checksums the file it was itself loaded from, which arrives a
  block at a time through DOS and never exists anywhere as one object. }
procedure CrcOpen;
procedure CrcFeed(var Buf; N: Word);
function  CrcClose: LongInt;

implementation

{$ifdef AT_FAR_DATA}
type
  { A far pointer taken apart the Turbo Pascal way. Ptr() would do for the
    other direction, but there is no Seg()/Ofs() for an expression. }
  TPtrRec = record
    Ofs, Seg : Word;
  end;

{$endif}

var
  PatState : Word;              { LCG state, shared by the asm chunk helpers }
  CrcAcc   : LongInt;
  CrcTable : array[0..255] of LongInt;
  CrcReady : Boolean;

{ ---------------------------------------------------------------- allocation }

{$ifdef AT_FAR_DATA}
function FarMaxAvail: LongInt;
{ The heap owns conventional memory in this model, so its own answer is the
  right one. Sixteen bytes come off it because that is what FarAlloc spends
  rounding a block up to a paragraph. }
begin
  if MaxAvail > 16 then
    FarMaxAvail := MaxAvail - 16
  else
    FarMaxAvail := 0;
end;
{$else}
function FarMaxAvail: LongInt;
{ AH=48h with BX=FFFFh always fails and reports the largest free block. }
var
  Para: Word;
begin
  asm
    mov  ah, 48h
    mov  bx, 0FFFFh
    int  21h
    mov  Para, bx
  end;
  FarMaxAvail := LongInt(Para) * 16;
end;
{$endif}

{$ifdef AT_FAR_DATA}
function FarAlloc(Bytes: LongInt; var B: TFarBuf): Boolean;
var
  Para : Word;
  Want : LongInt;
  P    : Pointer;
begin
  B.Base := 0;
  B.Para := 0;
  B.Size := 0;
  B.Raw  := nil;
  B.RawSize := 0;
  FarAlloc := False;
  if (Bytes <= 0) or (Bytes > LongInt(65535) * 16) then
    Exit;

  Para := Word((Bytes + 15) shr 4);
  { Fifteen bytes of slack so that whatever the heap returns can be rounded
    up to the next paragraph with the full size still inside the block.
    ReturnNilIfGrowHeapFails - set in the initialisation below - is what
    turns a refusal into a nil instead of runtime error 203. }
  Want := LongInt(Para) * 16 + 15;
  GetMem(P, Want);
  if P = nil then
    Exit;

  B.Raw     := P;
  B.RawSize := Want;
  B.Base    := TPtrRec(P).Seg + ((TPtrRec(P).Ofs + 15) shr 4);
  B.Para    := Para;
  B.Size    := LongInt(Para) * 16;
  FarAlloc  := True;
end;
{$else}
function FarAlloc(Bytes: LongInt; var B: TFarBuf): Boolean;
var
  Para, Sgm, Err: Word;
begin
  B.Base := 0;
  B.Para := 0;
  B.Size := 0;
  FarAlloc := False;
  if (Bytes <= 0) or (Bytes > LongInt(65535) * 16) then
    Exit;

  Para := Word((Bytes + 15) shr 4);
  Sgm  := 0;
  Err  := 1;
  asm
    mov  ah, 48h
    mov  bx, Para
    int  21h
    jc   @@failed
    mov  Sgm, ax
    mov  Err, 0
  @@failed:
  end;
  if Err <> 0 then
    Exit;

  B.Base := Sgm;
  B.Para := Para;
  B.Size := LongInt(Para) * 16;
  FarAlloc := True;
end;
{$endif}

{$ifdef AT_FAR_DATA}
procedure FarFree(var B: TFarBuf);
begin
  if B.Raw <> nil then
    FreeMem(B.Raw, B.RawSize);
  B.Raw     := nil;
  B.RawSize := 0;
  B.Base := 0;
  B.Para := 0;
  B.Size := 0;
end;
{$else}
procedure FarFree(var B: TFarBuf);
var
  Sgm: Word;
begin
  if B.Base = 0 then
    Exit;
  Sgm := B.Base;
  asm
    mov  ax, Sgm
    mov  es, ax
    mov  ah, 49h
    int  21h
  end;
  B.Base := 0;
  B.Para := 0;
  B.Size := 0;
end;
{$endif}

function FarSegAt(const B: TFarBuf; Ofs: LongInt): Word;
begin
  FarSegAt := B.Base + Word(Ofs shr 4);
end;

{ ------------------------------------------------------------ chunk kernels }

procedure FillChunk(SegBase, Count: Word; Value: Byte); assembler;
asm
    push di
    mov  es, SegBase
    xor  di, di
    mov  cx, Count
    mov  al, Value
    cld
    rep  stosb
    pop  di
end;

{ Writes Count pseudo-random bytes at SegBase:0000, advancing PatState.
  The generator is the classic 16-bit LCG; we store the high byte because the
  low bits of such an LCG are notoriously non-random. }
procedure PatChunk(SegBase, Count: Word); assembler;
asm
    push di
    mov  es, SegBase
    xor  di, di
    mov  cx, Count
    mov  ax, PatState
    mov  bx, 25173
    cld
@@1:
    mul  bx
    add  ax, 13849
    mov  es:[di], ah
    inc  di
    dec  cx
    jnz  @@1
    mov  PatState, ax
    pop  di
end;

{ Same sequence, compared instead of written. Returns the offset of the first
  mismatch, or FFFFh when the chunk is intact. }
function VerChunk(SegBase, Count: Word): Word; assembler;
asm
    push di
    push si
    mov  es, SegBase
    xor  di, di
    mov  cx, Count
    mov  ax, PatState
    mov  bx, 25173
    cld
@@1:
    mul  bx
    add  ax, 13849
    cmp  es:[di], ah
    jne  @@bad
    inc  di
    dec  cx
    jnz  @@1
    mov  PatState, ax
    mov  ax, 0FFFFh
    jmp  @@done
@@bad:
    mov  PatState, ax
    mov  ax, di
@@done:
    pop  si
    pop  di
end;

{ CRC32 of one chunk, folded into CrcAcc. Table-driven, reflected, the usual
  0xEDB88320 polynomial - so the value can be checked against any other tool. }
procedure CrcChunk(SegBase, Count: Word); assembler;
asm
    push di
    push si
    push ds

    mov  es, SegBase
    xor  di, di
    mov  cx, Count

    { dx:ax = running CRC }
    mov  ax, word ptr CrcAcc
    mov  dx, word ptr CrcAcc+2

@@1:
    { index = (crc_low_byte xor next_byte) * 4 }
    mov  bl, al
    xor  bl, es:[di]
    xor  bh, bh
    shl  bx, 1
    shl  bx, 1

    { crc = (crc shr 8) xor table[index] }
    mov  al, ah
    mov  ah, dl
    mov  dl, dh
    xor  dh, dh

    xor  ax, word ptr CrcTable[bx]
    xor  dx, word ptr CrcTable[bx+2]

    inc  di
    dec  cx
    jnz  @@1

    mov  word ptr CrcAcc, ax
    mov  word ptr CrcAcc+2, dx

    pop  ds
    pop  si
    pop  di
end;

{ ------------------------------------------------------ chunked far walkers }

{ Every walker below steps through the buffer in ChunkBytes pieces, moving the
  segment by ChunkBytes shr 4 paragraphs each time. Offsets therefore stay in
  0..ChunkBytes-1 and no 16-bit counter can overflow. }

procedure FarFill(const B: TFarBuf; Value: Byte);
var
  Left: LongInt;
  Sgm, N: Word;
begin
  if B.Base = 0 then Exit;
  Left := B.Size;
  Sgm  := B.Base;
  while Left > 0 do
  begin
    if Left > ChunkBytes then N := ChunkBytes else N := Word(Left);
    FillChunk(Sgm, N, Value);
    Inc(Sgm, N shr 4);
    Dec(Left, N);
  end;
end;

procedure FarPattern(const B: TFarBuf; Seed: Word);
var
  Left: LongInt;
  Sgm, N: Word;
begin
  if B.Base = 0 then Exit;
  PatState := Seed;
  Left := B.Size;
  Sgm  := B.Base;
  while Left > 0 do
  begin
    if Left > ChunkBytes then N := ChunkBytes else N := Word(Left);
    PatChunk(Sgm, N);
    Inc(Sgm, N shr 4);
    Dec(Left, N);
  end;
end;

function FarVerify(const B: TFarBuf; Seed: Word): LongInt;
var
  Left, Done: LongInt;
  Sgm, N, R: Word;
begin
  FarVerify := -1;
  if B.Base = 0 then Exit;
  PatState := Seed;
  Left := B.Size;
  Done := 0;
  Sgm  := B.Base;
  while Left > 0 do
  begin
    if Left > ChunkBytes then N := ChunkBytes else N := Word(Left);
    R := VerChunk(Sgm, N);
    if R <> $FFFF then
    begin
      FarVerify := Done + R;
      Exit;
    end;
    Inc(Sgm, N shr 4);
    Inc(Done, N);
    Dec(Left, N);
  end;
end;

procedure BuildCrcTable;
var
  I, J: Integer;
  C: LongInt;
begin
  for I := 0 to 255 do
  begin
    C := I;
    for J := 1 to 8 do
      if (C and 1) <> 0 then
        C := LongInt($EDB88320) xor ((C shr 1) and $7FFFFFFF)
      else
        C := (C shr 1) and $7FFFFFFF;
    CrcTable[I] := C;
  end;
  CrcReady := True;
end;

type
  TCrcBytes = array[0..65534] of Byte;
  PCrcBytes = ^TCrcBytes;

procedure CrcOpen;
begin
  if not CrcReady then BuildCrcTable;
  CrcAcc := LongInt(-1);
end;

{ Pascal and not the assembler chunk helper: this runs over a hundred and
  fifty kilobytes once, at the end of a run that took minutes, and the
  helper wants a paragraph-aligned segment which a local buffer is not. }
procedure CrcFeed(var Buf; N: Word);
var
  P: PCrcBytes;
  I: Word;
  A: LongInt;
begin
  if N = 0 then Exit;
  P := PCrcBytes(@Buf);
  A := CrcAcc;
  for I := 0 to N - 1 do
    A := CrcTable[(A xor LongInt(P^[I])) and $FF] xor
         ((A shr 8) and $00FFFFFF);
  CrcAcc := A;
end;

function CrcClose: LongInt;
begin
  CrcClose := CrcAcc xor LongInt(-1);
end;

function FarCrc32(const B: TFarBuf): LongInt;
var
  Left: LongInt;
  Sgm, N: Word;
begin
  if not CrcReady then BuildCrcTable;
  CrcAcc := LongInt(-1);
  if B.Base <> 0 then
  begin
    Left := B.Size;
    Sgm  := B.Base;
    while Left > 0 do
    begin
      if Left > ChunkBytes then N := ChunkBytes else N := Word(Left);
      CrcChunk(Sgm, N);
      Inc(Sgm, N shr 4);
      Dec(Left, N);
    end;
  end;
  FarCrc32 := CrcAcc xor LongInt(-1);
end;

begin
  CrcReady := False;
  PatState := 0;
{$ifdef AT_FAR_DATA}
  { A buffer this program cannot get is a test it skips and says so; it is
    never a reason to stop. Without this the first oversized GetMem would end
    the run with runtime error 203. }
  ReturnNilIfGrowHeapFails := True;
{$endif}
end.
