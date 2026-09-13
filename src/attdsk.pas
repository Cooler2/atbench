unit attdsk;
{ ----------------------------------------------------------------------------
  ATBench - the disk tests.

  Everything here goes through the DOS file handle calls, not through BIOS
  INT 13h. That is deliberate: what a user of the machine actually experiences
  is the whole stack - FAT, DOS, whatever cache is loaded, then the drive - and
  on the hardware of this era the DOS call overhead is often the larger half of
  it. INT 13h would measure a controller; INT 21h measures a computer.

  Nothing here uses ATHARN. The harness works by running a kernel over and over
  and keeping the fastest pass, which is exactly wrong for a disk: the second
  pass reads from a cache, and a hundred passes over a floppy would take the
  afternoon. Each phase instead runs once, under a time budget, and reports the
  rate for the work it actually managed - so a slow drive returns a smaller
  file and an honest number rather than a hang.

  The time budget is also the safety net. Between blocks the phase checks the
  clock and ESC, so no disk test can run away, and a drive that stops answering
  costs the budget rather than the session.

  Two hazards get explicit handling:

    * "Abort, Retry, Fail" - an empty or write-protected drive would otherwise
      stop the program dead inside DOS, with no way back for a headless run.
      An INT 24h handler returning FAIL is installed for the duration.
    * the leftover temp file - removed by the normal path, and again from an
      ExitProc so that a crash mid-test does not leave megabytes behind.
  ---------------------------------------------------------------------------- }

interface

uses attime, atharn, atmemx;

{$I at.inc}

type
  TDskTest = record
    Id     : String[8];
    Title  : String[30];
    Metric : String[9];      { 'MB/s', 'IOPS' or 'ms' }
  end;

  TDskTestRes = record
    Ran     : Boolean;
    Skipped : Boolean;
    Why     : String[28];
    Value   : LongWord;      { the metric in millionths, as everywhere else }
  end;

const
  DskTestN  = 13;
  DskPhaseN = 8;

var
  DskTests   : array[0..DskTestN - 1] of TDskTest;
  DskTestRes : array[0..DskTestN - 1] of TDskTestRes;

  { --- what the caller sets before running ------------------------------- }
  DskDrive       : Byte;      { 0 = whatever DOS considers current, 1 = A: }
  DskAllowFloppy : Boolean;   { floppies are only touched on explicit consent }

  { --- what the probe and the run report back ---------------------------- }
  DskReady      : Boolean;
  DskRun        : Boolean;    { the suite got as far as running; stays set
                                after DskTestsDone so the report knows to
                                print a disk section at all }
  DskLetter     : Char;
  DskIsFloppy   : Boolean;
  DskFreeBytes  : LongInt;
  DskFileBytes  : LongInt;    { size the sequential file actually reached }
  DskCacheDoubt : Boolean;    { file too small to be sure the cache was beaten }
  DskWhy        : String[40]; { why the suite could not run }

{ Checks the drive and fills DskLetter/DskIsFloppy/DskFreeBytes. False, with
  DskWhy set, when the drive is unusable or is a floppy without consent. }
function  DskProbe: Boolean;

function  DskTestsInit: Boolean;
procedure DskTestsDone;

function  DskPhaseTitle(P: Integer): String;
procedure DskRunPhase(P: Integer);

{ Empty when the data written came back byte for byte. Run after the
  sequential phases, while the file is still there. }
function  DskSelfCheck: String;

implementation

uses dos;

const
  BufBytes    = 32768;        { largest block in the sweep }
  MaxSeq      = LongInt(8) * 1024 * 1024;
  MinSeq      = LongInt(2) * 1024 * 1024;   { below this the cache may not be
                                              beaten; noted in the report }
  SeqFloor    = 65536;        { never bother with less than this }
  FreeMargin  = 65536;        { leave DOS room to write the report afterwards }

  SeqBudgetMs   = 20000;
  SweepBudgetMs = 5000;
  RandBudgetMs  = 2000;
  CacheWant     = 65536;

  MaxRandOps    = 4000;

  { --- test indices --- }
  tSeqW  = 0;  tSeqR  = 1;
  tCache = 2;
  tIop5  = 3;  tAcc5  = 4;
  tIop4K = 5;  tAcc4K = 6;
  tWr512 = 7;  tRd512 = 8;
  tWr2K  = 9;  tRd2K  = 10;
  tWr8K  = 11; tRd8K  = 12;

