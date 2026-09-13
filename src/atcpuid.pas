unit atcpuid;
{ ----------------------------------------------------------------------------
  ATBench - what am I running on?

  Everything else keys off this. Which kernels are legal to execute, which
  tests appear in the report, and how a result is labelled all follow from
  the answers here, so the detection ladder must never itself be the thing
  that crashes: each rung is executed only after the rung below it has proved
  the instructions are available.

  The order is forced by the hardware:

    1. FLAGS bits 12-15 stuck high      -> 8086/8088 (or 80186)
    2. SMSW                             -> 286+ only, gives PE/EM/TS
    3. PE set                           -> we are inside V86, hence 386+
    4. FLAGS bits 12-15 settable        -> 386+
    5. EFLAGS bit 18 (AC) togglable     -> 486+
    6. EFLAGS bit 21 (ID) togglable     -> CPUID exists
    7. CPUID                            -> vendor, family/model, features

  Step 2 has to come before step 4 because under EMM386 or a Windows DOS box
  the POPF in step 4 is virtualised and reads back as a 286 would. SMSW is
  not virtualised, so PE settles the question first.

  The FPU probe is guarded the same way. On a 386 or later, an ESC opcode
  traps to INT 07h when EM or TS is set in the machine status word - EM being
  exactly how a software emulator announces itself. Reading those two bits
  first tells us whether an FPU instruction is safe to execute at all, which
  is a stronger guarantee than catching the trap after the fact and needs no
  interrupt handler.

  {$asmcpu PENTIUM} relaxes only the *assembler*; -Cp80286 still governs
  every instruction the compiler generates. Nothing above a 286 is reached
  without a runtime check.
  ---------------------------------------------------------------------------- }

interface

uses attime, atharn;

{$I at.inc}
{$asmcpu PENTIUM}

type
  TCpuClass = (ccUnknown, cc8086, cc80186, cc80286, cc80386, cc80486,
               cc586, cc686);
  TFpuClass = (fcNone, fcEmulated, fc8087, fc287, fc387);

var
  CpuClass  : TCpuClass;
  CpuName   : String[24];    { '486DX2', 'Pentium MMX', 'Am5x86' ... }
  Vendor    : String[12];    { CPUID leaf 0, or '' when there is no CPUID }

  HasCpuid  : Boolean;
  CpuidMax  : LongWord;
  CpuFamily : Byte;
  CpuModel  : Byte;
  CpuStep   : Byte;
  FeatEdx   : LongWord;

  HasFpu    : Boolean;
  FpuClass  : TFpuClass;
  HasTsc    : Boolean;
  HasMmx    : Boolean;
  HasCmov   : Boolean;

  InV86     : Boolean;       { EMM386, QEMM, a Windows DOS box ... }
  EmuFpuBit : Boolean;       { MSW.EM - an FPU emulator is hooked in }

  CpuMhz    : Word;          { 0 until CpuMeasureMhz has run }
  MhzExact  : Boolean;       { True only when RDTSC did the measuring }

{ Safe on anything from an 8086 up. Does not need the timer. }
procedure CpuDetect;

{ Needs TimerInstall to have been called. Uses RDTSC where available and a
  calibrated LOOP otherwise, in which case the answer is an estimate and
  MhzExact stays False. }
procedure CpuMeasureMhz;

function CpuClassStr: String;
function FpuClassStr: String;

implementation

{ Cycles taken by one taken LOOP, per family. Used only when there is no
  RDTSC, which in practice means 486 and below. These are the published
  figures; real machines drift from them with wait states and cache misses,
  which is why the result is flagged as an estimate. }
const
  LoopCycles : array[TCpuClass] of Word =
    ( 8,     { ccUnknown - assume 286-ish }
      17,    { 8086 }
      8,     { 80186 }
      8,     { 80286 }
      11,    { 80386 }
      6,     { 80486 }
      5,     { 586 }
      5 );   { 686 }

var
  CpEax, CpEbx, CpEcx, CpEdx : LongWord;
  TscLo : LongWord;

{ ------------------------------------------------------------ the ladder }

{ 8086/8088 and 80186 leave FLAGS bits 12-15 set no matter what is written
  to them. Uses nothing newer than an 8086. }
function FlagsStuckHigh: Boolean; assembler;
asm
    pushf
    pop  ax
    mov  cx, ax
    and  ax, 0FFFh
    push ax
    popf
    pushf
    pop  ax
    push cx
    popf
    and  ax, 0F000h
    cmp  ax, 0F000h
    mov  ax, 0
    jne  @@done
    mov  ax, 1
  @@done:
end;

