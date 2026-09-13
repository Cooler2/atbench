unit atsys;
{ ----------------------------------------------------------------------------
  ATBench - everything about the machine that is not the CPU.

  Two jobs. It fills in the header of every report, because a bandwidth
  figure means nothing without knowing what it was measured on; and it warns
  about the things that quietly poison measurements - a memory manager
  putting us in V86, a disk cache turning the disk test into a memory test.

  All of this is done through documented BIOS and DOS calls, and every one of
  them is treated as optional: a machine that does not answer simply leaves
  the field blank. Nothing here is allowed to be the reason the benchmark
  fails to start.
  ---------------------------------------------------------------------------- }

interface

uses dos, atdbg, atmemx;

{$I at.inc}

var
  DosMajor, DosMinor : Byte;
  DosTrueMaj, DosTrueMin : Byte;   { 0 when DOS is too old to be asked }

  ConvKb     : Word;               { as the BIOS reports it }
  FreeDosKb  : Word;               { largest block DOS would give us now }

  XmsOk      : Boolean;
  XmsVer     : Word;               { BCD, e.g. 0300h }
  XmsFreeKb  : Word;
  XmsLargeKb : Word;

  EmsOk      : Boolean;
  EmsVer     : Word;               { BCD }
  EmsFreeKb  : Word;

  VideoKind  : String[20];
  VideoBios  : String[40];

  VbeOk      : Boolean;
  VbeVer     : Word;               { 0102h = VBE 1.2, 0200h = 2.0 }
  VbeMemKb   : Word;
  VbeOem     : String[40];

  Floppies   : Byte;
  HardDisks  : Byte;

  SmartDrv   : Boolean;            { a resident disk cache was found }
  DiskCache  : String[8];          { and this is what it calls itself }
  MachineId  : Byte;               { F000:FFFE - FCh AT, F8h PS/2 ... }

{ Skips the detections that hand control to somebody else's code - the XMS
  driver, the EMS driver, the VESA BIOS. Any of them can take a machine down
  with it, and losing three lines of the system report is a far better outcome
  than losing the run. The disk cache is not among them any more: it is found
  by reading memory, which nothing can hang. }
var SafeProbe: Boolean;

procedure SysDetect;

{ The CRC32 of the file this program was loaded from, and its length - the
  answer to 'is this report from the build I think it is'. A date would answer
  it nearly as well until the day somebody rebuilds without changing anything,
  or changes something without rebuilding; a checksum of the bytes that ran
  answers it exactly, and two machines can be compared on it without either of
  them knowing when the other was built.

  Read on demand and then remembered, because the only caller is the report
  and the file may be on the floppy the machine booted from - a hundred and
  fifty kilobytes off a 1.44M disk is several seconds, and a run whose report
  is never written should not pay them. Zero means it could not be read, which
  is not worth stopping for: DOS 2.x has no name to give us in the first
  place, and a program run off a disk that has since been swapped is a fair
  thing to be quiet about. }
function SysExeCrc: LongInt;
function SysExeSize: LongInt;

function DosVerStr: String;
function BcdVerStr(V: Word): String;
function MachineIdStr: String;

implementation

{ -------------------------------------------------------------------- misc }

function W2S(W: LongWord): String;
var
  S: String;
begin
  Str(W, S);
  W2S := S;
end;

function BcdVerStr(V: Word): String;
begin
  BcdVerStr := W2S(V shr 8) + '.' + W2S(V and $FF);
end;

function DosVerStr: String;
var
  S: String;
begin
  S := W2S(DosMajor) + '.';
  if DosMinor < 10 then S := S + '0';
  S := S + W2S(DosMinor);
  if (DosTrueMaj <> 0) and
     ((DosTrueMaj <> DosMajor) or (DosTrueMin <> DosMinor)) then
    S := S + ' (reported; really ' + W2S(DosTrueMaj) + '.' +
         W2S(DosTrueMin) + ')';
  DosVerStr := S;
end;

function MachineIdStr: String;
begin
  case MachineId of
    $FF: MachineIdStr := 'PC';
    $FE: MachineIdStr := 'PC/XT';
    $FD: MachineIdStr := 'PCjr';
    $FC: MachineIdStr := 'PC/AT or clone';
    $FB: MachineIdStr := 'XT (1986)';
    $FA: MachineIdStr := 'PS/2 Model 30';
    $F9: MachineIdStr := 'PC Convertible';
    $F8: MachineIdStr := 'PS/2 Model 80';
  else
    MachineIdStr := 'unknown';
  end;