var
  WrBuf, RdBuf : TFarBuf;
  WrSeg, RdSeg : Word;

  { Every write comes from offset 0 of WrBuf, so a file written in 512-byte
    blocks holds the first 512 bytes of the buffer over and over. The
    self-check has to know how long that repeating unit is. }
  LastBlock    : Word;
  LastFileSize : LongInt;

  PathZ        : array[0..15] of Char;
  DskError     : Word;
  FileMade     : Boolean;
  Int24Saved   : Boolean;
  OldInt24     : FarPointer;
  PrevExit     : FarPointer;
  Rnd          : LongWord;

{ ------------------------------------------------------- DOS, without the RTL }

{ The RTL's file routines would do their own buffering in DGROUP, which is
  precisely what a disk benchmark must not have between itself and DOS.

  Every call below brackets INT 21h with SI/DI/BP saves. DOS is documented to
  preserve them and normally does, but "normally" is not a property one wants
  to depend on across every DOS version this program is meant to run under,
  and the cost against a disk access is nothing. }

function DosCreate(var Handle: Word): Boolean;
var H, E: Word;
begin
  H := 0; E := 0;
  asm
    mov ah, 3Ch
    xor cx, cx
    mov dx, offset PathZ
    push si
    push di
    push bp
    int 21h
    pop bp
    pop di
    pop si
    jnc @@ok
    mov E, ax
    jmp @@done
  @@ok:
    mov H, ax
  @@done:
  end;
  Handle := H;
  DskError := E;
  DosCreate := E = 0;
end;

function DosOpen(var Handle: Word): Boolean;
var H, E: Word;
begin
  H := 0; E := 0;
  asm
    mov ax, 3D00h
    mov dx, offset PathZ
    push si
    push di
    push bp
    int 21h
    pop bp
    pop di
    pop si
    jnc @@ok
    mov E, ax
    jmp @@done
  @@ok:
    mov H, ax
  @@done:
  end;
  Handle := H;
  DskError := E;
  DosOpen := E = 0;
end;

procedure DosClose(Handle: Word);
begin
  asm
    mov ah, 3Eh
    mov bx, Handle
    push si
    push di
    push bp
    int 21h
    pop bp
    pop di
    pop si
  end;
end;

procedure DosDelete;
begin
  asm
    mov ah, 41h
    mov dx, offset PathZ
    push si
    push di
    push bp
    int 21h
    pop bp
    pop di
    pop si
  end;
end;

{ Both transfers point DS at the far buffer for the duration of the call and
  put it straight back; every operand is read off the stack first, so DGROUP
  is never needed while DS is away. }

function DosWrite(Handle, Sg, Count: Word; var Done: Word): Boolean;
var D, E: Word;
begin
  D := 0; E := 0;
  asm
    mov bx, Handle
    mov cx, Count
    mov ax, Sg
    push ds
    push si
    push di
    push bp
    mov ds, ax
    xor dx, dx
    mov ah, 40h
    int 21h
    pop bp
    pop di
    pop si
    pop ds
    jnc @@ok
    mov E, ax
    jmp @@done
  @@ok:
    mov D, ax
  @@done:
  end;
  Done := D;
  DskError := E;
  DosWrite := E = 0;
end;

function DosRead(Handle, Sg, Count: Word; var Done: Word): Boolean;
var D, E: Word;
begin
  D := 0; E := 0;
  asm
    mov bx, Handle
    mov cx, Count
    mov ax, Sg
    push ds
    push si
    push di
    push bp
    mov ds, ax
    xor dx, dx
    mov ah, 3Fh
    int 21h
    pop bp
    pop di
    pop si
    pop ds
    jnc @@ok
    mov E, ax
    jmp @@done
  @@ok:
    mov D, ax
  @@done:
  end;
  Done := D;
  DskError := E;
  DosRead := E = 0;
end;