{ 8086 shifts as many times as it is told; everything from the 186 up masks
  the count to five bits. Only reached when FlagsStuckHigh said yes. }
function ShiftCountMasked: Boolean; assembler;
asm
    mov  al, 1
    mov  cl, 33
    shl  al, cl
    cmp  al, 0
    mov  ax, 0
    je   @@done          { shifted 33 times, result gone -> 8086 }
    mov  ax, 1
  @@done:
end;

{ Machine status word. 286 and up. Bit 0 PE, bit 1 MP, bit 2 EM, bit 3 TS. }
function Smsw: Word; assembler;
asm
    smsw ax
end;

{ On a 286 in real mode FLAGS bits 12-15 read back as zero however hard you
  push. On a 386 they take the value written. Do not trust this inside V86 -
  see the header. }
function Flags1215Settable: Boolean; assembler;
asm
    pushf
    pop  ax
    mov  cx, ax
    or   ax, 0F000h
    push ax
    popf
    pushf
    pop  ax
    push cx
    popf
    and  ax, 0F000h
    jz   @@no
    mov  ax, 1
    jmp  @@done
  @@no:
    mov  ax, 0
  @@done:
end;

{ EFLAGS bit 18, alignment check: 486 and later. 386 opcodes - only called
  once Flags1215Settable or the V86 check has proved we are on a 386+. }
function AcFlagTogglable: Boolean; assembler;
asm
    pushfd
    pop  eax
    mov  ecx, eax
    xor  eax, 40000h
    push eax
    popfd
    pushfd
    pop  eax
    push ecx
    popfd
    xor  eax, ecx
    and  eax, 40000h
    jz   @@no
    mov  ax, 1
    jmp  @@done
  @@no:
    mov  ax, 0
  @@done:
end;

{ EFLAGS bit 21: the CPU is telling us CPUID exists. }
function IdFlagTogglable: Boolean; assembler;
asm
    pushfd
    pop  eax
    mov  ecx, eax
    xor  eax, 200000h
    push eax
    popfd
    pushfd
    pop  eax
    push ecx
    popfd
    xor  eax, ecx
    and  eax, 200000h
    jz   @@no
    mov  ax, 1
    jmp  @@done
  @@no:
    mov  ax, 0
  @@done:
end;

procedure DoCpuid(Leaf: LongWord); assembler;
asm
    push bx
    push si
    push di
    mov  eax, Leaf
    xor  ecx, ecx
    cpuid
    mov  CpEax, eax
    mov  CpEbx, ebx
    mov  CpEcx, ecx
    mov  CpEdx, edx
    pop  di
    pop  si
    pop  bx
end;

{ ---------------------------------------------------------------- the FPU }

var
  FpuCw : Word;
  FpuSw : Word;

{ Only ever called with EM and TS known to be clear, so no ESC opcode here
  can trap. All FN forms: no FWAIT is emitted, which is what keeps this safe
  when MP is set on a machine with no coprocessor. }
function FpuPresent: Boolean;
begin
  FpuSw := $5A5A;
  FpuCw := $5A5A;
  asm
    fninit
    fnstsw FpuSw
  end;
  if (FpuSw and $FF) <> 0 then
  begin
    FpuPresent := False;
    Exit;
  end;
  asm
    fnstcw FpuCw
  end;
  { After FNINIT the control word is 037Fh on a 287 or later and 03FFh on an
    8087; either way the low six bits - the exception masks - are all set. }
  FpuPresent := (FpuCw and $103F) = $3F;
end;

{ 8087 and 287 work in projective mode, where +inf and -inf are the same
  value; the 387 introduced affine-only arithmetic where they differ. This is
  also exactly the line that decides whether FSIN exists. }
function FpuIsAffine: Boolean;
var
  R: Word;
begin
  R := 0;
  asm
    fninit
    fld1
    fldz
    fdiv                  { st = 1/0 = infinity, exceptions are masked }
    fld  st(0)
    fchs                  { st = -infinity, st(1) = +infinity }
    fcompp
    fnstsw R
    fninit                { leave the FPU clean }
  end;
  { C3 (bit 14) set means the two compared equal - projective, so 287 or
    older. C0/C2/C3 all set would mean unordered, which cannot happen here. }
  FpuIsAffine := (R and $4000) = 0;
end;

{ ------------------------------------------------------------------ naming }

procedure Add4(var S: String; V: LongWord);
var
  I: Integer;
  W: LongWord;
  C: Char;
begin
  W := V;
  for I := 1 to 4 do
  begin
    C := Chr(Byte(W and $FF));
    if C >= ' ' then
      S := S + C;
    W := W shr 8;
  end;
end;