end;

{ --------------------------------------------------------------- DOS + RAM }

procedure GetDos;
var
  A, B: Word;
begin
  asm
    mov  ah, 30h
    int  21h
    mov  A, ax
  end;
  DosMajor := Byte(A and $FF);
  DosMinor := Byte(A shr 8);

  DosTrueMaj := 0;
  DosTrueMin := 0;
  if DosMajor >= 5 then
  begin
    B := 0;
    asm
      mov  ax, 3306h
      int  21h
      jc   @@no
      mov  B, bx
    @@no:
    end;
    if B <> 0 then
    begin
      DosTrueMaj := Byte(B and $FF);
      DosTrueMin := Byte(B shr 8);
    end;
  end;
end;

procedure GetConv;
var
  K, P: Word;
begin
  asm
    int  12h
    mov  K, ax
  end;
  ConvKb := K;

  { Asking for 0FFFFh paragraphs always fails, and the failure carries the
    size of the largest block there is - so this measures free memory
    without ever taking any. }
  asm
    mov  ah, 48h
    mov  bx, 0FFFFh
    int  21h
    mov  P, bx
  end;
  FreeDosKb := P div 64;
{$if defined(FPC_MM_COMPACT) or defined(FPC_MM_LARGE) or defined(FPC_MM_HUGE)}
  { In a far-data model DOS has almost nothing left to report, because the
    start-up code handed every byte above our stack to the RTL heap on
    purpose (see atmemx). What DOS still owns is then a true but useless
    number - it says nothing about the machine and everything about which
    memory model this binary was linked in. The free memory a reader of the
    report means is what a program could use here, so the heap's share is
    added back. Taken at detection time, before any benchmark has allocated
    anything, which is the only moment it means "free". }
  Inc(FreeDosKb, Word(FarMaxAvail div 1024));
{$endif}
end;

{ -------------------------------------------------------------------- XMS }

var
  XmsEntry : FarPointer;
  XAx, XBx, XDx : Word;

procedure XmsInvoke(Fn: Byte); assembler;
asm
    push si
    push di
    push bp
    mov  ah, Fn
    call far [XmsEntry]
    pop  bp
    mov  XAx, ax
    mov  XBx, bx
    mov  XDx, dx
    pop  di
    pop  si
end;

procedure GetXms;
var
  Present : Byte;
  Sg, Of_ : Word;
begin
  XmsOk := False;
  XmsVer := 0; XmsFreeKb := 0; XmsLargeKb := 0;

  Present := 0;
  asm
    push si
    push di
    mov  ax, 4300h
    int  2Fh
    cmp  al, 80h
    jne  @@no
    mov  Present, 1
  @@no:
    pop  di
    pop  si
  end;
  if Present = 0 then Exit;
  Dbg('sys: XMS present, asking for entry point');

  asm
    push si
    push di
    mov  ax, 4310h
    int  2Fh
    mov  Sg, es
    mov  Of_, bx
    pop  di
    pop  si
  end;
  if (Sg = 0) and (Of_ = 0) then Exit;

  XmsEntry := Ptr(Sg, Of_);
  XmsOk := True;

  Dbg('sys: XMS call version');
  XmsInvoke($00);          { get version: AX = XMS version, BCD }
  XmsVer := XAx;

  Dbg('sys: XMS call free');
  XmsInvoke($08);          { query free extended memory }
  XmsLargeKb := XAx;       { largest free block, KB }
  XmsFreeKb  := XDx;       { total free, KB }
end;

{ -------------------------------------------------------------------- EMS }

function EmsSignature: Boolean;
var
  Sg : Word;
  I  : Word;
  Ok : Boolean;
const
  Sig : array[0..7] of Char = 'EMMXXXX0';
begin
  EmsSignature := False;
  Sg := MemW[$0000:$67*4 + 2];
  if Sg = 0 then Exit;
  Ok := True;
  for I := 0 to 7 do
    if Mem[Sg:$0A + I] <> Byte(Sig[I]) then
    begin
      Ok := False;
      Break;
    end;
  EmsSignature := Ok;
end;

procedure GetEms;
var
  V, Free_: Word;