function DosSeek(Handle: Word; Pos: LongInt): Boolean;
var E: Word; Hi, Lo: Word;
begin
  Hi := Word(Pos shr 16);
  Lo := Word(Pos and $FFFF);
  E := 0;
  asm
    mov ax, 4200h
    mov bx, Handle
    mov cx, Hi
    mov dx, Lo
    push si
    push di
    push bp
    int 21h
    pop bp
    pop di
    pop si
    jnc @@done
    mov E, ax
  @@done:
  end;
  DskError := E;
  DosSeek := E = 0;
end;

function DosCurrentDrive: Byte;
var D: Byte;
begin
  asm
    mov ah, 19h
    push si
    push di
    push bp
    int 21h
    pop bp
    pop di
    pop si
    mov D, al
  end;
  DosCurrentDrive := D;      { 0 = A: }
end;

{ AH=36h: AX sectors per cluster (FFFFh means the drive is not there),
  BX free clusters, CX bytes per sector. }
function DosFreeBytes(Drive: Byte; var Bytes: LongInt): Boolean;
var Spc, Free_, Bps: Word; T: Int64;
begin
  Spc := 0; Free_ := 0; Bps := 0;
  asm
    mov ah, 36h
    mov dl, Drive
    push si
    push di
    push bp
    int 21h
    pop bp
    pop di
    pop si
    mov Spc, ax
    mov Free_, bx
    mov Bps, cx
  end;
  Bytes := 0;
  if Spc = $FFFF then
  begin
    DosFreeBytes := False;
    Exit;
  end;
  T := Int64(Spc) * Int64(Free_) * Int64(Bps);
  if T > Int64(MaxLongInt) then Bytes := MaxLongInt else Bytes := LongInt(T);
  DosFreeBytes := True;
end;

{ --------------------------------------------------------- the INT 24h stub }

{ DOS calls this with its own stack when a device fails. AL=3 is FAIL, which
  turns the failure into an ordinary error code on the INT 21h call that
  provoked it - so an empty drive becomes a message from us rather than a
  prompt from DOS that a headless run can never answer. No stack frame: the
  handler leaves through IRET, so a pushed BP would never come back off. }
procedure Int24Fail; assembler; nostackframe;
asm
    mov al, 3
    iret
end;

procedure Int24Install;
begin
  if Int24Saved then Exit;
  GetIntVec($24, OldInt24);
  SetIntVec($24, @Int24Fail);
  Int24Saved := True;
end;

procedure Int24Restore;
begin
  if not Int24Saved then Exit;
  SetIntVec($24, OldInt24);
  Int24Saved := False;
end;

{ ------------------------------------------------------------------ helpers }

procedure SetPathZ;
var I: Integer; S: String;
begin
  if DskDrive = 0 then S := 'ATDISK.$$$'
  else S := DskLetter + ':ATDISK.$$$';
  for I := 1 to Length(S) do PathZ[I - 1] := S[I];
  PathZ[Length(S)] := #0;
end;

{ Value in millionths, clamped rather than wrapped: a cached read can be fast
  enough to overflow the 32-bit form, and a wrapped number would look like a
  measurement. }
function Millionths(Amount: LongWord; Us: LongWord): LongWord;
var T: Int64;
begin
  if (Us = 0) or (Amount = 0) then
  begin
    Millionths := 0;
    Exit;
  end;
  T := (Int64(Amount) * 1000000 * 1000000) div Int64(Us);
  if T > Int64($FFFFFFFF) then Millionths := $FFFFFFFF
  else Millionths := LongWord(T);
end;

{ Bytes per second - which the report prints as MB/s, since it divides by a
  million like every other rate in the suite. }
function BytesPerSec(Bytes: LongInt; Us: LongWord): LongWord;
var T: Int64;
begin
  if (Us = 0) or (Bytes <= 0) then
  begin
    BytesPerSec := 0;
    Exit;
  end;
  T := (Int64(Bytes) * 1000000) div Int64(Us);
  if T > Int64($FFFFFFFF) then BytesPerSec := $FFFFFFFF
  else BytesPerSec := LongWord(T);
end;

procedure SetResult(I: Integer; Value: LongWord);
begin
  DskTestRes[I].Ran := True;
  DskTestRes[I].Skipped := False;
  DskTestRes[I].Value := Value;