function IntelName(F, M: Byte): String;
begin
  case F of
    4: case M of
         0, 1: IntelName := '486DX';
         2:    IntelName := '486SX';
         3:    IntelName := '486DX2';
         4:    IntelName := '486SL';
         5:    IntelName := '486SX2';
         7:    IntelName := '486DX2WB';
         8:    IntelName := '486DX4';
         9:    IntelName := '486DX4WB';
       else    IntelName := '486';
       end;
    5: case M of
         1:    IntelName := 'Pentium 60/66';
         2:    IntelName := 'Pentium';
         3:    IntelName := 'Pentium OverDrive';
         4:    IntelName := 'Pentium MMX';
         7:    IntelName := 'Pentium';
         8:    IntelName := 'Pentium MMX';
       else    IntelName := 'Pentium';
       end;
    6:         IntelName := 'Pentium Pro/II or later';
  else         IntelName := 'Intel';
  end;
end;

function AmdName(F, M: Byte): String;
begin
  case F of
    4: case M of
         3:    AmdName := 'Am486DX2';
         7:    AmdName := 'Am486DX2WB';
         8:    AmdName := 'Am486DX4';
         9:    AmdName := 'Am486DX4WB';
         14:   AmdName := 'Am5x86';
         15:   AmdName := 'Am5x86WB';
       else    AmdName := 'Am486';
       end;
    5: case M of
         0, 1, 2, 3: AmdName := 'K5';
         6, 7: AmdName := 'K6';
         8:    AmdName := 'K6-2';
         9:    AmdName := 'K6-III';
         13:   AmdName := 'K6-2+/III+';
       else    AmdName := 'K5/K6';
       end;
    6:         AmdName := 'Athlon or later';
  else         AmdName := 'AMD';
  end;
end;

function CyrixName(F, M: Byte): String;
begin
  case F of
    4: if M = 4 then CyrixName := 'MediaGX' else CyrixName := 'Cyrix 486';
    5: case M of
         2: CyrixName := '6x86';
         4: CyrixName := 'MediaGXm';
       else CyrixName := 'Cyrix 5x86';
       end;
    6:   CyrixName := '6x86MX/MII';
  else   CyrixName := 'Cyrix';
  end;
end;

function ClassFallbackName(C: TCpuClass): String;
begin
  case C of
    cc8086:  ClassFallbackName := '8086/8088';
    cc80186: ClassFallbackName := '80186';
    cc80286: ClassFallbackName := '80286';
    cc80386: ClassFallbackName := '80386';
    cc80486: ClassFallbackName := '80486';
    cc586:   ClassFallbackName := '586-class';
    cc686:   ClassFallbackName := '686-class';
  else       ClassFallbackName := 'unknown';
  end;
end;

function CpuClassStr: String;
begin
  CpuClassStr := ClassFallbackName(CpuClass);
end;

function FpuClassStr: String;
begin
  case FpuClass of
    fcNone:     FpuClassStr := 'none';
    fcEmulated: FpuClassStr := 'emulated (MSW.EM set)';
    fc8087:     FpuClassStr := '8087';
    fc287:      FpuClassStr := '287-class (projective)';
    fc387:      FpuClassStr := '387-class (affine, FSIN)';
  else          FpuClassStr := '?';
  end;
end;

{ ------------------------------------------------------------------ detect }

procedure CpuDetect;
var
  MSW  : Word;
  Sig  : LongWord;
  Fam  : Byte;