begin
  EmsOk := False;
  EmsVer := 0;
  EmsFreeKb := 0;
  if not EmsSignature then Exit;
  Dbg('sys: EMS signature found, INT 67h AH=46h');

  V := 0;
  asm
    push si
    push di
    mov  ah, 46h
    int  67h
    or   ah, ah
    jnz  @@bad
    xor  ah, ah
    mov  V, ax
  @@bad:
    pop  di
    pop  si
  end;
  if V = 0 then Exit;

  EmsOk := True;
  Dbg('sys: EMS version ok, INT 67h AH=42h');
  { AH=46h returns the version in BCD in AL: 32h means 3.2. }
  EmsVer := Word(((V shr 4) and $0F) shl 8) or Word(V and $0F);

  Free_ := 0;
  asm
    push si
    push di
    mov  ah, 42h
    int  67h
    or   ah, ah
    jnz  @@bad
    mov  Free_, bx
  @@bad:
    pop  di
    pop  si
  end;
  EmsFreeKb := Free_ * 16;      { EMS pages are 16 KB }
end;

{ ------------------------------------------------------------------ video }

procedure GetVideoKind;
var
  R, B: Byte;
begin
  R := 0; B := 0;
  asm
    push si
    push di
    mov  ax, 1A00h
    int  10h
    mov  R, al
    mov  B, bl
    pop  di
    pop  si
  end;
  if R = $1A then
  begin
    case B of
      0:      VideoKind := 'none';
      1:      VideoKind := 'MDA';
      2:      VideoKind := 'CGA';
      4:      VideoKind := 'EGA colour';
      5:      VideoKind := 'EGA mono';
      7:      VideoKind := 'VGA mono';
      8:      VideoKind := 'VGA colour';
      $0A,
      $0C:    VideoKind := 'PGA/MCGA colour';
      $0B:    VideoKind := 'MCGA mono';
    else      VideoKind := 'code ' + W2S(B);
    end;
    Exit;
  end;

  { No VGA BIOS. Ask the EGA BIOS instead: function 12h/10h rewrites BL only
    when an EGA is answering. }
  B := $10;
  asm
    push si
    push di
    mov  ah, 12h
    mov  bl, 10h
    int  10h
    mov  B, bl
    pop  di
    pop  si
  end;
  if B <> $10 then
  begin
    VideoKind := 'EGA';
    Exit;
  end;

  { Fall back on the equipment word: bits 4-5 give the initial video mode. }
  case (MemW[$0040:$0010] shr 4) and 3 of
    1, 2: VideoKind := 'CGA';
    3:    VideoKind := 'MDA/Hercules';
  else    VideoKind := 'unknown';
  end;
end;

{ Video BIOSes have no standard place for their name, so this has to be a
  search. Two places are worth looking, in this order.

  The copyright notice is the string that actually names the chipset, and
  every ROM carries one - but not always early. Scanning half the window
  found nothing on the first real card this ever ran against (an S3
  Trio64V2, whose notice sits past the 32 KB mark), so the scan now runs to
  the ROM's own declared length: offset 2 of an option-ROM header is the
  size in 512-byte blocks.

  Failing that, fall back to where the older VGATEST looked - the first few
  hundred bytes. Cards put a plain manufacturer string right behind the
  three-byte header, and that tool simply harvested every printable byte
  from offset 0 and showed the lot. Harvesting is far too loose to use as
  the main path: the longest printable run in a SeaBIOS ROM is a stretch of
  66h-prefixed opcodes decoding to 'fXf[f^f_f]', and the first run that
  merely looks like prose is its internal error message. Bounded to the
  header area, and required to be long enough and to contain letters, the
  same idea is sound - that region is a name or it is nothing.

  A ROM with neither leaves the field empty, which is honest - and the VESA
  OEM string names the card too. }
function RomHasAt(Ofs: Word; const Pat: String): Boolean;
var
  I: Integer;
begin
  RomHasAt := False;
  for I := 1 to Length(Pat) do
    if Mem[$C000:Ofs + Word(I) - 1] <> Byte(Pat[I]) then Exit;
  RomHasAt := True;
end;

{ How far the ROM says it extends, capped a little short of the full 64 KB
  window so a Word offset plus the pattern length cannot wrap past its end. }
function RomScanLen: Word;
var
  Blocks : Byte;
  L      : LongWord;