end;

procedure SkipResult(I: Integer; const Why: String);
begin
  DskTestRes[I].Ran := False;
  DskTestRes[I].Skipped := True;
  DskTestRes[I].Why := Why;
end;

function BudgetSpent(T0: TStamp; BudgetMs: LongWord): Boolean;
begin
  BudgetSpent := StampMs(StampDiff(T0, Stamp)) > BudgetMs;
end;

{ ------------------------------------------------------------------- phases }

{ Create, write, close - all inside the timed window, because a write that is
  not on the platter yet is not a write. Closing is what makes DOS flush its
  buffers and update the directory. }
function WriteRun(Block: Word; Want: LongInt; BudgetMs: LongWord;
                  var Written: LongInt; var Us: LongWord): Boolean;
var
  H, N, Done, Guard : Word;
  Left              : LongInt;
  T0                : TStamp;
  Ok                : Boolean;
begin
  Written := 0;
  Us := 0;
  WriteRun := False;
  Left := Want;
  Guard := 0;
  Ok := True;

  T0 := Stamp;
  if not DosCreate(H) then Exit;
  FileMade := True;
  while Left > 0 do
  begin
    if Left < Block then N := Word(Left) else N := Block;
    if not DosWrite(H, WrSeg, N, Done) then begin Ok := False; Break end;
    Inc(Written, Done);
    Dec(Left, Done);
    if Done < N then begin Ok := False; Break end;   { out of room }
    Inc(Guard);
    if (Guard and 15) = 0 then
    begin
      if BudgetSpent(T0, BudgetMs) then Break;
      if EscPressed then Break;
    end;
  end;
  DosClose(H);
  Us := StampUs(StampDiff(T0, Stamp));
  LastBlock := Block;
  LastFileSize := Written;
  WriteRun := Ok and (Written > 0);
end;

function ReadRun(Block: Word; Want: LongInt; BudgetMs: LongWord;
                 var Got: LongInt; var Us: LongWord): Boolean;
var
  H, N, Done, Guard : Word;
  Left              : LongInt;
  T0                : TStamp;
  Ok                : Boolean;
begin
  Got := 0;
  Us := 0;
  ReadRun := False;
  Left := Want;
  Guard := 0;
  Ok := True;

  T0 := Stamp;
  if not DosOpen(H) then Exit;
  while Left > 0 do
  begin
    if Left < Block then N := Word(Left) else N := Block;
    if not DosRead(H, RdSeg, N, Done) then begin Ok := False; Break end;
    Inc(Got, Done);
    Dec(Left, Done);
    if Done < N then Break;                          { end of file }
    Inc(Guard);
    if (Guard and 15) = 0 then
    begin
      if BudgetSpent(T0, BudgetMs) then Break;
      if EscPressed then Break;
    end;
  end;
  DosClose(H);
  Us := StampUs(StampDiff(T0, Stamp));
  ReadRun := Ok and (Got > 0);
end;

{ Read the head of the file twice and time the second pass. Whatever cache is
  present - DOS buffers, SMARTDRV, the drive's own - the first pass fills it,
  so this figure is the cache's speed rather than the drive's. The gap between
  the two is the point. }
function CacheRun(var Got: LongInt; var Us: LongWord): Boolean;
var
  H, N, Done : Word;
  Left       : LongInt;
  T0         : TStamp;
  Want       : LongInt;
begin
  Got := 0;
  Us := 0;
  CacheRun := False;
  Want := CacheWant;
  if Want > DskFileBytes then Want := DskFileBytes;
  if Want <= 0 then Exit;

  if not DosOpen(H) then Exit;

  Left := Want;                                      { warming pass }
  while Left > 0 do
  begin
    if Left < BufBytes then N := Word(Left) else N := BufBytes;
    if not DosRead(H, RdSeg, N, Done) then begin DosClose(H); Exit end;
    Dec(Left, Done);
    if Done < N then Break;
  end;

  if not DosSeek(H, 0) then begin DosClose(H); Exit end;

  Left := Want;
  T0 := Stamp;
  while Left > 0 do
  begin
    if Left < BufBytes then N := Word(Left) else N := BufBytes;
    if not DosRead(H, RdSeg, N, Done) then Break;
    Inc(Got, Done);
    Dec(Left, Done);
    if Done < N then Break;
  end;
  Us := StampUs(StampDiff(T0, Stamp));
  DosClose(H);
  CacheRun := Got > 0;
