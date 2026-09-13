unit attmem;
{ ----------------------------------------------------------------------------
  ATBench - the memory tests.

  The point of this module is not a number in megabytes per second. It is the
  *curve*: the same read loop run over working sets from 1 KB to half a
  megabyte, so that the steps in the graph draw the cache hierarchy without
  anyone having to know in advance what the machine has. A 486DX2 shows a
  cliff at 8 KB and another at 256 KB; a 386 with no cache at all shows a
  straight line, which is just as informative.

  Addressing. Buffers come from DOS through ATMEMX and live outside DGROUP,
  so the kernels have to reach them by segment. Two rules keep that honest:

    * loops that step through memory by hand use ES with an explicit
      override, so DS keeps pointing at DGROUP and the loop counters stay
      readable throughout;
    * REP-based kernels need DS:SI, so they change DS around the REP itself
      and nothing else. All control flow runs with DS intact.

  The working set is traversed in chunks of at most 8 KB, all sizes being
  powers of two, so a chunk never straddles a segment boundary and the
  offset arithmetic stays inside a Word.
  ---------------------------------------------------------------------------- }

interface

uses attime, atharn, atcpuid, atmemx;

{$I at.inc}
{$asmcpu PENTIUM}

type
  TMemReq = (mrAny, mr386, mrFpu, mrMmx);

  TMemTest = record
    Id     : String[10];
    Title  : String[30];
    Metric : String[8];     { 'MB/s' or 'Macc/s' }
    Req    : TMemReq;
    Bytes  : LongWord;      { working set }
    OpsPer : LongWord;      { bytes, or accesses, per unit }
    Kern   : TKernel;
  end;

  TMemTestRes = record
    Ran      : Boolean;
    Skipped  : Boolean;
    Why      : String[28];
    Value    : LongWord;
    SpreadPc : Word;
  end;

const
  MaxMemTests = 80;
  SmallWs     = 8192;       { inside L1 on anything from a 486 up }
  MaxCurve    = 12;         { as many points as there are sweep sizes }
  MaxMethods  = 20;         { as many as one AddMethodSet adds }

type
  { The sweep read at one working set, and the pointer chase at the same one
    where there is a chase for it. Kept as a table rather than recovered from
    the identifiers: 'rd64K' and 'rdwS' both start with 'rd', and a report
    that tells them apart by spelling breaks the day a test is renamed. }
  TMemCurve = record
    Kb   : Word;
    Read : Integer;         { index into MemTests, -1 if there is none }
    Lat  : Integer;
  end;

  { One access method at both working sets. The method set exists to answer
    "which way of moving memory is fastest on this machine, and does the
    answer change once the data stops fitting the cache" - and that answer is
    invisible while the two halves of it sit thirty rows apart in a list
    sorted by nothing in particular. Paired here so the report can put them
    side by side. }
  TMemMethod = record
    Name  : String[18];
    Small : Integer;        { index into MemTests, -1 if there is none }
    Big   : Integer;
  end;

var
  MemTests   : array[0..MaxMemTests - 1] of TMemTest;
  MemTestRes : array[0..MaxMemTests - 1] of TMemTestRes;
  MemTestN   : Integer;

  MemCurve   : array[0..MaxCurve - 1] of TMemCurve;
  MemCurveN  : Integer;

  MemMethod  : array[0..MaxMethods - 1] of TMemMethod;
  MemMethodN : Integer;
  MemSmallKb : Word;        { the working set the S column was measured at }
  MemBigKb   : Word;        { and the B one; 0 when there was no room for it }

  MemReady   : Boolean;
  MemBufBytes: LongInt;     { what we actually got from DOS }
  MemBigWs   : LongWord;    { working set used for the out-of-cache tests }
  MemMaxSweep: LongWord;    { largest size in the sweep }

{ Allocates the buffer and builds the table. False when there is not enough
  conventional memory to say anything useful. }
function  MemTestsInit: Boolean;
procedure MemTestsDone;

procedure MemTestRun(I: Integer);
procedure MemTestRunAll;

implementation

const
  MaxChunk  = 8192;
  ChasePad  = 4096;         { slack so the misaligned loop cannot run off the
                              end of the buffer }

  { 1.0 as an IEEE double, low byte first - the value the FPU fill stores.
    Normal and exactly representable, so FLD and FST round-trip it without
    ever raising anything; written as bytes so that no floating-point code has
    to be generated for a machine that may not have an FPU. }
  FpuOne : array[0..7] of Byte = ($00, $00, $00, $00, $00, $00, $F0, $3F);