begin
  Blocks := Mem[$C000:$0002];
  if Blocks = 0 then
    RomScanLen := 32768
  else
  begin
    L := LongWord(Blocks) * 512;
    if L > 65024 then L := 65024;
    RomScanLen := Word(L);
  end;
end;

{ Longest printable run in [First, Last), provided it is at least MinRun long
  and contains a letter. A row of punctuation or a table of digits is not a
  name, and refusing them is what keeps this usable as a fallback. }
function RomBestRun(First, Last: Word): String;
const
  MinRun = 8;
var
  I, RunStart, BestStart, BestLen : Word;
  Alpha : Boolean;
  B     : Byte;
  S     : String;
begin
  BestStart := 0;
  BestLen   := 0;
  RunStart  := First;
  Alpha     := False;
  I         := First;
  while I <= Last do
  begin
    B := 0;
    if I < Last then B := Mem[$C000:I];
    if (I < Last) and (B >= 32) and (B < 127) then
    begin
      if ((B >= 65) and (B <= 90)) or ((B >= 97) and (B <= 122)) then
        Alpha := True;
    end
    else
    begin
      if Alpha and (I - RunStart >= MinRun) and (I - RunStart > BestLen) then
      begin
        BestStart := RunStart;
        BestLen   := I - RunStart;
      end;
      RunStart := I + 1;
      Alpha    := False;
    end;
    Inc(I);
  end;

  S := '';
  if BestLen > 0 then
  begin
    if BestLen > 40 then BestLen := 40;
    for I := BestStart to BestStart + BestLen - 1 do
      S := S + Chr(Mem[$C000:I]);
    while (Length(S) > 0) and (S[Length(S)] = ' ') do
      Dec(S[0]);
    while (Length(S) > 0) and (S[1] = ' ') do
      Delete(S, 1, 1);
  end;
  RomBestRun := S;
end;

procedure GetVideoBios;
const
  MaxBack = 48;
var
  I, Scan, Start, Stop, J : Word;
  Hit : Boolean;
  B   : Byte;
  S   : String;
begin
  VideoBios := '';
  if MemW[$C000:$0000] <> $AA55 then Exit;

  Scan := RomScanLen;

  Hit := False;
  I := 4;
  while I < Scan - 8 do
  begin
    if RomHasAt(I, '(C)') or RomHasAt(I, 'opyright') then
    begin
      Hit := True;
      Break;
    end;
    Inc(I);
  end;
  if not Hit then
  begin
    VideoBios := RomBestRun(4, 512);
    Exit;
  end;

  { Expand to the printable run holding it, bounded so a ROM full of
    printable filler cannot run away with us. }
  Start := I;
  while (Start > 0) and (I - Start < MaxBack) do
  begin
    B := Mem[$C000:Start - 1];
    if (B < 32) or (B >= 127) then Break;
    Dec(Start);
  end;

  Stop := I;
  while (Stop < Scan) and (Stop - Start < 60) do
  begin
    B := Mem[$C000:Stop];
    if (B < 32) or (B >= 127) then Break;
    Inc(Stop);
  end;

  S := '';
  for J := Start to Stop - 1 do
  begin
    if Length(S) >= 40 then Break;
    S := S + Chr(Mem[$C000:J]);
  end;
  while (Length(S) > 0) and (S[Length(S)] = ' ') do
    Dec(S[0]);
  while (Length(S) > 0) and (S[1] = ' ') do
    Delete(S, 1, 1);
  VideoBios := S;
end;

{ ------------------------------------------------------------------- VESA }

type
  TVbeBlock = array[0..511] of Byte;

var
  VbeBuf : TVbeBlock;

procedure GetVbe;
var
  Ok   : Byte;
  P    : Word;
  Sg, Of_ : Word;
  I    : Word;
  B    : Byte;