end;

{ Seek somewhere, read one block, repeat. The seek is what is being measured -
  which is why the answer is also reported as a mean time in milliseconds, the
  one number that separates a hard disk from a CF card from a floppy without
  any knowledge of either. }
function RandRun(Block: Word; BudgetMs: LongWord;
                 var Ops: LongWord; var Us: LongWord): Boolean;
var
  H, Done : Word;
  Blocks  : LongWord;
  Pos     : LongInt;
  T0      : TStamp;
begin
  Ops := 0;
  Us := 0;
  RandRun := False;
  if DskFileBytes <= LongInt(Block) then Exit;
  Blocks := LongWord(DskFileBytes div LongInt(Block));
  if Blocks < 2 then Exit;

  if not DosOpen(H) then Exit;
  T0 := Stamp;
  while Ops < MaxRandOps do
  begin
    Rnd := Rnd * 1103515245 + 12345;
    Pos := LongInt((Rnd shr 8) mod Blocks) * LongInt(Block);
    if not DosSeek(H, Pos) then Break;
    if not DosRead(H, RdSeg, Block, Done) then Break;
    Inc(Ops);
    if (Ops and 7) = 0 then
    begin
      if BudgetSpent(T0, BudgetMs) then Break;
      if EscPressed then Break;
    end;
  end;
  Us := StampUs(StampDiff(T0, Stamp));
  DosClose(H);
  RandRun := Ops > 0;
end;

{ --------------------------------------------------------------- the driver }

procedure InitTable;
begin
  DskTests[tSeqW].Id  := 'seqw';
  DskTests[tSeqW].Title := 'sequential write, 32K';
  DskTests[tSeqW].Metric := 'MB/s';
  DskTests[tSeqR].Id  := 'seqr';
  DskTests[tSeqR].Title := 'sequential read, 32K';
  DskTests[tSeqR].Metric := 'MB/s';
  DskTests[tCache].Id := 'cache';
  DskTests[tCache].Title := 'cached re-read';
  DskTests[tCache].Metric := 'MB/s';
  DskTests[tIop5].Id  := 'rnd512';
  DskTests[tIop5].Title := 'random read, 512 B';
  DskTests[tIop5].Metric := 'IOPS';
  DskTests[tAcc5].Id  := 'acc512';
  DskTests[tAcc5].Title := 'access time, 512 B';
  DskTests[tAcc5].Metric := 'ms';
  DskTests[tIop4K].Id := 'rnd4k';
  DskTests[tIop4K].Title := 'random read, 4 KB';
  DskTests[tIop4K].Metric := 'IOPS';
  DskTests[tAcc4K].Id := 'acc4k';
  DskTests[tAcc4K].Title := 'access time, 4 KB';
  DskTests[tAcc4K].Metric := 'ms';
  DskTests[tWr512].Id := 'wr512';
  DskTests[tWr512].Title := 'write, 512 B blocks';
  DskTests[tWr512].Metric := 'MB/s';
  DskTests[tRd512].Id := 'rd512';
  DskTests[tRd512].Title := 'read, 512 B blocks';
  DskTests[tRd512].Metric := 'MB/s';
  DskTests[tWr2K].Id  := 'wr2k';
  DskTests[tWr2K].Title := 'write, 2 KB blocks';
  DskTests[tWr2K].Metric := 'MB/s';
  DskTests[tRd2K].Id  := 'rd2k';
  DskTests[tRd2K].Title := 'read, 2 KB blocks';
  DskTests[tRd2K].Metric := 'MB/s';
  DskTests[tWr8K].Id  := 'wr8k';
  DskTests[tWr8K].Title := 'write, 8 KB blocks';
  DskTests[tWr8K].Metric := 'MB/s';
  DskTests[tRd8K].Id  := 'rd8k';
  DskTests[tRd8K].Title := 'read, 8 KB blocks';
  DskTests[tRd8K].Metric := 'MB/s';
