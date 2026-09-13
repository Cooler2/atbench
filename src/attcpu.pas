unit attcpu;
{ ----------------------------------------------------------------------------
  ATBench - the CPU tests.

  Every kernel here is assembler, per the rule in DESIGN.md 1.3: what is
  being measured is the machine, not the code generator. The Pascal around
  them only decides which ones are legal to run and multiplies the harness's
  units/second by the work done per unit.

  Shape of a kernel: an inner loop with the operation under test unrolled
  enough times that the DEC/JNZ closing the loop is a small fraction of the
  cost, plus a JCXZ guard so a unit count of zero cannot turn into 65536
  iterations. One "unit" is one pass through that loop, and OpsPer says how
  many operations - or bytes - that pass performed.

  Two deliberate choices worth stating:

  * Independent operands, not dependency chains, in the ALU tests. A chain
    measures latency and would flatten a Pentium to the level of a 386; four
    independent accumulators measure what the machine can actually issue,
    which is the difference the report is there to show.

  * The block used by the string tests is 1 KB, small enough to sit in L1 on
    everything from a 486 up. This is a CPU test: it should measure how fast
    REP MOVSW retires, not how fast the DRAM is. Memory is ATTMEM's job.
  ---------------------------------------------------------------------------- }

interface

uses attime, atharn, atcpuid;

{$I at.inc}
{$asmcpu PENTIUM}

type
  { What a test needs before it may be run at all. }
  TReq = (rqAny, rq386, rqFpu, rqFpu387, rqMmx);

  TCpuTest = record
    Id     : String[8];      { key in the report and in the database }
    Title  : String[30];
    Metric : String[9];      { 'Mops/s', 'MB/s', 'Mflop/s' }
    Req    : TReq;
    OpsPer : LongWord;       { operations, or bytes, per unit }
    Kern   : TKernel;
  end;

  TCpuTestRes = record
    Ran      : Boolean;
    Skipped  : Boolean;
    Why      : String[28];   { why it was skipped }
    Value    : LongWord;     { operations or bytes per second }
    SpreadPc : Word;
  end;

const
  MaxCpuTests = 40;

var
  CpuTests    : array[0..MaxCpuTests - 1] of TCpuTest;
  CpuTestRes  : array[0..MaxCpuTests - 1] of TCpuTestRes;
  CpuTestN    : Integer;

{ Builds the table. Call CpuDetect first - the table depends on what the
  machine turned out to be. }
procedure CpuTestsInit;

{ Runs test I. Safe to call for a test the machine cannot support: it will
  be marked skipped instead. }
procedure CpuTestRun(I: Integer);

{ Runs the lot. Stops early if the user pressed ESC. }
procedure CpuTestRunAll;

function CpuTestSupported(const T: TCpuTest; var Why: String): Boolean;

{ Runs one rotation through each implementation the machine supports and
  checks they agree. Returns '' when they do. Cheap, and it catches the one
  class of bug a timing harness cannot: a kernel that is fast because it is
  computing the wrong thing. }
function CpuSelfCheck: String;

implementation

{ ------------------------------------------------------------------- data }

const
  BlkWords = 512;                { 1 KB - stays inside L1 on a 486 }
  BlkBytes = BlkWords * 2;

var
  { BufA is never written by any kernel and BufB only ever receives a copy of
    BufA, so the two stay identical for the whole run - which REPE CMPSW
    depends on to scan the full block instead of stopping at the first
    mismatch. STOSW therefore fills a buffer of its own: pointing it at BufB
    made CMPSW terminate after one word while still being credited with a
    kilobyte, and it reported anything from 125 MB/s to 3079 MB/s depending
    on which test had run before it. }
  BufA  : array[0..BlkWords - 1] of Word;
  BufB  : array[0..BlkWords - 1] of Word;
  BufC  : array[0..BlkWords - 1] of Word;
  MisBuf: array[0..255] of Byte;      { for the misaligned load/store test }
  BrTab : array[0..255] of Byte;      { branch directions }
  BrRnd : array[0..255] of Byte;

  { Fixed point, 16.16 and 8.8. Read-only inputs and a scratch output that is
    never read back, so nothing can drift, overflow or degenerate however
    long the test runs.

    The Rot prefix is not decoration: the assembler resolves operand names
    against the register table first, so a variable called Fs, Ss, Dx or Ds
    is read as a register and the instruction quietly means something else. }
  RotFx, RotFy   : LongInt;
  RotFc, RotFs   : LongInt;
  RotFnx, RotFny : LongInt;
  RotSx, RotSy   : Integer;
  RotSc, RotSs   : Integer;
  RotSnx, RotSny : Integer;

  { The same rotation in double precision. }
  RotDx, RotDy   : Double;
  RotDc, RotDs   : Double;
  RotDnx, RotDny : Double;

  D1, D2, DHalf, DTwo : Double;

  MmA, MmB : array[0..3] of Word;
  MmC      : array[0..3] of Word;

{ ------------------------------------------------------- integer, 16-bit }