begin
  VbeOk := False;
  VbeVer := 0;
  VbeMemKb := 0;
  VbeOem := '';

  FillChar(VbeBuf, SizeOf(VbeBuf), 0);
  { Asking as 'VBE2' makes a 2.0 BIOS fill in the extra fields; a 1.x BIOS
    ignores it and fills in the first 256 bytes as usual. }
  VbeBuf[0] := Byte('V'); VbeBuf[1] := Byte('B');
  VbeBuf[2] := Byte('E'); VbeBuf[3] := Byte('2');

  Ok := 0;
  asm
    push si
    push di
    push es
    mov  ax, ds
    mov  es, ax
    lea  di, VbeBuf
    mov  ax, 4F00h
    int  10h
    cmp  ax, 004Fh
    jne  @@no
    mov  Ok, 1
  @@no:
    pop  es
    pop  di
    pop  si
  end;
  if Ok = 0 then Exit;

  if (VbeBuf[0] <> Byte('V')) or (VbeBuf[1] <> Byte('E')) or
     (VbeBuf[2] <> Byte('S')) or (VbeBuf[3] <> Byte('A')) then Exit;

  VbeOk := True;
  VbeVer := VbeBuf[4] or (Word(VbeBuf[5]) shl 8);
  P := VbeBuf[18] or (Word(VbeBuf[19]) shl 8);
  VbeMemKb := P * 64;

  Of_ := VbeBuf[6] or (Word(VbeBuf[7]) shl 8);
  Sg  := VbeBuf[8] or (Word(VbeBuf[9]) shl 8);
  if (Sg = 0) and (Of_ = 0) then Exit;
  for I := 0 to 39 do
  begin
    B := Mem[Sg:Of_ + I];
    if (B < 32) or (B >= 127) then Break;
    VbeOem := VbeOem + Chr(B);
  end;
end;

{ ------------------------------------------------------------ disks, cache }

procedure GetDisks;
var
  Eq: Word;
begin
  Eq := MemW[$0040:$0010];
  if (Eq and 1) = 0 then
    Floppies := 0
  else
    Floppies := Byte((Eq shr 6) and 3) + 1;
  HardDisks := Mem[$0040:$0075];
end;

{ SMARTDRV's own installation check is INT 2Fh AX=4A10h, and on at least one
  machine here that call never comes back. It cannot be made safe: the 4Axx
  multiplex is Microsoft-reserved with more than one claimant, and there is no
  way to ask whether INT 2Fh has a handler at all, let alone whether it
  returns. Two warning lines are not worth a hung benchmark.

  So the cache is looked for instead of asked about. DOS 4 and later write the
  owning program's name into every memory control block, and walking that
  chain is nothing but reads of memory that is already there - no resident
  code executes. It also answers a better question: the multiplex could only
  ever say yes or no about SMARTDRV, while the chain names whichever cache is
  actually loaded. }
const
  KnownCaches = 6;
  CacheName : array[1..KnownCaches] of String[8] =
    ('SMARTDRV', 'NWCACHE', 'HYPERDSK', 'PC-CACHE', 'QCACHE', 'SUPERPCK');

procedure GetDiskCache;
var
  Sg, Owner, Para : Word;
  Kind, B         : Byte;
  Nm              : String;
  I, J            : Integer;
begin
  SmartDrv := False;
  DiskCache := '';

  { The first MCB's segment lives in the word immediately before the list of
    lists, which AH=52h hands back in ES:BX. }
  Sg := 0;
  asm
    push bx
    push es
    mov  ah, 52h
    int  21h
    mov  ax, es:[bx-2]
    mov  Sg, ax
    pop  es
    pop  bx
  end;
  if (Sg = 0) or (Sg = $FFFF) then Exit;

  { The bound is not decoration: a broken chain would otherwise walk memory
    forever, and this runs on machines whose memory managers we did not
    write. }
  for I := 1 to 256 do
  begin
    Kind := Mem[Sg:0];
    if (Kind <> Byte('M')) and (Kind <> Byte('Z')) then Exit;
    Owner := MemW[Sg:1];
    Para  := MemW[Sg:3];

    { Owner 0 is a free block, and its name field holds whatever the previous
      tenant left behind. }
    if Owner <> 0 then
    begin
      Nm := '';
      for J := 0 to 7 do
      begin
        B := Mem[Sg:8 + J];
        if (B = 0) or (B = 32) then Break;
        if (B < 32) or (B > 126) then
        begin
          Nm := '';
          Break;
        end;
        if (B >= Byte('a')) and (B <= Byte('z')) then Dec(B, 32);
        Nm := Nm + Chr(B);
      end;
      { Under /trace the walk lists what it saw. Without this, a chain that
        broke on the first block and a machine with no cache loaded produce
        exactly the same silence. }
      if Nm <> '' then Dbg('sys: mcb ' + Nm);
      if Nm <> '' then
        for J := 1 to KnownCaches do
          if Nm = CacheName[J] then
          begin
            SmartDrv := True;
            DiskCache := Nm;
            Exit;
          end;
    end;

    if Kind = Byte('Z') then Exit;
    Sg := Sg + Para + 1;
  end;