begin
  CpuClass  := ccUnknown;
  CpuName   := '';
  Vendor    := '';
  HasCpuid  := False;
  CpuidMax  := 0;
  CpuFamily := 0;
  CpuModel  := 0;
  CpuStep   := 0;
  FeatEdx   := 0;
  HasFpu    := False;
  FpuClass  := fcNone;
  HasTsc    := False;
  HasMmx    := False;
  HasCmov   := False;
  InV86     := False;
  EmuFpuBit := False;
  CpuMhz    := 0;
  MhzExact  := False;

  { --- rung 1: is this even a 286? --- }
  if FlagsStuckHigh then
  begin
    if ShiftCountMasked then
      CpuClass := cc80186
    else
      CpuClass := cc8086;
    CpuName := ClassFallbackName(CpuClass);
    Exit;                { no SMSW, no MSW, nothing further is safe }
  end;

  { --- rung 2: the machine status word --- }
  MSW       := Smsw;
  InV86     := (MSW and $01) <> 0;
  EmuFpuBit := (MSW and $04) <> 0;

  { --- rungs 3 and 4: 286 or 386+ --- }
  if InV86 or Flags1215Settable then
    CpuClass := cc80386
  else
    CpuClass := cc80286;

  if CpuClass >= cc80386 then
  begin
    { --- rung 5 --- }
    if AcFlagTogglable then
      CpuClass := cc80486;

    { --- rung 6 and 7 --- }
    if (CpuClass >= cc80486) and IdFlagTogglable then
    begin
      HasCpuid := True;
      DoCpuid(0);
      CpuidMax := CpEax;
      Add4(Vendor, CpEbx);
      Add4(Vendor, CpEdx);
      Add4(Vendor, CpEcx);

      if CpuidMax >= 1 then
      begin
        DoCpuid(1);
        Sig       := CpEax;
        FeatEdx   := CpEdx;
        CpuStep   := Byte(Sig and $0F);
        CpuModel  := Byte((Sig shr 4) and $0F);
        Fam       := Byte((Sig shr 8) and $0F);
        CpuFamily := Fam;
        case Fam of
          4: CpuClass := cc80486;
          5: CpuClass := cc586;
        else
          if Fam >= 6 then CpuClass := cc686;
        end;
        HasTsc  := (FeatEdx and $00000010) <> 0;
        HasCmov := (FeatEdx and $00008000) <> 0;
        HasMmx  := (FeatEdx and $00800000) <> 0;
      end;
    end;
  end;

  { --- name --- }
  if HasCpuid and (CpuidMax >= 1) then
  begin
    if Vendor = 'GenuineIntel' then
      CpuName := IntelName(CpuFamily, CpuModel)
    else if Vendor = 'AuthenticAMD' then
      CpuName := AmdName(CpuFamily, CpuModel)
    else if (Vendor = 'CyrixInstead') or (Vendor = 'Geode by NSC') then
      CpuName := CyrixName(CpuFamily, CpuModel)
    else
      CpuName := ClassFallbackName(CpuClass);
  end
  else
    CpuName := ClassFallbackName(CpuClass);

  { --- the FPU, last, and only when the status word says it is safe --- }
  if EmuFpuBit then
  begin
    FpuClass := fcEmulated;
    HasFpu   := False;
  end
  else if (MSW and $08) <> 0 then    { TS set - an ESC would trap }
  begin
    FpuClass := fcNone;
    HasFpu   := False;
  end
  else if FpuPresent then
  begin
    HasFpu := True;
    if CpuClass <= cc8086 then
      FpuClass := fc8087
    else if FpuIsAffine then
      FpuClass := fc387
    else
      FpuClass := fc287;
  end;

  { CPUID's own FPU bit is the authority when we have it. A 486SX reports
    zero here and no coprocessor above, which agree; a 487SX or a DX reports
    one. Disagreement is worth knowing about, so trust CPUID and let the
    probe stand as the reason. }
  if HasCpuid and (CpuidMax >= 1) then
    HasFpu := (FeatEdx and $00000001) <> 0;
end;

{ -------------------------------------------------------------------- MHz }

procedure ReadTsc; assembler;
asm
    push bx
    rdtsc
    mov  TscLo, eax
    pop  bx
end;

{ One unit is one taken LOOP. }
procedure KernLoop(Units: Word); assembler;
asm
    mov  cx, Units
    jcxz @@done
  @@spin:
    loop @@spin
  @@done:
end;

procedure CpuMeasureMhz;
var
  T0, T1 : TStamp;
  A, B   : LongWord;
  Us     : LongWord;
  R      : TBenchResult;
  Cyc    : LongWord;
begin
  CpuMhz   := 0;
  MhzExact := False;
  { A clock that is installed but not ticking cannot time anything, and the
    sampling window below would wait for a hundred milliseconds that never
    pass. Leaving the speed unknown is the right answer there, and the caller
    reports the dead clock. }
  if (not TimerOn) or (not TimerIrqOk) then Exit;

  if HasTsc then
  begin
    T0 := Stamp;
    ReadTsc;
    A := TscLo;
    if not StampWait(100 * LongWord(TicksPerMs)) then Exit;
    T1 := Stamp;
    ReadTsc;
    B := TscLo;
    Us := StampUs(StampDiff(T0, T1));
    if Us > 0 then
    begin
      { cycles per microsecond is megahertz, near enough }
      CpuMhz   := Word((B - A + (Us div 2)) div Us);
      MhzExact := True;
    end;
    Exit;
  end;

  { No RDTSC: time a loop whose cost in cycles we think we know. }
  R := RunBench(@KernLoop);
  if not R.Ok then Exit;
  Cyc := LoopCycles[CpuClass];
  CpuMhz   := Word((LongWord(R.Rate) * Cyc + 500000) div 1000000);
  MhzExact := False;
end;

begin
  CpuClass := ccUnknown;
  CpuName  := '';
end.