procedure KAlu16(Units: Word); assembler;
asm
    push si
    push di
    mov  cx, Units
    jcxz @@x
    mov  ax, 1
    mov  bx, 3
    mov  dx, 5
    mov  si, 7
  @@l:
    add  ax, 3
    add  bx, 5
    add  dx, 7
    add  si, 11
    xor  ax, 13
    xor  bx, 17
    xor  dx, 19
    xor  si, 23
    sub  ax, 2
    sub  bx, 4
    sub  dx, 6
    sub  si, 8
    add  ax, 1
    add  bx, 1
    add  dx, 1
    add  si, 1
    dec  cx
    jnz  @@l
  @@x:
    pop  di
    pop  si
end;

procedure KShift16(Units: Word); assembler;
asm
    push si
    push di
    mov  cx, Units
    jcxz @@x
    mov  ax, 12345
    mov  bx, 23456
    mov  dx, 4567
    mov  si, 8901
  @@l:
    shl  ax, 1
    shr  bx, 1
    rol  dx, 1
    ror  si, 1
    shl  ax, 3
    shr  bx, 3
    rol  dx, 3
    ror  si, 3
    sar  ax, 1
    sar  bx, 1
    rol  dx, 5
    ror  si, 5
    shl  ax, 1
    shr  bx, 1
    rol  dx, 1
    ror  si, 1
    dec  cx
    jnz  @@l
  @@x:
    pop  di
    pop  si
end;

{ AX is reloaded before each MUL, so the multiplier is never waiting on the
  previous result - this is throughput, not latency. }
procedure KMul16(Units: Word); assembler;
asm
    push si
    mov  cx, Units
    jcxz @@x
    mov  bx, 31
  @@l:
    mov  ax, 12345
    mul  bx
    mov  ax, 23456
    mul  bx
    mov  ax, 34567
    mul  bx
    mov  ax, 45678
    mul  bx
    mov  ax, 12345
    mul  bx
    mov  ax, 23456
    mul  bx
    mov  ax, 34567
    mul  bx
    mov  ax, 45678
    mul  bx
    dec  cx
    jnz  @@l
  @@x:
    pop  si
end;

{ DX is cleared and AX reloaded before every DIV: the quotient always fits in
  16 bits, so a divide overflow - INT 0, and on DOS a dead machine - is not
  merely unlikely but arithmetically impossible. }
procedure KDiv16(Units: Word); assembler;
asm
    push si
    mov  cx, Units
    jcxz @@x
    mov  bx, 31
  @@l:
    xor  dx, dx
    mov  ax, 60000
    div  bx
    xor  dx, dx
    mov  ax, 50000
    div  bx
    xor  dx, dx
    mov  ax, 40000
    div  bx
    xor  dx, dx
    mov  ax, 30000
    div  bx
    xor  dx, dx
    mov  ax, 60000
    div  bx
    xor  dx, dx
    mov  ax, 50000
    div  bx
    xor  dx, dx
    mov  ax, 40000
    div  bx
    xor  dx, dx
    mov  ax, 30000
    div  bx
    dec  cx
    jnz  @@l
  @@x:
    pop  si
end;

procedure KLdSt16(Units: Word); assembler;
asm
    push si
    push di
    mov  cx, Units
    jcxz @@x
    lea  si, BufA
    lea  di, BufB
  @@l:
    mov  ax, [si]
    mov  [di], ax
    mov  bx, [si+2]
    mov  [di+2], bx
    mov  dx, [si+4]
    mov  [di+4], dx
    mov  ax, [si+6]
    mov  [di+6], ax
    mov  bx, [si+8]
    mov  [di+8], bx
    mov  dx, [si+10]
    mov  [di+10], dx
    mov  ax, [si+12]
    mov  [di+12], ax
    mov  bx, [si+14]
    mov  [di+14], bx
    dec  cx
    jnz  @@l
  @@x:
    pop  di
    pop  si
end;

{ The same eight loads and eight stores, one byte off. On a 16-bit bus every
  one of them becomes two bus cycles. }
procedure KLdSt16u(Units: Word); assembler;
asm
    push si
    push di
    mov  cx, Units
    jcxz @@x
    lea  si, MisBuf
    inc  si
    lea  di, MisBuf
    add  di, 129
  @@l:
    mov  ax, [si]
    mov  [di], ax
    mov  bx, [si+2]
    mov  [di+2], bx
    mov  dx, [si+4]
    mov  [di+4], dx
    mov  ax, [si+6]
    mov  [di+6], ax
    mov  bx, [si+8]
    mov  [di+8], bx
    mov  dx, [si+10]
    mov  [di+10], dx
    mov  ax, [si+12]
    mov  [di+12], ax
    mov  bx, [si+14]
    mov  [di+14], bx
    dec  cx
    jnz  @@l
  @@x:
    pop  di
    pop  si
end;

procedure KStack(Units: Word); assembler;
asm
    push si
    mov  cx, Units
    jcxz @@x
    mov  ax, 1234
    mov  bx, 5678
  @@l:
    push ax
    push bx
    pop  bx
    pop  ax
    push ax
    push bx
    pop  bx
    pop  ax
    push ax
    push bx
    pop  bx
    pop  ax
    push ax
    push bx
    pop  bx
    pop  ax
    dec  cx
    jnz  @@l
  @@x:
    pop  si
end;

{ An empty far procedure: in the medium memory model every call between
  units costs a far call and a far return, which is the number this measures
  and the reason medium-model Pascal is slower than it looks. }
procedure EmptyFar; far; assembler;
asm
end;