end;

{ ------------------------------------------------------------------ detect }

{ Every step is announced before it runs, so that a machine which does not
  survive one of them says which. Several of these talk to whatever memory
  manager is loaded - the XMS entry point is a far call into a driver, and EMS
  is an INT 67h into another - and that is precisely the neighbourhood where a
  V86 monitor stops the computer instead of returning an error. }
{ ------------------------------------------------------------------ the exe }

var
  ExeCrc  : LongInt;
  ExeSize : LongInt;
  ExeRead : Boolean;

{ The name is printed because the interesting failure is the one where it is
  not a name at all. ParamStr(0) returns the copy the RTL made on the heap at
  start-up, so a path full of rubbish means something in this program handed
  out heap memory twice - a fault inside, while a real path DOS cannot open is
  a fault outside. Control characters are what tells the two apart, so they
  have to reach the trace as something a text file can hold. }
function Printable(const S: String): String;
var
  I : Integer;
  R : String;
begin
  R := S;
  for I := 1 to Length(R) do
    if (R[I] < ' ') or (R[I] > #126) then R[I] := '?';
  Printable := R;
end;

procedure ReadExe;
var
  F   : File;
  Buf : array[0..511] of Byte;
  Got : Word;
  E   : Integer;
begin
  ExeRead := True;
  ExeCrc  := 0;
  ExeSize := 0;
  { Three ways to come away without a checksum, and from the report line
    alone - 'CRC unavailable' - they look identical. Under /trace they do
    not, which is the difference between a DOS that will not name the
    program and a suite that ran the file handles out. }
  if ParamStr(0) = '' then
  begin
    Dbg('exe: no ParamStr(0)');
    Exit;
  end;
  Assign(F, ParamStr(0));
  Reset(F, 1);
  E := IOResult;
  if E <> 0 then
  begin
    Dbg('exe: open failed, ioresult ' + W2S(E) + ', name ' + Printable(ParamStr(0)));
    Exit;
  end;
  CrcOpen;
  repeat
    BlockRead(F, Buf, SizeOf(Buf), Got);
    E := IOResult;
    if E <> 0 then
    begin
      Dbg('exe: read failed, ioresult ' + W2S(E));
      Close(F);
      if IOResult <> 0 then ;
      ExeSize := 0;
      Exit;
    end;
    if Got > 0 then
    begin
      CrcFeed(Buf, Got);
      Inc(ExeSize, Got);
    end;
  until Got = 0;
  { The close can fail on a disk that was swapped under us; the bytes were
    still read and checksummed, so the result stands. }
  Close(F);
  if IOResult <> 0 then ;
  ExeCrc := CrcClose;
end;

function SysExeCrc: LongInt;
begin
  if not ExeRead then ReadExe;
  SysExeCrc := ExeCrc;
end;

function SysExeSize: LongInt;
begin
  if not ExeRead then ReadExe;
  SysExeSize := ExeSize;
end;

procedure SysDetect;
begin
  Dbg('sys: GetDos');
  GetDos;
  Dbg('sys: GetConv');
  GetConv;
  if SafeProbe then Dbg('sys: XMS/EMS/VBE skipped (/safe)')
  else
  begin
    Dbg('sys: GetXms');
    GetXms;
    Dbg('sys: GetEms');
    GetEms;
  end;
  Dbg('sys: GetVideoKind');
  GetVideoKind;
  Dbg('sys: GetVideoBios');
  GetVideoBios;
  if not SafeProbe then
  begin
    Dbg('sys: GetVbe');
    GetVbe;
  end;
  Dbg('sys: GetDisks');
  GetDisks;
  { Not guarded by /safe: this one only reads memory. }
  Dbg('sys: GetDiskCache');
  GetDiskCache;
  Dbg('sys: MachineId');
  MachineId := Mem[$F000:$FFFE];
  Dbg('sys: done');
end;

begin
  VideoKind := '';
  VideoBios := '';
  VbeOem    := '';
  DiskCache := '';
  SafeProbe := False;
end.