end;

function DskProbe: Boolean;
var D: Byte;
begin
  DskProbe := False;
  DskWhy := '';
  DskFreeBytes := 0;
  if DskDrive = 0 then D := DosCurrentDrive + 1 else D := DskDrive;
  DskLetter := Chr(Ord('A') + D - 1);
  DskIsFloppy := D <= 2;

  if DskIsFloppy and (not DskAllowFloppy) then
  begin
    DskWhy := 'floppy drive, not confirmed';
    Exit;
  end;
  if not DosFreeBytes(D, DskFreeBytes) then
  begin
    DskWhy := 'drive ' + DskLetter + ': is not there';
    Exit;
  end;
  if DskFreeBytes < SeqFloor + FreeMargin then
  begin
    DskWhy := 'not enough free space';
    Exit;
  end;
  DskProbe := True;
end;

function DskTestsInit: Boolean;
var I: Integer;
begin
  DskTestsInit := False;
  DskReady := False;
  DskFileBytes := 0;
  DskCacheDoubt := False;
  FileMade := False;
  LastBlock := 0;
  LastFileSize := 0;

  InitTable;
  for I := 0 to DskTestN - 1 do
  begin
    DskTestRes[I].Ran := False;
    DskTestRes[I].Skipped := False;
    DskTestRes[I].Why := '';
    DskTestRes[I].Value := 0;
  end;

  if not DskProbe then Exit;

  WrBuf.Base := 0;
  RdBuf.Base := 0;
  if not FarAlloc(BufBytes, WrBuf) then
  begin
    DskWhy := 'no memory for the buffers';
    Exit;
  end;
  if not FarAlloc(BufBytes, RdBuf) then
  begin
    FarFree(WrBuf);
    DskWhy := 'no memory for the buffers';
    Exit;
  end;
  FarPattern(WrBuf, $2468);
  WrSeg := WrBuf.Base;
  RdSeg := RdBuf.Base;

  SetPathZ;
  Int24Install;
  Rnd := 987654321;
  DskReady := True;
  DskRun := True;
  DskTestsInit := True;
end;

procedure DskTestsDone;
begin
  if FileMade then
  begin
    DosDelete;
    FileMade := False;
  end;
  Int24Restore;
  if DskReady then
  begin
    FarFree(RdBuf);
    FarFree(WrBuf);
    DskReady := False;
  end;
end;

function DskPhaseTitle(P: Integer): String;
begin
  case P of
    0: DskPhaseTitle := 'sequential write';
    1: DskPhaseTitle := 'sequential read';
    2: DskPhaseTitle := 'cached re-read';
    3: DskPhaseTitle := 'random access, 512 B';
    4: DskPhaseTitle := 'random access, 4 KB';
    5: DskPhaseTitle := 'block sweep, 512 B';
    6: DskPhaseTitle := 'block sweep, 2 KB';
    7: DskPhaseTitle := 'block sweep, 8 KB';
  else
    DskPhaseTitle := '';
  end;
end;

{ How much the sweep should move: enough to mean something, little enough that
  three of them at 512 bytes a block do not outlast everything else. }
function SweepWant: LongInt;
begin
  if DskFileBytes < 262144 then SweepWant := DskFileBytes
  else SweepWant := 262144;
end;

procedure RunSweep(Block: Word; WrIdx, RdIdx: Integer);
var
  Written, Got : LongInt;
  Us           : LongWord;
begin
  if not WriteRun(Block, SweepWant, SweepBudgetMs, Written, Us) then
  begin
    SkipResult(WrIdx, 'write failed');
    SkipResult(RdIdx, 'no file to read');
    Exit;
  end;
  SetResult(WrIdx, BytesPerSec(Written, Us));
  { Read back exactly what the write left behind. }
  if ReadRun(Block, Written, SweepBudgetMs, Got, Us) then
    SetResult(RdIdx, BytesPerSec(Got, Us))
  else
    SkipResult(RdIdx, 'read failed');
end;

procedure RunRandom(Block: Word; IopIdx, AccIdx: Integer);
var
  Ops : LongWord;
  Us  : LongWord;