procedure KFarCall(Units: Word); assembler;
asm
    push si
    push di
    mov  cx, Units
    jcxz @@x
  @@l:
    call EmptyFar
    call EmptyFar
    call EmptyFar
    call EmptyFar
    call EmptyFar
    call EmptyFar
    call EmptyFar
    call EmptyFar
    dec  cx
    jnz  @@l
  @@x:
    pop  di
    pop  si
end;

procedure KSegLoad(Units: Word); assembler;
asm
    push si
    push es
    mov  cx, Units
    jcxz @@x
    mov  ax, ds
    mov  bx, ds
  @@l:
    mov  es, ax
    mov  es, bx
    mov  es, ax
    mov  es, bx
    mov  es, ax
    mov  es, bx
    mov  es, ax
    mov  es, bx
    dec  cx
    jnz  @@l
  @@x:
    pop  es
    pop  si
end;

{ Eight conditional branches per unit, taken from a table. The two kernels
  are identical instruction for instruction; only the table differs - all
  zeros in one, pseudorandom in the other. Whatever is left after subtracting
  one rate from the other is the branch predictor, and on a Pentium that gap
  is the single most eloquent number in the CPU section. }
procedure BranchBody; assembler;
asm
end;

procedure KBranchP(Units: Word); assembler;
asm
    push si
    push di
    mov  cx, Units
    jcxz @@x
    lea  bx, BrTab
    xor  di, di
    xor  dx, dx
  @@l:
    mov  al, [bx+di]
    inc  di
    and  di, 255
    test al, al
    jz   @@n1
    inc  dx
  @@n1:
    mov  al, [bx+di]
    inc  di
    and  di, 255
    test al, al
    jz   @@n2
    inc  dx
  @@n2:
    mov  al, [bx+di]
    inc  di
    and  di, 255
    test al, al
    jz   @@n3
    inc  dx
  @@n3:
    mov  al, [bx+di]
    inc  di
    and  di, 255
    test al, al
    jz   @@n4
    inc  dx
  @@n4:
    mov  al, [bx+di]
    inc  di
    and  di, 255
    test al, al
    jz   @@n5
    inc  dx
  @@n5:
    mov  al, [bx+di]
    inc  di
    and  di, 255
    test al, al
    jz   @@n6
    inc  dx
  @@n6:
    mov  al, [bx+di]
    inc  di
    and  di, 255
    test al, al
    jz   @@n7
    inc  dx
  @@n7:
    mov  al, [bx+di]
    inc  di
    and  di, 255
    test al, al
    jz   @@n8
    inc  dx
  @@n8:
    dec  cx
    jnz  @@l
  @@x:
    pop  di
    pop  si
end;

procedure KBranchR(Units: Word); assembler;
asm
    push si
    push di
    mov  cx, Units
    jcxz @@x
    lea  bx, BrRnd
    xor  di, di
    xor  dx, dx
  @@l:
    mov  al, [bx+di]
    inc  di
    and  di, 255
    test al, al
    jz   @@n1
    inc  dx
  @@n1:
    mov  al, [bx+di]
    inc  di
    and  di, 255
    test al, al
    jz   @@n2
    inc  dx
  @@n2:
    mov  al, [bx+di]
    inc  di
    and  di, 255
    test al, al
    jz   @@n3
    inc  dx
  @@n3:
    mov  al, [bx+di]
    inc  di
    and  di, 255
    test al, al
    jz   @@n4
    inc  dx
  @@n4:
    mov  al, [bx+di]
    inc  di
    and  di, 255
    test al, al
    jz   @@n5
    inc  dx
  @@n5:
    mov  al, [bx+di]
    inc  di
    and  di, 255
    test al, al
    jz   @@n6
    inc  dx
  @@n6:
    mov  al, [bx+di]
    inc  di
    and  di, 255
    test al, al
    jz   @@n7
    inc  dx
  @@n7:
    mov  al, [bx+di]
    inc  di
    and  di, 255
    test al, al
    jz   @@n8
    inc  dx
  @@n8:
    dec  cx
    jnz  @@l
  @@x:
    pop  di
    pop  si
end;

{ ---------------------------------------------------------- string moves }