var
  Buf : TFarBuf;

  { --- what the kernels read; all set by SetWorkingSet ------------------- }
  WsSeg    : Word;          { segment of byte 0 of the working set }
  WsChunks : Word;          { how many chunks make up one pass }
  WsParaPC : Word;          { paragraphs to advance between chunks }
  WsIter16 : Word;          { iterations of a 16-byte-per-pass loop }
  WsIter32 : Word;          { iterations of a 32-byte-per-pass loop }
  WsWords  : Word;          { words in a chunk }
  WsDwords : Word;
  WsMask   : Word;          { chunk size minus one, for the scattered walk }
  WsDstPara: Word;          { paragraphs from a source chunk to its copy }
  ChaseAt  : Word;          { where the pointer walk starts }
  ChaseEnd : Word;          { where it finished - keeps the result live }

{ --------------------------------------------------------- sequential read }

procedure KRdW(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  dx, Units
    or   dx, dx
    jz   @@x
  @@pass:
    mov  bx, WsSeg
    mov  di, WsChunks
  @@chunk:
    mov  es, bx
    xor  si, si
    mov  cx, WsIter16
  @@inner:
    mov  ax, es:[si]
    mov  ax, es:[si+2]
    mov  ax, es:[si+4]
    mov  ax, es:[si+6]
    mov  ax, es:[si+8]
    mov  ax, es:[si+10]
    mov  ax, es:[si+12]
    mov  ax, es:[si+14]
    add  si, 16
    dec  cx
    jnz  @@inner
    add  bx, WsParaPC
    dec  di
    jnz  @@chunk
    dec  dx
    jnz  @@pass
  @@x:
    pop  es
    pop  di
    pop  si
end;

procedure KRdD(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  dx, Units
    or   dx, dx
    jz   @@x
  @@pass:
    mov  bx, WsSeg
    mov  di, WsChunks
  @@chunk:
    mov  es, bx
    xor  si, si
    mov  cx, WsIter32
  @@inner:
    mov  eax, es:[si]
    mov  eax, es:[si+4]
    mov  eax, es:[si+8]
    mov  eax, es:[si+12]
    mov  eax, es:[si+16]
    mov  eax, es:[si+20]
    mov  eax, es:[si+24]
    mov  eax, es:[si+28]
    add  si, 32
    dec  cx
    jnz  @@inner
    add  bx, WsParaPC
    dec  di
    jnz  @@chunk
    dec  dx
    jnz  @@pass
  @@x:
    pop  es
    pop  di
    pop  si
end;

{ One byte off, so every access straddles a word - and on a 16-bit bus, two
  bus cycles instead of one. The buffer carries slack past the working set so
  the final read of a pass stays inside it. }
procedure KRdWu(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  dx, Units
    or   dx, dx
    jz   @@x
  @@pass:
    mov  bx, WsSeg
    mov  di, WsChunks
  @@chunk:
    mov  es, bx
    mov  si, 1
    mov  cx, WsIter16
  @@inner:
    mov  ax, es:[si]
    mov  ax, es:[si+2]
    mov  ax, es:[si+4]
    mov  ax, es:[si+6]
    mov  ax, es:[si+8]
    mov  ax, es:[si+10]
    mov  ax, es:[si+12]
    mov  ax, es:[si+14]
    add  si, 16
    dec  cx
    jnz  @@inner
    add  bx, WsParaPC
    dec  di
    jnz  @@chunk
    dec  dx
    jnz  @@pass
  @@x:
    pop  es
    pop  di
    pop  si
end;

{ -------------------------------------------------------- sequential write }

procedure KWrW(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  dx, Units
    or   dx, dx
    jz   @@x
    mov  ax, 5A5Ah
  @@pass:
    mov  bx, WsSeg
    mov  di, WsChunks
  @@chunk:
    mov  es, bx
    xor  si, si
    mov  cx, WsIter16
  @@inner:
    mov  es:[si], ax
    mov  es:[si+2], ax
    mov  es:[si+4], ax
    mov  es:[si+6], ax
    mov  es:[si+8], ax
    mov  es:[si+10], ax
    mov  es:[si+12], ax
    mov  es:[si+14], ax
    add  si, 16
    dec  cx
    jnz  @@inner
    add  bx, WsParaPC
    dec  di
    jnz  @@chunk
    dec  dx
    jnz  @@pass
  @@x:
    pop  es
    pop  di
    pop  si
end;

procedure KWrD(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  dx, Units
    or   dx, dx
    jz   @@x
    mov  eax, 5A5A5A5Ah
  @@pass:
    mov  bx, WsSeg
    mov  di, WsChunks
  @@chunk:
    mov  es, bx
    xor  si, si
    mov  cx, WsIter32
  @@inner:
    mov  es:[si], eax
    mov  es:[si+4], eax
    mov  es:[si+8], eax
    mov  es:[si+12], eax
    mov  es:[si+16], eax
    mov  es:[si+20], eax
    mov  es:[si+24], eax
    mov  es:[si+28], eax
    add  si, 32
    dec  cx
    jnz  @@inner
    add  bx, WsParaPC
    dec  di
    jnz  @@chunk
    dec  dx
    jnz  @@pass
  @@x:
    pop  es
    pop  di
    pop  si
end;

{ ----------------------------------------------------------- REP variants }

procedure KStosw(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  dx, Units
    or   dx, dx
    jz   @@x
  @@pass:
    mov  bx, WsSeg
    mov  si, WsChunks
  @@chunk:
    mov  cx, WsWords
    mov  es, bx
    xor  di, di
    mov  ax, 5A5Ah
    cld
    rep  stosw
    add  bx, WsParaPC
    dec  si
    jnz  @@chunk
    dec  dx
    jnz  @@pass
  @@x:
    pop  es
    pop  di
    pop  si
end;

procedure KStosd(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  dx, Units
    or   dx, dx
    jz   @@x
  @@pass:
    mov  bx, WsSeg
    mov  si, WsChunks
  @@chunk:
    mov  cx, WsDwords
    mov  es, bx
    xor  di, di
    mov  eax, 5A5A5A5Ah
    cld
    rep  stosd
    add  bx, WsParaPC
    dec  si
    jnz  @@chunk
    dec  dx
    jnz  @@pass
  @@x:
    pop  es
    pop  di
    pop  si
end;

{ LODSW reads through DS:SI, so DS is swapped for the duration of the REP
  and put straight back. }
procedure KLodsw(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  dx, Units
    or   dx, dx
    jz   @@x
  @@pass:
    mov  bx, WsSeg
    mov  di, WsChunks
  @@chunk:
    mov  cx, WsWords
    push ds
    mov  ds, bx
    xor  si, si
    cld
    rep  lodsw
    pop  ds
    add  bx, WsParaPC
    dec  di
    jnz  @@chunk
    dec  dx
    jnz  @@pass
  @@x:
    pop  es
    pop  di
    pop  si
end;

procedure KMovsw(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  dx, Units
    or   dx, dx
    jz   @@x
  @@pass:
    mov  bx, WsSeg
    push bp
    mov  bp, WsChunks
  @@chunk:
    mov  cx, WsWords
    mov  ax, bx
    add  ax, WsDstPara
    mov  es, ax
    push ds
    mov  ds, bx
    xor  si, si
    xor  di, di
    cld
    rep  movsw
    pop  ds
    add  bx, WsParaPC
    dec  bp
    jnz  @@chunk
    pop  bp
    dec  dx
    jnz  @@pass
  @@x:
    pop  es
    pop  di
    pop  si
end;

procedure KMovsd(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  dx, Units
    or   dx, dx
    jz   @@x
  @@pass:
    mov  bx, WsSeg
    push bp
    mov  bp, WsChunks
  @@chunk:
    mov  cx, WsDwords
    mov  ax, bx
    add  ax, WsDstPara
    mov  es, ax
    push ds
    mov  ds, bx
    xor  si, si
    xor  di, di
    cld
    rep  movsd
    pop  ds
    add  bx, WsParaPC
    dec  bp
    jnz  @@chunk
    pop  bp
    dec  dx
    jnz  @@pass
  @@x:
    pop  es
    pop  di
    pop  si
end;

{ ------------------------------------------------- copies without REP MOVS }

{ The same copy as an unrolled loop. REP MOVS is microcoded and its advantage
  over a plain loop varies by more than a factor of two across this era's
  processors, so which one is the machine's real copy speed has to be measured
  rather than assumed.

  CX is loaded before DS is handed to the source segment, as everywhere else
  in this unit: the loop counters live in DGROUP and the inner loop must not
  need it. }

procedure KCopyW(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  dx, Units
    or   dx, dx
    jz   @@x
  @@pass:
    mov  bx, WsSeg
    push bp
    mov  bp, WsChunks
  @@chunk:
    mov  ax, bx
    add  ax, WsDstPara
    mov  es, ax
    mov  cx, WsIter16
    push ds
    mov  ds, bx
    xor  si, si
    xor  di, di
  @@inner:
    mov  ax, [si]
    mov  es:[di], ax
    mov  ax, [si+2]
    mov  es:[di+2], ax
    mov  ax, [si+4]
    mov  es:[di+4], ax
    mov  ax, [si+6]
    mov  es:[di+6], ax
    mov  ax, [si+8]
    mov  es:[di+8], ax
    mov  ax, [si+10]
    mov  es:[di+10], ax
    mov  ax, [si+12]
    mov  es:[di+12], ax
    mov  ax, [si+14]
    mov  es:[di+14], ax
    add  si, 16
    add  di, 16
    dec  cx
    jnz  @@inner
    pop  ds
    add  bx, WsParaPC
    dec  bp
    jnz  @@chunk
    pop  bp
    dec  dx
    jnz  @@pass
  @@x:
    pop  es
    pop  di
    pop  si
end;

procedure KCopyD(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  dx, Units
    or   dx, dx
    jz   @@x
  @@pass:
    mov  bx, WsSeg
    push bp
    mov  bp, WsChunks
  @@chunk:
    mov  ax, bx
    add  ax, WsDstPara
    mov  es, ax
    mov  cx, WsIter32
    push ds
    mov  ds, bx
    xor  si, si
    xor  di, di
  @@inner:
    mov  eax, [si]
    mov  es:[di], eax
    mov  eax, [si+4]
    mov  es:[di+4], eax
    mov  eax, [si+8]
    mov  es:[di+8], eax
    mov  eax, [si+12]
    mov  es:[di+12], eax
    mov  eax, [si+16]
    mov  es:[di+16], eax
    mov  eax, [si+20]
    mov  es:[di+20], eax
    mov  eax, [si+24]
    mov  es:[di+24], eax
    mov  eax, [si+28]
    mov  es:[di+28], eax
    add  si, 32
    add  di, 32
    dec  cx
    jnz  @@inner
    pop  ds
    add  bx, WsParaPC
    dec  bp
    jnz  @@chunk
    pop  bp
    dec  dx
    jnz  @@pass
  @@x:
    pop  es
    pop  di
    pop  si
end;

{ ------------------------------------------------------------------- x87 }

{ Eight bytes an access, which on a machine without MMX is the widest there
  is. Four loads then four stores, so a load has somewhere to go while a store
  is still in flight; FSTP pops, so the stores run backwards through the group.

  FLD/FSTP on doubles rather than FILD/FISTP on integers. The integer pair is
  bit-exact for every input where this one would quieten a signalling NaN, but
  it is several times slower on a 486 and this test exists to find the fastest
  way to move bytes. Nothing here depends on the bytes: the buffer is scratch
  and no other test reads what a copy left behind. }
procedure KCopyF(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  dx, Units
    or   dx, dx
    jz   @@x
    fninit
  @@pass:
    mov  bx, WsSeg
    push bp
    mov  bp, WsChunks
  @@chunk:
    mov  ax, bx
    add  ax, WsDstPara
    mov  es, ax
    mov  cx, WsIter32
    push ds
    mov  ds, bx
    xor  si, si
    xor  di, di
  @@inner:
    fld  qword ptr [si]
    fld  qword ptr [si+8]
    fld  qword ptr [si+16]
    fld  qword ptr [si+24]
    fstp qword ptr es:[di+24]
    fstp qword ptr es:[di+16]
    fstp qword ptr es:[di+8]
    fstp qword ptr es:[di]
    add  si, 32
    add  di, 32
    dec  cx
    jnz  @@inner
    pop  ds
    add  bx, WsParaPC
    dec  bp
    jnz  @@chunk
    pop  bp
    dec  dx
    jnz  @@pass
    fninit
  @@x:
    pop  es
    pop  di
    pop  si
end;

{ The FPU fill. DS is never given away here, so the constant can be loaded
  straight out of DGROUP. }
procedure KWrF(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  dx, Units
    or   dx, dx
    jz   @@x
    fninit
    fld  qword ptr [FpuOne]
  @@pass:
    mov  bx, WsSeg
    mov  di, WsChunks
  @@chunk:
    mov  es, bx
    xor  si, si
    mov  cx, WsIter32
  @@inner:
    fst  qword ptr es:[si]
    fst  qword ptr es:[si+8]
    fst  qword ptr es:[si+16]
    fst  qword ptr es:[si+24]
    add  si, 32
    dec  cx
    jnz  @@inner
    add  bx, WsParaPC
    dec  di
    jnz  @@chunk
    dec  dx
    jnz  @@pass
    fninit
  @@x:
    pop  es
    pop  di
    pop  si
end;

{ ------------------------------------------------------------------- MMX }

procedure KRdQ(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  dx, Units
    or   dx, dx
    jz   @@x
  @@pass:
    mov  bx, WsSeg
    mov  di, WsChunks
  @@chunk:
    mov  es, bx
    xor  si, si
    mov  cx, WsIter32
  @@inner:
    movq mm0, es:[si]
    movq mm1, es:[si+8]
    movq mm2, es:[si+16]
    movq mm3, es:[si+24]
    add  si, 32
    dec  cx
    jnz  @@inner
    add  bx, WsParaPC
    dec  di
    jnz  @@chunk
    dec  dx
    jnz  @@pass
    emms
  @@x:
    pop  es
    pop  di
    pop  si
end;

procedure KWrQ(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  dx, Units
    or   dx, dx
    jz   @@x
    pxor mm0, mm0
    pxor mm1, mm1
    pxor mm2, mm2
    pxor mm3, mm3
  @@pass:
    mov  bx, WsSeg
    mov  di, WsChunks
  @@chunk:
    mov  es, bx
    xor  si, si
    mov  cx, WsIter32
  @@inner:
    movq es:[si], mm0
    movq es:[si+8], mm1
    movq es:[si+16], mm2
    movq es:[si+24], mm3
    add  si, 32
    dec  cx
    jnz  @@inner
    add  bx, WsParaPC
    dec  di
    jnz  @@chunk
    dec  dx
    jnz  @@pass
    emms
  @@x:
    pop  es
    pop  di
    pop  si
end;

{ ------------------------------------------------------- scattered access }

{ A stride of 1027 - odd, prime, and far larger than any cache line of the
  era - so consecutive accesses never share a line and the sequential case
  has nothing to prefetch. The mask keeps the walk inside the chunk; every
  chunk size is a power of two, which is why a mask is enough. }
procedure KRand(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  dx, Units
    or   dx, dx
    jz   @@x
  @@pass:
    mov  bx, WsSeg
    mov  di, WsChunks
  @@chunk:
    mov  es, bx
    xor  si, si
    mov  cx, WsIter16
  @@inner:
    mov  ax, es:[si]
    add  si, 1027
    and  si, WsMask
    mov  ax, es:[si]
    add  si, 1027
    and  si, WsMask
    mov  ax, es:[si]
    add  si, 1027
    and  si, WsMask
    mov  ax, es:[si]
    add  si, 1027
    and  si, WsMask
    mov  ax, es:[si]
    add  si, 1027
    and  si, WsMask
    mov  ax, es:[si]
    add  si, 1027
    and  si, WsMask
    mov  ax, es:[si]
    add  si, 1027
    and  si, WsMask
    mov  ax, es:[si]
    add  si, 1027
    and  si, WsMask
    dec  cx
    jnz  @@inner
    add  bx, WsParaPC
    dec  di
    jnz  @@chunk
    dec  dx
    jnz  @@pass
  @@x:
    pop  es
    pop  di
    pop  si
end;

{ Dependent loads round a random cycle: the address of the next access is
  the value just read, so nothing can overlap and the rate is the raw
  load-to-use latency. This is the one memory figure that bandwidth cannot
  express, and the one that plots most clearly. }
procedure KChase(Units: Word); assembler;
asm
    push si
    push es
    mov  cx, Units
    jcxz @@x
    mov  ax, WsSeg
    mov  es, ax
    mov  si, ChaseAt
  @@l:
    mov  si, es:[si]
    mov  si, es:[si]
    mov  si, es:[si]
    mov  si, es:[si]
    mov  si, es:[si]
    mov  si, es:[si]
    mov  si, es:[si]
    mov  si, es:[si]
    dec  cx
    jnz  @@l
    mov  ChaseEnd, si
  @@x:
    pop  es
    pop  si
end;

{ ------------------------------------------------------- working-set setup }

function SetWorkingSet(Bytes: LongWord): Boolean;
var
  Chunk: LongWord;
begin
  SetWorkingSet := False;
  if (Bytes = 0) or (Bytes > LongWord(MemBufBytes)) then Exit;

  if Bytes < MaxChunk then Chunk := Bytes else Chunk := MaxChunk;

  WsSeg     := Buf.Base;
  WsChunks  := Word(Bytes div Chunk);
  WsParaPC  := Word(Chunk div 16);
  WsIter16  := Word(Chunk div 16);
  WsIter32  := Word(Chunk div 32);
  WsWords   := Word(Chunk div 2);
  WsDwords  := Word(Chunk div 4);
  WsMask    := Word(Chunk - 1);
  WsDstPara := Word(Bytes div 16);
  SetWorkingSet := True;
end;

{ Sattolo's algorithm applied to an identity permutation produces a single
  cycle covering every element - exactly what the chase needs, and it does it
  in place, so the permutation is built inside the far buffer and costs no
  DGROUP at all. }
procedure BuildChase(Bytes: LongWord);
const
  Cell = 16;
var
  N, I, J : Word;
  S       : Word;
  T       : Word;
begin
  N := Word(Bytes div Cell);
  if N < 2 then N := 2;

  for I := 0 to N - 1 do
    MemW[Buf.Base : I * Cell] := I * Cell;

  S := 22695;
  I := N - 1;
  while I >= 1 do
  begin
    S := Word(S * 25173 + 13849);
    J := S mod I;                     { strictly below I - this is Sattolo }
    T := MemW[Buf.Base : I * Cell];
    MemW[Buf.Base : I * Cell] := MemW[Buf.Base : J * Cell];
    MemW[Buf.Base : J * Cell] := T;
    Dec(I);
  end;

  ChaseAt := 0;
end;

{ --------------------------------------------------------------- the table }

procedure AddTest(const AId, ATitle, AMetric: String; AReq: TMemReq;
                  ABytes, AOpsPer: LongWord; AKern: TKernel);
begin
  if MemTestN >= MaxMemTests then Exit;
  MemTests[MemTestN].Id     := AId;
  MemTests[MemTestN].Title  := ATitle;
  MemTests[MemTestN].Metric := AMetric;
  MemTests[MemTestN].Req    := AReq;
  MemTests[MemTestN].Bytes  := ABytes;
  MemTests[MemTestN].OpsPer := AOpsPer;
  MemTests[MemTestN].Kern   := AKern;
  Inc(MemTestN);
end;

function KbStr(Bytes: LongWord): String;
var
  S: String;
begin
  Str(Bytes div 1024, S);
  KbStr := S + 'K';
end;

const
  { Doublings, and nothing between them. There were fifteen sizes with 1.5x
    steps in the gaps, which bought resolution nobody was reading: a cache
    boundary shows up as a step between two neighbouring doublings, and
    naming it to within 50% is all this curve can honestly do anyway. Ten
    points cost half the RAM suite's running time and read better. }
  SweepSizes : array[0..9] of LongWord =
    (1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288);

  { The chase permutation is built from 16-bit offsets, so it cannot reach
    past one segment. Beyond 64 KB the walk would need 32-bit addressing,
    which is scheduled with the XMS work - so latency is measured up to 64 KB
    and the bandwidth curve carries the story from there. }
  ChaseSizes : array[0..3] of LongWord =
    (1024, 8192, 32768, 65536);

var
  { AddMeth's share of AddMethodSet's arguments, and where it is up to. The
    first set defines the method list and the second fills in its other
    column, so the two must add the same methods in the same order - which
    they do by construction, being the same procedure called twice. }
  MethWhere : String[8];
  MethIdx   : Integer;
  MethNew   : Boolean;

procedure AddMeth(const AId, AName, AMetric: String; AReq: TMemReq;
                  ABytes, AOpsPer: LongWord; AKern: TKernel);
begin
  if MethNew then
  begin
    if MemMethodN < MaxMethods then
    begin
      MemMethod[MemMethodN].Name  := AName;
      MemMethod[MemMethodN].Small := MemTestN;
      MemMethod[MemMethodN].Big   := -1;
      Inc(MemMethodN);
    end;
  end
  else if MethIdx < MemMethodN then MemMethod[MethIdx].Big := MemTestN;
  Inc(MethIdx);
  AddTest(AId, AName + ', ' + MethWhere, AMetric, AReq, ABytes, AOpsPer, AKern);
end;

procedure AddMethodSet(Bytes: LongWord; const Tag, Where: String; First: Boolean);
begin
  MethWhere := Where;
  MethIdx   := 0;
  MethNew   := First;
  AddMeth('rdw' + Tag, 'read 16-bit',      'MB/s',   mrAny, Bytes, Bytes, @KRdW);
  AddMeth('rdd' + Tag, 'read 32-bit',      'MB/s',   mr386, Bytes, Bytes, @KRdD);
  AddMeth('rdq' + Tag, 'read MMX',         'MB/s',   mrMmx, Bytes, Bytes, @KRdQ);
  AddMeth('rdu' + Tag, 'read odd address', 'MB/s',   mrAny, Bytes, Bytes, @KRdWu);
  AddMeth('lds' + Tag, 'REP LODSW',        'MB/s',   mrAny, Bytes, Bytes, @KLodsw);
  AddMeth('wrw' + Tag, 'write 16-bit',     'MB/s',   mrAny, Bytes, Bytes, @KWrW);
  AddMeth('wrd' + Tag, 'write 32-bit',     'MB/s',   mr386, Bytes, Bytes, @KWrD);
  AddMeth('wrq' + Tag, 'write MMX',        'MB/s',   mrMmx, Bytes, Bytes, @KWrQ);
  AddMeth('sto' + Tag, 'REP STOSW',        'MB/s',   mrAny, Bytes, Bytes, @KStosw);
  AddMeth('std' + Tag, 'REP STOSD',        'MB/s',   mr386, Bytes, Bytes, @KStosd);
  AddMeth('wrf' + Tag, 'write FPU 64-bit', 'MB/s',   mrFpu, Bytes, Bytes, @KWrF);
  AddMeth('mvw' + Tag, 'REP MOVSW copy',   'MB/s',   mrAny, Bytes, Bytes, @KMovsw);
  AddMeth('mvd' + Tag, 'REP MOVSD copy',   'MB/s',   mr386, Bytes, Bytes, @KMovsd);
  AddMeth('cpw' + Tag, 'loop copy 16-bit', 'MB/s',   mrAny, Bytes, Bytes, @KCopyW);
  AddMeth('cpd' + Tag, 'loop copy 32-bit', 'MB/s',   mr386, Bytes, Bytes, @KCopyD);
  AddMeth('cpf' + Tag, 'FPU copy 64-bit',  'MB/s',   mrFpu, Bytes, Bytes, @KCopyF);
  AddMeth('rnd' + Tag, 'scattered read',   'Macc/s', mrAny, Bytes, Bytes div 2, @KRand);
end;

function MemTestsInit: Boolean;
var
  Want, Got : LongInt;
  I, J      : Integer;
  Sweep     : TKernel;
begin
  MemTestsInit := False;
  MemReady := False;
  MemTestN := 0;
  MemCurveN := 0;
  MemMethodN := 0;
  MemSmallKb := 0;
  MemBigKb := 0;

  { Take the largest block DOS will part with, less a margin so the runtime
    can still open the report file afterwards, and cap it at the largest
    sweep size we have any use for.

    Sweep and copy are sized separately from that one block. Sizing both to
    the same figure - as asking for twice the sweep size would - costs half
    the curve to benefit two tests: on a 406 KB machine the sweep stopped at
    192 KB when 384 KB was there for the reading. Only the copy tests need a
    destination, so only they are held to half the buffer. }
  Want := FarMaxAvail - 32768;
  if Want > LongInt(SweepSizes[High(SweepSizes)]) + ChasePad then
    Want := LongInt(SweepSizes[High(SweepSizes)]) + ChasePad;
  if Want < 1024 + ChasePad then Exit;
  if not FarAlloc(Want, Buf) then Exit;

  Got := Want;
  MemBufBytes := Got;
  MemReady    := True;

  MemMaxSweep := 0;
  MemBigWs    := 0;
  for I := 0 to High(SweepSizes) do
  begin
    if LongInt(SweepSizes[I]) + ChasePad <= Got then
      MemMaxSweep := SweepSizes[I];
    if LongInt(SweepSizes[I]) * 2 + ChasePad <= Got then
      MemBigWs := SweepSizes[I];
  end;
  if MemMaxSweep = 0 then
  begin
    FarFree(Buf);
    MemReady := False;
    Exit;
  end;

  FarFill(Buf, 1);
  if MemMaxSweep >= 65536 then
    BuildChase(65536)
  else
    BuildChase(MemMaxSweep);

  if CpuClass >= cc80386 then Sweep := @KRdD else Sweep := @KRdW;

  { --- the curve --- }
  MemCurveN := 0;
  for I := 0 to High(SweepSizes) do
    if SweepSizes[I] <= MemMaxSweep then
    begin
      MemCurve[MemCurveN].Kb   := SweepSizes[I] div 1024;
      MemCurve[MemCurveN].Read := MemTestN;
      MemCurve[MemCurveN].Lat  := -1;
      Inc(MemCurveN);
      AddTest('rd' + KbStr(SweepSizes[I]),
              'sequential read, ' + KbStr(SweepSizes[I]),
              'MB/s', mrAny, SweepSizes[I], SweepSizes[I], Sweep);
    end;

  { --- latency --- }
  { Every chase size is also a sweep size, so each chase lands on a curve
    point that already exists rather than adding one of its own. }
  for I := 0 to High(ChaseSizes) do
    if ChaseSizes[I] <= MemMaxSweep then
    begin
      for J := 0 to MemCurveN - 1 do
        if MemCurve[J].Kb = ChaseSizes[I] div 1024 then MemCurve[J].Lat := MemTestN;
      AddTest('lat' + KbStr(ChaseSizes[I]),
              'pointer chase, ' + KbStr(ChaseSizes[I]),
              'Macc/s', mrAny, ChaseSizes[I], 8, @KChase);
    end;

  { --- methods, in cache and out of it --- }
  { Labelled by size rather than by 'in cache' / 'out of cache': which one a
    given size actually is depends on the machine, and that is what the
    sweep is there to answer rather than assume. }
  MemSmallKb := SmallWs div 1024;
  AddMethodSet(SmallWs, 'S', KbStr(SmallWs), True);
  if MemBigWs > SmallWs then
  begin
    MemBigKb := MemBigWs div 1024;
    AddMethodSet(MemBigWs, 'B', KbStr(MemBigWs), False);
  end;

  for I := 0 to MemTestN - 1 do
  begin
    MemTestRes[I].Ran      := False;
    MemTestRes[I].Skipped  := False;
    MemTestRes[I].Why      := '';
    MemTestRes[I].Value    := 0;
    MemTestRes[I].SpreadPc := 0;
  end;

  MemTestsInit := True;
end;

procedure MemTestsDone;
begin
  if MemReady then
  begin
    FarFree(Buf);
    MemReady := False;
  end;
end;

function Supported(const T: TMemTest; var Why: String): Boolean;
begin
  Why := '';
  case T.Req of
    mr386: begin
             Supported := CpuClass >= cc80386;
             if CpuClass < cc80386 then Why := 'needs 386 or up';
           end;
    mrFpu: begin
             Supported := HasFpu;
             if not HasFpu then Why := 'no FPU';
           end;
    mrMmx: begin
             Supported := HasMmx;
             if not HasMmx then Why := 'no MMX';
           end;
  else
    Supported := True;
  end;
end;

procedure MemTestRun(I: Integer);
var
  R   : TBenchResult;
  Why : String;
begin
  if (I < 0) or (I >= MemTestN) or (not MemReady) then Exit;

  MemTestRes[I].Ran     := False;
  MemTestRes[I].Skipped := False;
  MemTestRes[I].Value   := 0;

  if not Supported(MemTests[I], Why) then
  begin
    MemTestRes[I].Skipped := True;
    MemTestRes[I].Why     := Why;
    Exit;
  end;

  if not SetWorkingSet(MemTests[I].Bytes) then
  begin
    MemTestRes[I].Skipped := True;
    MemTestRes[I].Why     := 'working set does not fit';
    Exit;
  end;

  { The chase walks a permutation of the whole 64 KB segment; restrict it to
    the working set under test by rebuilding it at that size. }
  if MemTests[I].Kern = TKernel(@KChase) then
    BuildChase(MemTests[I].Bytes);

  R := RunBench(MemTests[I].Kern);

  { Whatever the chase left behind, put the buffer back to a known state so
    the next test does not inherit a permutation as its data. }
  if MemTests[I].Kern = TKernel(@KChase) then
    FarFill(Buf, 1);

  if not R.Ok then
  begin
    MemTestRes[I].Skipped := True;
    if R.Aborted then
      MemTestRes[I].Why := 'cancelled'
    else if R.TooFast then
      MemTestRes[I].Why := 'too fast to time'
    else if R.Overrun then
      MemTestRes[I].Why := 'took too long'
    else
      MemTestRes[I].Why := 'no result';
    Exit;
  end;

  MemTestRes[I].Ran      := True;
  MemTestRes[I].Value    := R.Rate * MemTests[I].OpsPer;
  MemTestRes[I].SpreadPc := R.SpreadPc;
end;

procedure MemTestRunAll;
var
  I: Integer;
begin
  for I := 0 to MemTestN - 1 do
  begin
    MemTestRun(I);
    if BenchAborted then Break;
  end;
end;

begin
  MemTestN := 0;
  MemCurveN := 0;
  MemMethodN := 0;
  MemSmallKb := 0;
  MemBigKb := 0;
  MemReady := False;
end.