begin
  if not RandRun(Block, RandBudgetMs, Ops, Us) then
  begin
    SkipResult(IopIdx, 'no result');
    SkipResult(AccIdx, 'no result');
    Exit;
  end;
  SetResult(IopIdx, Millionths(Ops, Us));
  { Mean time per access, in millionths of a millisecond. }
  SetResult(AccIdx, LongWord((Int64(Us) * 1000) div Int64(Ops)));
end;

procedure DskRunPhase(P: Integer);
var
  Want, Moved : LongInt;
  Us          : LongWord;
begin
  if not DskReady then Exit;
  if BenchAborted then Exit;

  case P of
    0: begin
         Want := DskFreeBytes - FreeMargin;
         if Want > MaxSeq then Want := MaxSeq;
         if Want < SeqFloor then
         begin
           SkipResult(tSeqW, 'not enough free space');
           Exit;
         end;
         if not WriteRun(BufBytes, Want, SeqBudgetMs, Moved, Us) then
         begin
           if Moved > 0 then SetResult(tSeqW, BytesPerSec(Moved, Us))
           else SkipResult(tSeqW, 'write failed');
         end
         else SetResult(tSeqW, BytesPerSec(Moved, Us));
         DskFileBytes := Moved;
         DskCacheDoubt := DskFileBytes < MinSeq;
       end;

    1: if DskFileBytes <= 0 then SkipResult(tSeqR, 'no file to read')
       else if ReadRun(BufBytes, DskFileBytes, SeqBudgetMs, Moved, Us) then
         SetResult(tSeqR, BytesPerSec(Moved, Us))
       else SkipResult(tSeqR, 'read failed');

    2: if DskFileBytes <= 0 then SkipResult(tCache, 'no file to read')
       else if CacheRun(Moved, Us) then
         SetResult(tCache, BytesPerSec(Moved, Us))
       else SkipResult(tCache, 'read failed');

    3: RunRandom(512, tIop5, tAcc5);
    4: RunRandom(4096, tIop4K, tAcc4K);

    { The sweeps overwrite the file, so they come after everything that needs
      it at full length. }
    5: RunSweep(512, tWr512, tRd512);
    6: RunSweep(2048, tWr2K, tRd2K);
    7: RunSweep(8192, tWr8K, tRd8K);
  end;
end;

function DskSelfCheck: String;
var
  H, Done, N : Word;
  Ok         : Boolean;
  Src, Got   : TFarBuf;
begin
  DskSelfCheck := '';
  if not DskReady then begin DskSelfCheck := 'disk setup failed'; Exit end;
  N := LastBlock;
  if N = 0 then Exit;                        { nothing has been written yet }
  if LastFileSize < LongInt(N) then Exit;    { nothing long enough to check }

  if not DosOpen(H) then
  begin
    DskSelfCheck := 'temp file vanished';
    Exit;
  end;
  FarFill(RdBuf, 0);
  Ok := DosRead(H, RdSeg, N, Done) and (Done = N);
  DosClose(H);
  if not Ok then
  begin
    DskSelfCheck := 'read back failed';
    Exit;
  end;

  { CRC32 over just the block that was written, by describing that prefix of
    each buffer as a buffer of its own. }
  Src := WrBuf; Src.Size := N;
  Got := RdBuf; Got.Size := N;
  if FarCrc32(Got) <> FarCrc32(Src) then
    DskSelfCheck := 'data read back does not match';
end;

{ Belt and braces: the normal path already deletes the file and puts INT 24h
  back, but a runtime error anywhere in the suite would otherwise leave a
  multi-megabyte file and a vector pointing into a program that has exited. }
procedure DskExit; far;
begin
  ExitProc := PrevExit;
  if FileMade then
  begin
    DosDelete;
    FileMade := False;
  end;
  Int24Restore;
end;

begin
  DskReady := False;
  DskRun := False;
  DskDrive := 0;
  DskAllowFloppy := False;
  DskIsFloppy := False;
  DskCacheDoubt := False;
  DskFileBytes := 0;
  DskWhy := '';
  FileMade := False;
  Int24Saved := False;
  PrevExit := ExitProc;
  ExitProc := @DskExit;
end.