procedure KMovsb(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  ax, ds
    mov  es, ax
    mov  dx, Units
    or   dx, dx
    jz   @@x
  @@l:
    lea  si, BufA
    lea  di, BufB
    mov  cx, BlkBytes
    cld
    rep  movsb
    dec  dx
    jnz  @@l
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
    mov  ax, ds
    mov  es, ax
    mov  dx, Units
    or   dx, dx
    jz   @@x
  @@l:
    lea  si, BufA
    lea  di, BufB
    mov  cx, BlkWords
    cld
    rep  movsw
    dec  dx
    jnz  @@l
  @@x:
    pop  es
    pop  di
    pop  si
end;

procedure KStosw(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  bx, ds
    mov  es, bx
    mov  dx, Units
    or   dx, dx
    jz   @@x
    mov  ax, 5A5Ah
  @@l:
    lea  di, BufC
    mov  cx, BlkWords
    cld
    rep  stosw
    dec  dx
    jnz  @@l
  @@x:
    pop  es
    pop  di
    pop  si
end;

{ Searches for a value the buffer is guaranteed not to contain, so the scan
  always runs to the end and always measures the same amount of work. }
procedure KScasw(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  bx, ds
    mov  es, bx
    mov  dx, Units
    or   dx, dx
    jz   @@x
  @@l:
    lea  di, BufA
    mov  cx, BlkWords
    mov  ax, 0FFFFh
    cld
    repne scasw
    dec  dx
    jnz  @@l
  @@x:
    pop  es
    pop  di
    pop  si
end;

{ BufA and BufB hold the same bytes, so REPE runs the full length. }
procedure KCmpsw(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  ax, ds
    mov  es, ax
    mov  dx, Units
    or   dx, dx
    jz   @@x
  @@l:
    lea  si, BufA
    lea  di, BufB
    mov  cx, BlkWords
    cld
    repe cmpsw
    dec  dx
    jnz  @@l
  @@x:
    pop  es
    pop  di
    pop  si
end;

{ -------------------------------------------------------- integer, 32-bit }

procedure KAlu32(Units: Word); assembler;
asm
    push si
    push di
    mov  cx, Units
    jcxz @@x
    mov  eax, 1
    mov  ebx, 3
    mov  edx, 5
    mov  esi, 7
  @@l:
    add  eax, 3
    add  ebx, 5
    add  edx, 7
    add  esi, 11
    xor  eax, 13
    xor  ebx, 17
    xor  edx, 19
    xor  esi, 23
    sub  eax, 2
    sub  ebx, 4
    sub  edx, 6
    sub  esi, 8
    add  eax, 1
    add  ebx, 1
    add  edx, 1
    add  esi, 1
    dec  cx
    jnz  @@l
  @@x:
    pop  di
    pop  si
end;

procedure KShift32(Units: Word); assembler;
asm
    push si
    push di
    mov  cx, Units
    jcxz @@x
    mov  eax, 123456789
    mov  ebx, 234567891
    mov  edx, 345678912
    mov  esi, 456789123
  @@l:
    shl  eax, 1
    shr  ebx, 1
    rol  edx, 1
    ror  esi, 1
    shl  eax, 3
    shr  ebx, 3
    rol  edx, 3
    ror  esi, 3
    sar  eax, 1
    sar  ebx, 1
    rol  edx, 5
    ror  esi, 5
    shl  eax, 1
    shr  ebx, 1
    rol  edx, 1
    ror  esi, 1
    dec  cx
    jnz  @@l
  @@x:
    pop  di
    pop  si
end;

procedure KMul32(Units: Word); assembler;
asm
    push si
    push di
    mov  cx, Units
    jcxz @@x
    mov  ebx, 31
  @@l:
    mov  eax, 1234567
    mul  ebx
    mov  eax, 2345678
    mul  ebx
    mov  eax, 3456789
    mul  ebx
    mov  eax, 4567891
    mul  ebx
    mov  eax, 1234567
    mul  ebx
    mov  eax, 2345678
    mul  ebx
    mov  eax, 3456789
    mul  ebx
    mov  eax, 4567891
    mul  ebx
    dec  cx
    jnz  @@l
  @@x:
    pop  di
    pop  si
end;

procedure KDiv32(Units: Word); assembler;
asm
    push si
    push di
    mov  cx, Units
    jcxz @@x
    mov  ebx, 31
  @@l:
    xor  edx, edx
    mov  eax, 1234567890
    div  ebx
    xor  edx, edx
    mov  eax, 1034567890
    div  ebx
    xor  edx, edx
    mov  eax, 934567890
    div  ebx
    xor  edx, edx
    mov  eax, 834567890
    div  ebx
    xor  edx, edx
    mov  eax, 1234567890
    div  ebx
    xor  edx, edx
    mov  eax, 1034567890
    div  ebx
    xor  edx, edx
    mov  eax, 934567890
    div  ebx
    xor  edx, edx
    mov  eax, 834567890
    div  ebx
    dec  cx
    jnz  @@l
  @@x:
    pop  di
    pop  si
end;

{ BSF and BT: the sources are never zero, so BSF's result is always defined
  and the loop is free of any dependence on undefined behaviour. }
procedure KBitScan(Units: Word); assembler;
asm
    push si
    push di
    mov  cx, Units
    jcxz @@x
    mov  esi, 12345678
    mov  edi, 987654321
  @@l:
    bsf  eax, esi
    bsr  ebx, esi
    bsf  edx, edi
    bsr  eax, edi
    bt   esi, 5
    bt   edi, 9
    bt   esi, 17
    bt   edi, 23
    bsf  eax, esi
    bsr  ebx, esi
    bsf  edx, edi
    bsr  eax, edi
    bt   esi, 5
    bt   edi, 9
    bt   esi, 17
    bt   edi, 23
    dec  cx
    jnz  @@l
  @@x:
    pop  di
    pop  si
end;

procedure KMovsd(Units: Word); assembler;
asm
    push si
    push di
    push es
    mov  ax, ds
    mov  es, ax
    mov  dx, Units
    or   dx, dx
    jz   @@x
  @@l:
    lea  si, BufA
    lea  di, BufB
    mov  cx, BlkWords / 2
    cld
    rep  movsd
    dec  dx
    jnz  @@l
  @@x:
    pop  es
    pop  di
    pop  si
end;

{ ----------------------------------------------- the same rotation, thrice }

{ x' = x*c - y*s ;  y' = x*s + y*c

  Three implementations of one algorithm: 16.16 fixed point, 8.8 fixed point
  and double-precision x87. Their ratio is the number that actually decides
  how a program of this era should have been written - and it inverts
  somewhere around the 486DX, which is exactly what the report should show.

  Inputs are read from memory and results go to a scratch that is never read
  back. Nothing accumulates, so the values cannot drift towards zero or
  overflow however many million times the loop runs. }

procedure KFix1616(Units: Word); assembler;
asm
    push si
    push di
    mov  cx, Units
    jcxz @@x
  @@l:
    mov  eax, RotFx
    imul dword ptr RotFc
    shrd eax, edx, 16
    mov  esi, eax
    mov  eax, RotFy
    imul dword ptr RotFs
    shrd eax, edx, 16
    sub  esi, eax

    mov  eax, RotFx
    imul dword ptr RotFs
    shrd eax, edx, 16
    mov  edi, eax
    mov  eax, RotFy
    imul dword ptr RotFc
    shrd eax, edx, 16
    add  edi, eax

    mov  RotFnx, esi
    mov  RotFny, edi
    dec  cx
    jnz  @@l
  @@x:
    pop  di
    pop  si
end;

{ 8.8 for the 286, which has no 32-bit multiply to do 16.16 with. The lower
  precision is the historical answer, not a shortcut: this is why the demos
  of the day used 8.8. }
procedure KFix88(Units: Word); assembler;
asm
    push si
    push di
    mov  cx, Units
    jcxz @@x
  @@l:
    mov  ax, RotSx
    imul word ptr RotSc
    mov  al, ah
    mov  ah, dl
    mov  si, ax
    mov  ax, RotSy
    imul word ptr RotSs
    mov  al, ah
    mov  ah, dl
    sub  si, ax

    mov  ax, RotSx
    imul word ptr RotSs
    mov  al, ah
    mov  ah, dl
    mov  di, ax
    mov  ax, RotSy
    imul word ptr RotSc
    mov  al, ah
    mov  ah, dl
    add  di, ax

    mov  RotSnx, si
    mov  RotSny, di
    dec  cx
    jnz  @@l
  @@x:
    pop  di
    pop  si
end;

procedure KFpuRot(Units: Word); assembler;
asm
    push si
    push di
    mov  cx, Units
    jcxz @@x
    fninit
  @@l:
    fld  qword ptr RotDx
    fmul qword ptr RotDc
    fld  qword ptr RotDy
    fmul qword ptr RotDs
    fsubp st(1), st(0)
    fld  qword ptr RotDx
    fmul qword ptr RotDs
    fld  qword ptr RotDy
    fmul qword ptr RotDc
    faddp st(1), st(0)
    fstp qword ptr RotDny
    fstp qword ptr RotDnx
    dec  cx
    jnz  @@l
    fninit
  @@x:
    pop  di
    pop  si
end;

{ ------------------------------------------------------------------- x87 }

{ Adding then subtracting the same value keeps ST(0) exactly where it
  started, so the register can never wander off into infinity or a NaN no
  matter how long the test runs. }
procedure KFadd(Units: Word); assembler;
asm
    push si
    mov  cx, Units
    jcxz @@x
    fninit
    fld  qword ptr D1
    fld  qword ptr D2
  @@l:
    fadd st(0), st(1)
    fsub st(0), st(1)
    fadd st(0), st(1)
    fsub st(0), st(1)
    fadd st(0), st(1)
    fsub st(0), st(1)
    fadd st(0), st(1)
    fsub st(0), st(1)
    dec  cx
    jnz  @@l
    fninit
  @@x:
    pop  si
end;

{ Multiply by two, then by a half. Same argument as above. }
procedure KFmul(Units: Word); assembler;
asm
    push si
    mov  cx, Units
    jcxz @@x
    fninit
    fld  qword ptr DHalf
    fld  qword ptr DTwo
    fld  qword ptr D1
  @@l:
    fmul st(0), st(1)
    fmul st(0), st(2)
    fmul st(0), st(1)
    fmul st(0), st(2)
    fmul st(0), st(1)
    fmul st(0), st(2)
    fmul st(0), st(1)
    fmul st(0), st(2)
    dec  cx
    jnz  @@l
    fninit
  @@x:
    pop  si
end;

procedure KFdiv(Units: Word); assembler;
asm
    push si
    mov  cx, Units
    jcxz @@x
    fninit
    fld  qword ptr DHalf
    fld  qword ptr DTwo
    fld  qword ptr D1
  @@l:
    fdiv st(0), st(1)
    fdiv st(0), st(2)
    fdiv st(0), st(1)
    fdiv st(0), st(2)
    dec  cx
    jnz  @@l
    fninit
  @@x:
    pop  si
end;

{ Repeated square roots converge on 1.0 and stay there; the argument is
  always positive, so the invalid-operation case cannot arise. }
procedure KFsqrt(Units: Word); assembler;
asm
    push si
    mov  cx, Units
    jcxz @@x
    fninit
    fld  qword ptr DTwo
  @@l:
    fsqrt
    fsqrt
    fsqrt
    fsqrt
    fsqrt
    fsqrt
    fsqrt
    fsqrt
    dec  cx
    jnz  @@l
    fninit
  @@x:
    pop  si
end;

{ F2XM1 rather than FSIN, because every x87 from the 8087 onwards has it -
  so this one number is comparable across the whole range. Its argument must
  lie in [-1,+1]; the value is reloaded each time round, so it always does. }
procedure KF2xm1(Units: Word); assembler;
asm
    push si
    mov  cx, Units
    jcxz @@x
    fninit
  @@l:
    fld  qword ptr DHalf
    f2xm1
    fstp st(0)
    fld  qword ptr DHalf
    f2xm1
    fstp st(0)
    fld  qword ptr DHalf
    f2xm1
    fstp st(0)
    fld  qword ptr DHalf
    f2xm1
    fstp st(0)
    dec  cx
    jnz  @@l
    fninit
  @@x:
    pop  si
end;

{ FSIN exists only from the 387 on - hence rqFpu387, decided by the
  projective/affine probe in ATCPUID rather than by guessing from the CPU. }
procedure KFsin(Units: Word); assembler;
asm
    push si
    mov  cx, Units
    jcxz @@x
    fninit
  @@l:
    fld  qword ptr D1
    fsin
    fstp st(0)
    fld  qword ptr D1
    fsin
    fstp st(0)
    fld  qword ptr D1
    fsin
    fstp st(0)
    fld  qword ptr D1
    fsin
    fstp st(0)
    dec  cx
    jnz  @@l
    fninit
  @@x:
    pop  si
end;

{ ------------------------------------------------------------------- MMX }

procedure KMmxAdd(Units: Word); assembler;
asm
    push si
    mov  cx, Units
    jcxz @@x
    movq mm0, qword ptr MmA
    movq mm1, qword ptr MmB
    movq mm2, qword ptr MmA
    movq mm3, qword ptr MmB
  @@l:
    paddw mm0, mm1
    paddw mm2, mm3
    psubw mm0, mm1
    psubw mm2, mm3
    paddw mm0, mm1
    paddw mm2, mm3
    psubw mm0, mm1
    psubw mm2, mm3
    dec  cx
    jnz  @@l
    movq qword ptr MmC, mm0
    emms
  @@x:
    pop  si
end;

procedure KMmxMul(Units: Word); assembler;
asm
    push si
    mov  cx, Units
    jcxz @@x
    movq mm1, qword ptr MmB
    movq mm3, qword ptr MmB
  @@l:
    movq  mm0, qword ptr MmA
    pmullw mm0, mm1
    movq  mm2, qword ptr MmA
    pmullw mm2, mm3
    movq  mm4, qword ptr MmA
    pmullw mm4, mm1
    movq  mm5, qword ptr MmA
    pmullw mm5, mm3
    movq  mm0, qword ptr MmA
    pmullw mm0, mm1
    movq  mm2, qword ptr MmA
    pmullw mm2, mm3
    movq  mm4, qword ptr MmA
    pmullw mm4, mm1
    movq  mm5, qword ptr MmA
    pmullw mm5, mm3
    dec  cx
    jnz  @@l
    movq qword ptr MmC, mm0
    emms
  @@x:
    pop  si
end;

procedure KMmxPack(Units: Word); assembler;
asm
    push si
    mov  cx, Units
    jcxz @@x
    movq mm0, qword ptr MmA
    movq mm1, qword ptr MmB
  @@l:
    movq     mm2, mm0
    packuswb mm2, mm1
    movq     mm3, mm0
    packssdw mm3, mm1
    movq     mm4, mm0
    punpcklwd mm4, mm1
    movq     mm5, mm0
    punpckhwd mm5, mm1
    movq     mm2, mm0
    packuswb mm2, mm1
    movq     mm3, mm0
    packssdw mm3, mm1
    movq     mm4, mm0
    punpcklwd mm4, mm1
    movq     mm5, mm0
    punpckhwd mm5, mm1
    dec  cx
    jnz  @@l
    movq qword ptr MmC, mm2
    emms
  @@x:
    pop  si
end;

{ ------------------------------------------------------------- the table }

{ No WITH here, deliberately. Inside `with CpuTests[n] do` the field names
  win over the parameter names, so `Id := Id` assigns the field to itself and
  every test ends up nameless with an OpsPer of zero - which reads, in the
  report, as a suite that ran perfectly and measured nothing. }
procedure AddTest(const AId, ATitle, AMetric: String; AReq: TReq;
                  AOpsPer: LongWord; AKern: TKernel);
begin
  if CpuTestN >= MaxCpuTests then Exit;
  CpuTests[CpuTestN].Id     := AId;
  CpuTests[CpuTestN].Title  := ATitle;
  CpuTests[CpuTestN].Metric := AMetric;
  CpuTests[CpuTestN].Req    := AReq;
  CpuTests[CpuTestN].OpsPer := AOpsPer;
  CpuTests[CpuTestN].Kern   := AKern;
  Inc(CpuTestN);
end;

function CpuTestSupported(const T: TCpuTest; var Why: String): Boolean;
begin
  Why := '';
  case T.Req of
    rqAny:    CpuTestSupported := True;
    rq386:    begin
                CpuTestSupported := CpuClass >= cc80386;
                if CpuClass < cc80386 then Why := 'needs 386 or up';
              end;
    rqFpu:    begin
                CpuTestSupported := HasFpu;
                if not HasFpu then Why := 'no FPU';
              end;
    rqFpu387: begin
                CpuTestSupported := HasFpu and (FpuClass = fc387);
                if not HasFpu then Why := 'no FPU'
                else if FpuClass <> fc387 then Why := 'needs 387 or up';
              end;
    rqMmx:    begin
                CpuTestSupported := HasMmx;
                if not HasMmx then Why := 'no MMX';
              end;
  else
    CpuTestSupported := False;
  end;
end;

procedure InitData;
var
  I : Integer;
  S : Word;
begin
  { A pattern with no 0FFFFh in it, so REPNE SCASW never finds its needle. }
  for I := 0 to BlkWords - 1 do
  begin
    BufA[I] := Word(I * 7 + 1) and $7FFF;
    BufB[I] := BufA[I];            { REPE CMPSW must run the full length }
    BufC[I] := 0;
  end;
  for I := 0 to 255 do
    MisBuf[I] := Byte(I);

  for I := 0 to 255 do
    BrTab[I] := 0;                 { always the same way }

  S := 12345;
  for I := 0 to 255 do
  begin
    S := Word(S * 25173 + 13849);  { the 16-bit LCG used elsewhere }
    BrRnd[I] := Byte((S shr 8) and 1);
  end;

  { 0.1 radian: cos = 0.9950042, sin = 0.0998334 }
  RotFc := 65208;  RotFs := 6542;        { 16.16 }
  RotFx := 65536;  RotFy := 0;
  RotSc := 255;    RotSs := 26;          { 8.8 }
  RotSx := 256;    RotSy := 0;
  RotDc := 0.9950042; RotDs := 0.0998334;
  RotDx := 1.0;       RotDy := 0.0;

  D1 := 1.0;  D2 := 3.0;  DHalf := 0.5;  DTwo := 2.0;

  for I := 0 to 3 do
  begin
    MmA[I] := Word(1000 + I * 37);
    MmB[I] := Word(3 + I);
    MmC[I] := 0;
  end;
end;

procedure CpuTestsInit;
var
  I: Integer;
begin
  InitData;
  CpuTestN := 0;

  AddTest('alu16',  '16-bit ALU, independent',   'Mops/s', rqAny, 16, @KAlu16);
  AddTest('shift16','16-bit shifts and rotates', 'Mops/s', rqAny, 16, @KShift16);
  AddTest('mul16',  '16-bit multiply',           'Mops/s', rqAny,  8, @KMul16);
  AddTest('div16',  '16-bit divide',             'Mops/s', rqAny,  8, @KDiv16);
  AddTest('ldst16', '16-bit load/store aligned', 'Mops/s', rqAny, 16, @KLdSt16);
  AddTest('ldst16u','16-bit load/store odd addr','Mops/s', rqAny, 16, @KLdSt16u);
  AddTest('stack',  'push/pop',                  'Mops/s', rqAny, 16, @KStack);
  AddTest('farcall','far call and return',       'Mops/s', rqAny,  8, @KFarCall);
  AddTest('segload','segment register load',     'Mops/s', rqAny,  8, @KSegLoad);
  AddTest('brpred', 'branches, predictable',     'Mops/s', rqAny,  8, @KBranchP);
  AddTest('brrand', 'branches, unpredictable',   'Mops/s', rqAny,  8, @KBranchR);

  AddTest('movsb',  'REP MOVSB',   'MB/s', rqAny, BlkBytes, @KMovsb);
  AddTest('movsw',  'REP MOVSW',   'MB/s', rqAny, BlkBytes, @KMovsw);
  AddTest('stosw',  'REP STOSW',   'MB/s', rqAny, BlkBytes, @KStosw);
  AddTest('scasw',  'REPNE SCASW', 'MB/s', rqAny, BlkBytes, @KScasw);
  AddTest('cmpsw',  'REPE CMPSW',  'MB/s', rqAny, BlkBytes, @KCmpsw);

  AddTest('alu32',  '32-bit ALU, independent',   'Mops/s', rq386, 16, @KAlu32);
  AddTest('shift32','32-bit shifts and rotates', 'Mops/s', rq386, 16, @KShift32);
  AddTest('mul32',  '32-bit multiply',           'Mops/s', rq386,  8, @KMul32);
  AddTest('div32',  '32-bit divide',             'Mops/s', rq386,  8, @KDiv32);
  AddTest('bitscan','BSF/BSR/BT',                'Mops/s', rq386, 16, @KBitScan);
  AddTest('movsd',  'REP MOVSD',   'MB/s', rq386, BlkBytes, @KMovsd);

  if CpuClass >= cc80386 then
    AddTest('fix16', 'rotation, fixed 16.16', 'Mops/s', rq386, 6, @KFix1616)
  else
    AddTest('fix8',  'rotation, fixed 8.8',   'Mops/s', rqAny, 6, @KFix88);

  AddTest('fadd',   'x87 FADD, double',   'Mflop/s', rqFpu,    8, @KFadd);
  AddTest('fmul',   'x87 FMUL, double',   'Mflop/s', rqFpu,    8, @KFmul);
  AddTest('fdiv',   'x87 FDIV, double',   'Mflop/s', rqFpu,    4, @KFdiv);
  AddTest('fsqrt',  'x87 FSQRT',          'Mflop/s', rqFpu,    8, @KFsqrt);
  AddTest('f2xm1',  'x87 F2XM1',          'Mflop/s', rqFpu,    4, @KF2xm1);
  AddTest('fsin',   'x87 FSIN',           'Mflop/s', rqFpu387, 4, @KFsin);
  AddTest('frot',   'rotation, x87 double','Mflop/s', rqFpu,   6, @KFpuRot);

  AddTest('mmxadd', 'MMX PADDW/PSUBW',    'Mops/s', rqMmx, 32, @KMmxAdd);
  AddTest('mmxmul', 'MMX PMULLW',         'Mops/s', rqMmx, 32, @KMmxMul);
  AddTest('mmxpack','MMX pack and unpack','Mops/s', rqMmx, 32, @KMmxPack);

  for I := 0 to CpuTestN - 1 do
  begin
    CpuTestRes[I].Ran      := False;
    CpuTestRes[I].Skipped  := False;
    CpuTestRes[I].Why      := '';
    CpuTestRes[I].Value    := 0;
    CpuTestRes[I].SpreadPc := 0;
  end;
end;

{ The rotation of (1,0) by 0.1 radian, which every implementation should
  land on: cos and sin of 0.1. FSUBP and FADDP are the reason this check
  exists - their operand order is the classic place for an assembler to
  disagree with the programmer, and a reversed FSUBP produces -0.995 instead
  of +0.995 while costing exactly the same number of cycles. }
const
  ExpX = 0.9950042;
  ExpY = 0.0998334;
  Tol  = 0.01;          { loose enough for 8.8, tight enough to catch a sign }

function AbsD(V: Double): Double;
begin
  if V < 0 then AbsD := -V else AbsD := V;
end;

function CpuSelfCheck: String;
var
  Fx, Fy : Double;
  Msg    : String;
  I      : Integer;
  Same   : Boolean;
  Needle : Boolean;
begin
  Msg := '';

  { Preconditions the string kernels rely on, checked against the buffers as
    they are right now. Run this after the suite as well as before it and it
    becomes a regression test: any kernel that scribbles on a block another
    kernel depends on is caught here rather than showing up as an
    implausible bandwidth figure that happens to look like a fast machine. }
  Same := True;
  Needle := False;
  for I := 0 to BlkWords - 1 do
  begin
    if BufA[I] <> BufB[I] then Same := False;
    if BufA[I] = $FFFF then Needle := True;
  end;
  if not Same then
    Msg := 'CMPSW blocks differ - the scan would stop early';
  if Needle then
  begin
    if Msg <> '' then Msg := Msg + '; ';
    Msg := Msg + 'SCASW needle occurs in the block';
  end;

  InitData;

  if CpuClass >= cc80386 then
  begin
    KFix1616(1);
    Fx := RotFnx / 65536.0;
    Fy := RotFny / 65536.0;
  end
  else
  begin
    KFix88(1);
    Fx := RotSnx / 256.0;
    Fy := RotSny / 256.0;
  end;

  if (AbsD(Fx - ExpX) > Tol) or (AbsD(Fy - ExpY) > Tol) then
    Msg := 'fixed-point rotation is wrong';

  if HasFpu then
  begin
    KFpuRot(1);
    if (AbsD(RotDnx - ExpX) > Tol) or (AbsD(RotDny - ExpY) > Tol) then
    begin
      if Msg <> '' then Msg := Msg + '; ';
      Msg := Msg + 'x87 rotation is wrong';
    end
    else if (AbsD(RotDnx - Fx) > Tol) or (AbsD(RotDny - Fy) > Tol) then
    begin
      if Msg <> '' then Msg := Msg + '; ';
      Msg := Msg + 'x87 and fixed point disagree';
    end;
  end;

  InitData;
  CpuSelfCheck := Msg;
end;

procedure CpuTestRun(I: Integer);
var
  R   : TBenchResult;
  Why : String;
begin
  if (I < 0) or (I >= CpuTestN) then Exit;

  CpuTestRes[I].Ran     := False;
  CpuTestRes[I].Skipped := False;
  CpuTestRes[I].Value   := 0;

  if not CpuTestSupported(CpuTests[I], Why) then
  begin
    CpuTestRes[I].Skipped := True;
    CpuTestRes[I].Why     := Why;
    Exit;
  end;

  R := RunBench(CpuTests[I].Kern);
  if not R.Ok then
  begin
    CpuTestRes[I].Skipped := True;
    if R.Aborted then
      CpuTestRes[I].Why := 'cancelled'
    else if R.TooFast then
      CpuTestRes[I].Why := 'too fast to time'
    else if R.Overrun then
      CpuTestRes[I].Why := 'took too long'
    else
      CpuTestRes[I].Why := 'no result';
    Exit;
  end;

  CpuTestRes[I].Ran      := True;
  CpuTestRes[I].Value    := R.Rate * CpuTests[I].OpsPer;
  CpuTestRes[I].SpreadPc := R.SpreadPc;
end;

procedure CpuTestRunAll;
var
  I: Integer;
begin
  for I := 0 to CpuTestN - 1 do
  begin
    CpuTestRun(I);
    if BenchAborted then Break;
  end;
end;

begin
  CpuTestN := 0;
end.
