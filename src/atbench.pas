program atbench;
{ ATBench iteration 1: system detection, CPU/RAM suites, reports and DB.
  (C) Ivan Polyacov, ivan@apus-software.com, 2026. GPL-3.0-or-later. }

uses attime, atharn, atcpuid, atsys, attcpu, atmemx, attmem,
     attvid, attvbe, attdsk, attcmp, atscore, atdbg, atui, atrep, atdb;

{$I at.inc}

type
  { Which suites a run covers. A set rather than a single choice: /cpu /ram
    used to keep only the last switch and drop the rest without a word, which
    is the kind of thing you discover after the machine is packed away. }
  TSuite  = (suCpu, suMem, suVid, suDsk);
  TSuites = set of TSuite;

  { The frame tiers are chosen the same way and kept apart from the suites on
    purpose: a tier is a size of the same benchmark, not another benchmark,
    and which size to run is a decision about this machine that nothing here
    is in a position to make for the user. }
  TTiers  = set of TCmpTier;

const
  AllSuites = [suCpu, suMem, suVid, suDsk];

var
  HaveRun : Boolean;
  AutoRun : Boolean;
  AutoSuites : TSuites;
  AutoTiers  : TTiers;
  CliLabel : String;    { /label ... }
  CliNotes : String;    { /notes ... }
  WantTrace : Boolean;  { /trace }
  WantStep  : Boolean;  { /step }
  WantHelp  : Boolean;  { /? /h /help, or a switch we do not know }
  BadOpt    : Boolean;  { ...it was the second of those }

function UpCaseChar(C: Char): Char;
begin
  if (C >= 'a') and (C <= 'z') then C := Chr(Ord(C) - 32);
  UpCaseChar := C;
end;

function RateText(V: LongWord): String;
var A, B: LongWord; S, T: String;
begin
  A := V div 1000000;
  B := (V mod 1000000) div 10000;
  Str(A, S); Str(B, T);
  if Length(T) < 2 then T := '0' + T;
  RateText := S + '.' + T;
end;

function NumStr(V: LongWord): String;
var S: String;
begin
  Str(V, S);
  NumStr := S;
end;

{ ----------------------------------------------------------------------------
  Prose that lives in the code segment.

  ATBENCH has some forty bytes left in DGROUP. The measurement buffers, the
  test tables and the report's line cache have taken the rest, and they are
  what the program is for - a page of help text is not going to win that
  argument. So the two blocks that are prose rather than results are
  assembled into the code segment, which in the medium memory model is far
  and plentiful, and written straight from there. Neither costs a data byte.

  Written through DOS function 09h rather than the BIOS TTY so that

    ATBENCH /? > HELP.TXT

  does what it looks like it does. The usage text is also the one thing that
  must print before CpuDetect has run: asking a program what its switches are
  should never require it to touch the hardware first.
  ---------------------------------------------------------------------------- }
{ Printed above the usage text when a switch was not recognised. Separate so
  that /? stays quiet: a question answered is not an error. }
procedure UsageBadOpt; assembler;
asm
    push ds
    push cs
    pop  ds
    mov  dx, offset @@txt
    mov  ah, 09h
    int  21h
    pop  ds
    jmp  @@done
  @@txt:
    db 13,10,'atbench: unrecognised switch',13,10,'$'
  @@done:
end;

procedure Usage; assembler;
asm
    push ds
    push cs
    pop  ds
    mov  dx, offset @@txt
    mov  ah, 09h
    int  21h
    pop  ds
    jmp  @@done
  @@txt:
    db 13,10
    db 'ATBench 1.0 - a benchmark for DOS machines, 286 to Pentium MMX',13,10
    db 13,10
    db 'usage: ATBENCH [switches]        no switches at all: the menu',13,10
    db 13,10
    db 'suites - any combination, and any of them makes the run automatic',13,10
    db '  /auto                 CPU, RAM, video and disk',13,10
    db '  /cpu /ram /video /disk   one suite each',13,10
    db '  /frame [low|std|high] the composite frame suite, one tier.',13,10
    db '                        /frame on its own means std. Deliberately',13,10
    db '                        not part of /auto: which tier to run is a',13,10
    db '                        decision about the machine in front of you.',13,10
    db 13,10
    db 'run options',13,10
    db '  /label <text>         machine label, up to the next switch',13,10
    db '  /notes <text>         free notes, up to the next switch',13,10
    db '  /fdd                  let the disk tests write to a floppy',13,10
    db '  /emu                  record the run as an emulated machine',13,10
    db '  /safe                 skip the XMS, EMS and VBE probes, which are',13,10
    db '                        the detections that call resident code',13,10
    db 13,10
    db 'diagnostics - for a machine that dies or hangs mid-run',13,10
    db '  /trace                name each phase on screen and in TRACE.TXT',13,10
    db '  /step                 /trace, and wait for a key after each phase',13,10
    db '  /?  /h  /help         this text',13,10
    db 13,10
    db 'An automated run writes REPORT.TXT and saves a numbered record under',13,10
    db 'DB\. From the menu, S saves the run that is in memory.',13,10
    db '$'
  @@done:
end;

{ The second block, and the only fatal diagnostic that has to print before
  any of the UI exists. Kept here with the other one for the same reason:
  five lines of explanation would not fit in the data segment. }
procedure SayTimerDead; assembler;
asm
    push ds
    push cs
    pop  ds
    mov  dx, offset @@txt
    mov  ah, 09h
    int  21h
    pop  ds
    jmp  @@done
  @@txt:
    db 13,10
    db 'TIMER FAILED: the PIT is counting, but IRQ0 never reaches the',13,10
    db 'benchmark clock. Nothing on this machine can be measured until',13,10
    db 'that is fixed, so the run was not started. Known causes, in the',13,10
    db 'order worth trying:',13,10
    db 13,10
    db '  - USB legacy / USB keyboard support in the BIOS setup. It',13,10
    db '    services the port out of SMM and does not survive the timer',13,10
    db '    running at 291 Hz instead of 18.2. Turn it off.',13,10
    db '  - APM or any power management that idles the machine.',13,10
    db '  - a TSR or driver that hooks INT 08h without chaining. Boot',13,10
    db '    clean - no EMM386, no TSRs - and try again.',13,10
    db 13,10
    db '$'
  @@done:
end;

{ One line of what a run prints as it goes, in the colours the report gives
  that kind of line. The kinds are ATREP's, and that is the point: the score
  block printed the moment a run ends and the score block on the report's
  first page are the same lines, so they are coloured from the same table
  rather than from two ideas of what a score row looks like. }
procedure Say(K: Char; const S: String);
begin
  UiSay(S, ReportLineMask(K, S));
end;

{ Read straight off the keyboard rather than through ReadLn: the question is
  "has somebody seen this", and any key answers it. ReadLn also insists on the
  one key that is hardest to find blind, and would eat a line of piped input
  that was meant for something else. }
procedure Pause;
var K: Word;
begin
  if AutoRun then Exit;
  WriteLn;
  Write('Press any key');
  K := UiKey;
  WriteLn;
end;

{ Built up as a string and then said, where it used to be a run of Writes. A
  line has to exist whole before it can be painted: the mask is one character
  per column, so there is no colouring half a line that is still being
  written. }
procedure ShowMachine;
var S: String;
begin
  UiTitle('System');
  S := 'CPU: ' + CpuName + ' (' + CpuClassStr + ')';
  if CpuMhz <> 0 then
  begin
    S := S + ', ' + NumStr(CpuMhz) + ' MHz';
    if MhzExact then S := S + ' measured' else S := S + ' estimated';
  end;
  Say('k', S);
  Say('k', 'FPU: ' + FpuClassStr + '  MMX: ' + NumStr(Ord(HasMmx)));
  Say('k', 'DOS: ' + DosVerStr + '  conventional: ' + NumStr(ConvKb) +
           ' KB  free: ' + NumStr(FreeDosKb) + ' KB');
  Say('k', 'Video: ' + VideoKind + '  ' + VideoBios);
  if VbeOk then
  begin
    S := 'VBE: ' + BcdVerStr(VbeVer) + '  ' + NumStr(VbeMemKb) + ' KB';
    if VbeOem <> '' then S := S + '  ' + VbeOem;
    Say('k', S);
  end;
  if InV86 then Say('w', 'WARNING: V86 mode may distort timing and I/O');
  if SmartDrv then
    Say('w', 'WARNING: ' + DiskCache + ' may distort disk results');
end;

function SaveDatabase: Boolean;
var
  LabelText, NotesText, Name: String;
begin
  SaveDatabase := False;
  if not HaveRun then Exit;
  if AutoRun then
  begin
    { An automated run has nobody to ask, so the label comes from the command
      line. It used to be hardwired to the QEMU correctness loop, which was
      fine while that was the only automated caller and wrong the moment one
      ran /auto on a real machine: the record went into the database claiming
      to be an emulator run. }
    LabelText := CliLabel;
    NotesText := CliNotes;
    if LabelText = '' then
      if ReportEmulated then LabelText := 'automated run, emulated'
      else LabelText := 'automated run, unlabelled';
    if (NotesText = '') and ReportEmulated then
      NotesText := 'emulated; timings are not benchmark data';
  end
  else
  begin
    { No "are you sure": the only way here is the menu item that says it, so
      the question would be asking twice for the same answer. }
    Write('Machine label: '); ReadLn(LabelText);
    Write('Notes: '); ReadLn(NotesText);
  end;
  if DbSave(LabelText, NotesText, Name) then
  begin
    Say('k', 'Saved ' + Name + ' (' + NumStr(DbCount) + ' record(s))');
    SaveDatabase := True;
  end
  else Say('e', 'Database write failed, DOS error ' + NumStr(DbError));
end;

{ False when the machine cannot be measured at all, which is one specific
  fault and not a general one: the benchmark clock is installed but IRQ0 never
  reaches it. Every number a run produced in that state would be zero or
  nonsense, so the run does not start - and it says why, because the causes
  are all things the person in front of the machine can change. }
function BeginRun: Boolean;
begin
  BenchAborted := False;
  BeginRun := False;
  Dbg('TimerInstall');
  TimerInstall;
  if not TimerIrqOk then
  begin
    Dbg('timer dead, run refused');
    SayTimerDead;
    Exit;
  end;
  Dbg('CpuMeasureMhz');
  CpuMeasureMhz;
  Dbg('ShowMachine');
  ShowMachine;
  Dbg('run started');
  BeginRun := True;
end;

procedure FinishRun(const DoneText: String);
begin
  HaveRun := True;
  if BenchAborted then Say('n', 'Run cancelled; partial results kept')
  else Say('n', DoneText);
  { The indices before the file writing, because they are what the run was
    for and the user should not have to open a report to see them. }
  Dbg('ReportSummary');
  ReportSummary;
  WriteLn;
  Dbg('ReportFile');
  if ReportFile('REPORT.TXT') then Say('n', 'Wrote REPORT.TXT')
  else Say('e', 'REPORT.TXT failed, DOS error ' + NumStr(ReportError));
  { Only an automated run saves itself, and only because there is nobody to
    ask. Asking after every suite was a question with a menu item of its own
    two keystrokes away: a run of four suites asked it four times, and the
    answer that matters is the one given once, at the end, when the results
    are worth keeping. }
  if AutoRun then
  begin
    Dbg('SaveDatabase');
    SaveDatabase;
  end
  else Say('n', 'Results kept in memory; menu item S saves them to the ' +
                'database.');
  Dbg('run finished');
end;

function RunCpuCore: Boolean;
var
  I       : Integer;
  Check   : String;
begin
  Dbg('CpuTestsInit');
  CpuTestsInit;
  Dbg('CpuSelfCheck');
  Check := CpuSelfCheck;
  if Check <> '' then
  begin
    Say('e', 'CPU SELF-CHECK FAILED: ' + Check);
    RunCpuCore := False;
    Exit;
  end;

  UiTitle('CPU benchmark');
  for I := 0 to CpuTestN - 1 do
  begin
    UiProgress(I + 1, CpuTestN, CpuTests[I].Title);
    CpuTestRun(I);
    if BenchAborted then Break;
  end;
  { Releases the row the progress line was rewriting, so whatever prints next
    starts under it instead of over it. }
  UiProgressEnd;

  Check := CpuSelfCheck;
  if Check <> '' then
  begin
    Say('e', 'CPU SELF-CHECK AFTER RUN FAILED: ' + Check);
    RunCpuCore := False;
    Exit;
  end;
  RunCpuCore := True;
end;

function RunMemCore: Boolean;
var
  I: Integer;
  MemOk: Boolean;
begin
  Dbg('MemTestsInit');
  MemOk := MemTestsInit;
  if MemOk then
  begin
    UiTitle('RAM benchmark');
    for I := 0 to MemTestN - 1 do
    begin
      UiProgress(I + 1, MemTestN, MemTests[I].Title);
      MemTestRun(I);
      if BenchAborted then Break;
    end;
    UiProgressEnd;
  end;
  if MemOk then MemTestsDone;
  if not MemOk then Say('n', 'Not enough conventional memory for RAM tests');
  RunMemCore := True;
end;

function RunVidCore: Boolean;
var
  I     : Integer;
  Check : String;
  VidOk : Boolean;
begin
  Check := '';
  UiTitle('VGA mode 13h benchmark');
  Say('n', 'Switching to graphics mode...');
  Dbg('VidTestsInit (mode 13h)');
  VidOk := VidTestsInit;
  if not VidOk then
  begin
    Say('n', 'VGA mode 13h setup failed; video tests skipped');
    RunVidCore := True;
    Exit;
  end;

  { Everything from here to VidTestsDone happens on the graphics screen, so
    progress is one line rewritten in place: a scroll in mode 13h means the
    BIOS moving the whole frame, which on a 286 is slower than some of the
    tests being reported. }
  Dbg('VidSelfCheck');
  Check := VidSelfCheck;
  if Check = '' then
    for I := 0 to VidTestN - 1 do
    begin
      Write(#13, 'test ', I + 1, '/', VidTestN, ': ', VidTests[I].Id, '      ');
      VidTestRun(I);
      if BenchAborted then Break;
    end;
  if (Check = '') and (not BenchAborted) then Check := VidSelfCheck;
  Dbg('VidTestsDone (mode restore)');
  VidTestsDone;

  UiTitle('VGA mode 13h results');
  for I := 0 to VidTestN - 1 do
    if VidTestRes[I].Ran then
      Say('k', VidTests[I].Title + ': ' + RateText(VidTestRes[I].Value) +
               ' ' + VidTests[I].Metric + '  spread=' +
               NumStr(VidTestRes[I].SpreadPc) + '%')
    else if VidTestRes[I].Skipped then
      Say('k', VidTests[I].Title + ': N/A ' + VidTestRes[I].Why);
  if Check <> '' then Say('e', 'VIDEO SELF-CHECK FAILED: ' + Check);

  { The bank switch, after mode 13h is done with and the screen is back in
    text. It sets a mode of its own and puts it back, and it says what it is
    about to do first: on a card that does not like 101h this is the last
    line the machine prints, and a line that names the mode is a bug report. }
  if not BenchAborted then
  begin
    UiTitle('VESA bank switch');
    Say('n', 'Setting mode 101h (640x480x8)...');
    Dbg('BankRun (mode 101h)');
    BankRun;
    Dbg('BankRun done');
    ReportBankLines;
  end;

  RunVidCore := (Check = '');
end;

{ One tier of the composite suite: set it up, prove the kernels right against
  the reference in Pascal, take the checksum, measure, and take the checksum
  again. The two checksums are the cheap half of the argument that the numbers
  mean anything - a kernel that scribbled on the texture or on another band
  would produce a different frame, and a different frame is a different CRC.

  True when the tier produced results. A tier that could not run is not a
  failure: it says why, in the same words the menu would have used. }
function RunFrameCore(T: TCmpTier): Boolean;
var
  I, N  : Integer;
  Check : String;
  Crc   : LongInt;
  Talk  : Boolean;
begin
  RunFrameCore := False;
  UiTitle('Game frame - ' + CmpTierCfg[T].Id + ', ' + CmpTierCfg[T].Title);

  { A tier that never starts is still a tier somebody asked for, so it goes on
    the record with its reason on every row rather than vanishing between the
    keystroke and the menu coming back. The message on the screen is a warning
    and not a note: it is the answer to the only question being asked at that
    moment, and it used to be painted in the colour of a passing remark. }
  Check := CmpTierWhy(T);
  if Check <> '' then
  begin
    Say('w', 'Frame tier ' + CmpTierCfg[T].Id + ' skipped: ' + Check);
    CmpTierRan[T] := True;
    CmpAnyRan := True;
    CmpMarkTier(T, Check);
    Exit;
  end;

  Dbg('CmpInit');
  if not CmpInit(T) then
  begin
    Say('w', 'Frame tier ' + CmpTierCfg[T].Id + ' skipped: ' + CmpWhy);
    CmpTierRan[T] := True;
    CmpAnyRan := True;
    CmpMarkTier(T, CmpWhy);
    Exit;
  end;

  Dbg('CmpSelfCheck');
  Check := CmpSelfCheck;
  if Check <> '' then
  begin
    Say('e', 'FRAME SELF-CHECK FAILED: ' + Check);
    CmpMarkTier(T, 'self-check failed');
    CmpDone;
    Exit;
  end;

  Dbg('CmpFrameCrc');
  Crc := CmpFrameCrc;
  CmpCrc[T]   := Crc;
  CmpCrcOk[T] := True;

  Say('n', 'Switching to graphics mode...');
  Dbg('CmpEnterMode');
  if not CmpEnterMode then
  begin
    Say('w', 'Frame tier ' + CmpTierCfg[T].Id + ' skipped: ' + CmpWhy);
    CmpMarkTier(T, CmpWhy);
    CmpDone;
    Exit;
  end;

  { The frame as it arrives on the card, before anything is timed. It is the
    one part of the suite whose correctness depends on the card rather than on
    us, and a window worked out wrongly puts the picture somewhere else
    without making any single pixel wrong. }
  Dbg('CmpPresentCheck');
  Check := CmpPresentCheck;
  if Check <> '' then
  begin
    { Said after the mode is back: in an SVGA mode there may be nothing that
      can render a line of text, and a failure nobody can read is a failure
      twice over. }
    CmpLeaveMode;
    Say('e', 'PRESENT CHECK FAILED: ' + Check);
    CmpMarkTier(T, 'present check failed');
    CmpDone;
    Exit;
  end;

  { On the graphics screen from here to the mode restore, so progress is one
    line rewritten in place - the same reason the mode 13h suite does it. In
    an SVGA mode it is printed only when output is going to a file: the BIOS
    owes nobody a text renderer in mode 101h, and asking it for one is the
    kind of thing that ends a run. }
  Talk := CmpTierCfg[T].Vga or (not UiDrawable);
  N := CmpLast(T) - CmpFirst(T) + 1;
  for I := CmpFirst(T) to CmpLast(T) do
  begin
    if Talk then
      Write(#13, 'test ', I - CmpFirst(T) + 1, '/', N, ': ',
            CmpTests[I].Id, '        ');
    Dbg('cmp test ' + CmpTests[I].Id);
    CmpRunTest(I);
    if BenchAborted then Break;
  end;
  Dbg('CmpLeaveMode');
  CmpLeaveMode;
  { Both of these are reasons a row came back empty, and until now only one of
    them was ever said out loud. A card whose window call the clock cannot
    follow skips every present and the frame itself - which is most of the
    tier - and the run said nothing about it at all: the reasons were on the
    rows, and the rows are two pages further on than the person watching. }
  if CmpPresentWhy <> '' then Say('w', 'NOTE: ' + CmpPresentWhy);
  if CmpTimerWhy <> '' then Say('w', 'NOTE: ' + CmpTimerWhy);

  if not BenchAborted then
  begin
    Check := CmpSelfCheck;
    if Check <> '' then Say('e', 'FRAME SELF-CHECK AFTER RUN FAILED: ' + Check)
    else if CmpFrameCrc <> Crc then
    begin
      Say('e', 'FRAME CHECKSUM CHANGED DURING THE RUN');
      CmpCrcOk[T] := False;
    end;
  end;

  RunFrameCore := CmpTierHasResults(T);
  CmpDone;

  UiTitle('Game frame results');
  ReportFrameLines;
end;

{ The drive is asked for once, before anything is written, and a floppy needs
  a second yes: a benchmark that writes megabytes to whatever happens to be in
  drive A: without asking would be a bad neighbour. }
procedure AskDisk;
var S: String; C: Char;
begin
  DskDrive := 0;
  DskAllowFloppy := False;
  Write('Drive letter [current]: '); ReadLn(S);
  if S <> '' then
  begin
    C := UpCaseChar(S[1]);
    if (C >= 'A') and (C <= 'Z') then DskDrive := Ord(C) - Ord('A') + 1;
  end;
  if not DskProbe then
  begin
    { The only reason worth a second question. }
    if DskIsFloppy then
    begin
      Write('Write a test file to ', DskLetter, ': (floppy)? [y/N] ');
      ReadLn(S);
      if (S <> '') and (UpCaseChar(S[1]) = 'Y') then DskAllowFloppy := True;
    end;
  end;
end;

function RunDskCore: Boolean;
var
  I     : Integer;
  Check : String;
begin
  UiTitle('Disk benchmark');
  Dbg('DskTestsInit');
  if not DskTestsInit then
  begin
    Say('k', 'Disk tests skipped: ' + DskWhy);
    RunDskCore := True;
    Exit;
  end;
  Say('k', 'Drive ' + DskLetter + ':  free ' +
           NumStr(DskFreeBytes div 1024) + ' KB');
  for I := 0 to DskPhaseN - 1 do
  begin
    UiProgress(I + 1, DskPhaseN, DskPhaseTitle(I));
    Dbg('disk phase ' + DskPhaseTitle(I));
    DskRunPhase(I);
    if BenchAborted then Break;
  end;
  UiProgressEnd;
  Dbg('DskSelfCheck');
  Check := DskSelfCheck;
  Dbg('DskTestsDone');
  DskTestsDone;
  if DskCacheDoubt then
    Say('w', 'NOTE: test file only ' + NumStr(DskFileBytes div 1024) +
             ' KB; the cache may not have been beaten');
  if Check <> '' then Say('e', 'DISK SELF-CHECK FAILED: ' + Check);
  RunDskCore := (Check = '');
end;

{ 'CPU, RAM, VGA and disk run complete' and the four single-suite variants of
  it, built from the selection instead of written out five times. A lone suite
  starts the sentence, so its name is capitalised there and nowhere else. }
function DoneText(Sel: TSuites; Tiers: TTiers): String;
var
  Names : array[1..7] of String[12];
  N, I  : Integer;
  T     : TCmpTier;
  S     : String;
begin
  N := 0;
  if suCpu in Sel then begin Inc(N); Names[N] := 'CPU'  end;
  if suMem in Sel then begin Inc(N); Names[N] := 'RAM'  end;
  if suVid in Sel then begin Inc(N); Names[N] := 'VGA'  end;
  if suDsk in Sel then begin Inc(N); Names[N] := 'disk' end;
  for T := ctLow to ctHigh do
    if T in Tiers then
    begin
      Inc(N);
      Names[N] := 'frame ' + CmpTierCfg[T].Id;
    end;
  S := '';
  for I := 1 to N do
    if I = 1 then S := Names[I]
    else if I = N then S := S + ' and ' + Names[I]
    else S := S + ', ' + Names[I];
  if (N = 1) and (Length(S) > 0) then S[1] := UpCaseChar(S[1]);
  DoneText := S + ' run complete';
end;

{ The selected suites, always in this order whatever order the switches were
  typed in. It is the order the report prints in, and letting the command line
  reorder it would only make two runs of the same machine harder to compare. }
procedure RunSelected(Sel: TSuites; Tiers: TTiers);
var
  CpuOk, Ran : Boolean;
  T          : TCmpTier;
begin
  if (suDsk in Sel) and (not AutoRun) then AskDisk;
  if not BeginRun then
  begin
    { Put the PIT and the vector back before returning: a clock nobody is
      listening to is worse than no clock, because the DOS time-of-day is
      chained through it. }
    TimerRemove;
    Pause;
    Exit;
  end;

  Ran   := False;
  CpuOk := True;
  if suCpu in Sel then
  begin
    CpuOk := RunCpuCore;
    if CpuOk then Ran := True;
  end;

  { The one gate between suites, and it predates this procedure: a CPU
    self-check that has just failed means the harness proved itself wrong, and
    memory numbers measured by the same arithmetic would inherit the fault. }
  if (suMem in Sel) and CpuOk and (not BenchAborted) then
    if RunMemCore then Ran := True;
  if (suVid in Sel) and (not BenchAborted) then
    if RunVidCore then Ran := True;
  if (suDsk in Sel) and (not BenchAborted) then
    if RunDskCore then Ran := True;
  for T := ctLow to ctHigh do
    if (T in Tiers) and (not BenchAborted) then
      if RunFrameCore(T) then Ran := True;

  TimerRemove;

  { Nothing ran at all is not the same as a run that went badly. A failed
    self-check aborts its suite before any test executes, so there are no
    numbers to write - and an empty REPORT.TXT laid over a good one is the
    worst outcome on offer. A run that produced anything is always reported,
    self-check failures included: they were printed as they happened, and the
    numbers around them are the evidence for diagnosing them. }
  if Ran then FinishRun(DoneText(Sel, Tiers));
end;

{ The heading line every screen carries: what this machine is, in the words
  the report uses for it. Rebuilt on the way into the menu because the clock
  speed is not measured until the first run. }
function MachineLine: String;
var S, T: String;
begin
  S := CpuName;
  if CpuMhz <> 0 then
  begin
    Str(CpuMhz, T);
    S := S + ' ' + T + ' MHz';
    if not MhzExact then S := S + '?';
  end;
  Str(ConvKb, T);
  S := S + '   ' + T + 'K conv';
  if XmsOk then
  begin
    Str(XmsFreeKb, T);
    S := S + ' + ' + T + 'K XMS';
  end;
  MachineLine := S + '   ' + VideoKind;
end;

procedure Menu;
var
  M : TUiMenu;
  C : Char;
begin
  UiMenuInit(M);
  UiMenuAdd(M, '1', 'Run CPU benchmark', '');
  UiMenuAdd(M, '2', 'Run RAM benchmark', '');
  UiMenuAdd(M, '3', 'Run VGA mode 13h benchmark', '');
  UiMenuAdd(M, '4', 'Run disk benchmark', '');
  UiMenuAdd(M, '5', 'Run all four benchmarks', '');
  { The frame tiers carry their sizes in the item text rather than in a legend
    somewhere else: the choice between them is a choice about this machine,
    and it is made here. }
  UiMenuAdd(M, '6', 'Game frame - low   256x200', '');
  UiMenuAdd(M, '7', 'Game frame - std   320x200', '');
  UiMenuAdd(M, '8', 'Game frame - high  512x480 VESA', '');
  UiMenuAdd(M, 'V', 'View accumulated results', '');
  UiMenuAdd(M, 'W', 'Write REPORT.TXT', '');
  UiMenuAdd(M, 'S', 'Save results to database', '');
  UiMenuAdd(M, 'Q', 'Quit', '');

  repeat
    { The last three need numbers to work on, and say so in those words: an
      item greyed out without a reason leaves the user guessing at something
      they could simply have done (DESIGN 8.4). }
    if HaveRun then
    begin
      UiMenuReason(M, 'V', '');
      UiMenuReason(M, 'W', '');
      UiMenuReason(M, 'S', '');
    end
    else
    begin
      UiMenuReason(M, 'V', 'run a benchmark first');
      UiMenuReason(M, 'W', 'run a benchmark first');
      UiMenuReason(M, 'S', 'run a benchmark first');
    end;
    { A tier that will not fit says so before it is picked, and says what it
      would have needed. }
    UiMenuReason(M, '6', CmpTierWhy(ctLow));
    UiMenuReason(M, '7', CmpTierWhy(ctStd));
    UiMenuReason(M, '8', CmpTierWhy(ctHigh));

    UiSetHead('ATBench 1.0 - iteration 1  (c) Ivan Polyacov, 2026', MachineLine);
    C := UiMenuRun(M);
    if C = #27 then C := 'Q';

    { Whatever runs next writes with ordinary DOS output, so the painted
      screen goes away before it starts rather than underneath it. On the way
      out it is DOS itself that gets the clean screen. }
    UiClear;

    case C of
      '1': begin RunSelected([suCpu], []); Pause end;
      '2': begin RunSelected([suMem], []); Pause end;
      '3': begin RunSelected([suVid], []); Pause end;
      '4': begin RunSelected([suDsk], []); Pause end;
      '5': begin RunSelected(AllSuites, []); Pause end;
      '6': begin RunSelected([], [ctLow]);  Pause end;
      '7': begin RunSelected([], [ctStd]);  Pause end;
      '8': begin RunSelected([], [ctHigh]); Pause end;
      { The pager ends by clearing the screen, so there is nothing left to
        read and nothing to hold. Only the line-printed form needs holding. }
      'V': if HaveRun then
           begin
             ReportScreen(False);
             if not UiDrawable then Pause;
           end;
      'W': if HaveRun then
           begin
             if ReportFile('REPORT.TXT') then Say('n', 'Wrote REPORT.TXT')
             else Say('e', 'Write failed, DOS error ' + NumStr(ReportError));
             Pause;
           end;
      'S': if HaveRun then begin SaveDatabase; Pause end;
    end;
  until C = 'Q';
end;

function LowStr(const S: String): String;
var I: Integer; R: String;
begin
  R := S;
  for I := 1 to Length(R) do
    if (R[I] >= 'A') and (R[I] <= 'Z') then R[I] := Chr(Ord(R[I]) + 32);
  LowStr := R;
end;

{ Words arrive one ParamStr at a time and go back together with single spaces.
  The cap is well short of 255 because the label also has to survive being
  read back out of a .ATR line. }
procedure AddWord(var S: String; const W: String);
begin
  if W = '' then Exit;
  if Length(S) + Length(W) + 1 > 100 then Exit;
  if S <> '' then S := S + ' ';
  S := S + W;
end;

{ DOS gives no quoting worth relying on, so /label and /notes swallow every
  following word up to the next switch:

    ATBENCH /auto /label 486DX2-66 turbo on /notes Trident 8900, 256K L2

  Switches are matched case-insensitively and in any position, because typing
  them in caps on the machine under test is the normal thing to do. }
{ /frame takes a tier name after it, and /frame on its own means the standard
  one. The pending flag is what lets both spellings work: a tier word claims
  the flag, and anything else - the next switch, or the end of the line -
  settles it as the default rather than losing the switch. }
procedure FlushFrame(var Pending: Boolean);
begin
  if not Pending then Exit;
  Pending := False;
  Include(AutoTiers, ctStd);
end;

procedure ParseArgs;
var I: Integer; P: String; Mode: Char; FramePend: Boolean;
begin
  AutoSuites := [];
  AutoTiers := [];
  FramePend := False;
  CliLabel := '';
  CliNotes := '';
  DskAllowFloppy := False;
  ReportEmulated := False;
  WantTrace := False;
  WantStep := False;
  WantHelp := False;
  BadOpt := False;
  SafeProbe := False;
  Mode := #0;
  for I := 1 to ParamCount do
  begin
    P := ParamStr(I);
    if (P <> '') and (P[1] = '/') then
    begin
      Mode := #0;
      P := LowStr(P);
      FlushFrame(FramePend);
      { Suite switches accumulate, so /cpu /ram runs both. /auto is the whole
        set and not a fifth alternative, which makes /auto /disk harmless
        rather than a contradiction. }
      if      P = '/auto'  then AutoSuites := AutoSuites + AllSuites
      else if P = '/cpu'   then Include(AutoSuites, suCpu)
      else if P = '/ram'   then Include(AutoSuites, suMem)
      else if P = '/video' then Include(AutoSuites, suVid)
      else if P = '/disk'  then Include(AutoSuites, suDsk)
      { The composite suite, and the one switch that takes a size. It is not
        part of /auto: a tier is a decision about the machine in front of you,
        and a script that ran the high tier on a 386SX would be measuring
        patience. }
      else if P = '/frame' then begin FramePend := True; Mode := 'F' end
      { Consent for a floppy: writing megabytes to whatever is in drive A:
        without asking would be a bad neighbour, and an automated run has
        nobody to ask. }
      else if P = '/fdd'   then DskAllowFloppy := True
      { Says the machine underneath is not real. Nothing detects this on its
        own - V86 is reported separately and is not the same claim - so the
        flag has to be asserted by whoever started the run. }
      else if P = '/emu'   then ReportEmulated := True
      { Diagnostics for a machine that dies mid-run. /step implies /trace. }
      { Leaves out the detections that call into other people's resident code.
        One of them taking the machine down should not cost the whole run. }
      else if P = '/safe'  then SafeProbe := True
      else if P = '/trace' then WantTrace := True
      else if P = '/step'  then begin WantTrace := True; WantStep := True end
      else if P = '/label' then Mode := 'L'
      else if P = '/notes' then Mode := 'N'
      else if (P = '/?') or (P = '/h') or (P = '/help') then WantHelp := True
      { A switch nobody recognised used to be dropped without a word, so
        ATBENCH /cpus sat in the menu looking like it had ignored the command
        line - which it had. Saying so costs one flag, and the usage text it
        then prints is the answer to the question the user was asking. }
      else begin WantHelp := True; BadOpt := True end;
    end
    else if Mode = 'F' then
    begin
      P := LowStr(P);
      if      P = 'low'  then begin Include(AutoTiers, ctLow);  FramePend := False end
      else if P = 'std'  then begin Include(AutoTiers, ctStd);  FramePend := False end
      else if P = 'high' then begin Include(AutoTiers, ctHigh); FramePend := False end
      else FlushFrame(FramePend);
      Mode := #0;
    end
    else if Mode = 'L' then AddWord(CliLabel, P)
    else if Mode = 'N' then AddWord(CliNotes, P);
  end;
  FlushFrame(FramePend);
  AutoRun := (AutoSuites <> []) or (AutoTiers <> []);
end;

begin
  ParseArgs;
  { Before anything else: no detection, no UI, no timer. What the switches
    are is a question about the program, not about the machine. }
  if WantHelp then
  begin
    if BadOpt then UsageBadOpt;
    Usage;
    if BadOpt then Halt(2) else Halt(0);
  end;
  DbgOn(WantTrace);
  DbgStep(WantStep);
  { Printed before anything else touches hardware. If a run dies and this line
    is missing, the program never reached its own first statement and the
    fault is in start-up, not in anything below. }
  Dbg('main entered, args parsed');
  HaveRun := False;

  Dbg('CpuDetect');
  CpuDetect;
  Dbg('SysDetect');
  SysDetect;
  Dbg('UiInit');
  UiInit(AutoRun);

  { The scoring arithmetic is fixed-point logarithms, which can be wrong in
    the one way nothing else catches: every score it produces still looks
    plausible. Checked once at startup, where a failure is visible. }
  Dbg('ScoreSelfCheck');
  if ScoreSelfCheck <> '' then
    Say('e', 'SCORE SELF-CHECK FAILED: ' + ScoreSelfCheck);
  Dbg('startup complete');

  if AutoRun then
  begin
    Say('t', 'ATBench 1.0 automated run');
    if ReportEmulated then
      Say('n', 'Emulated machine; timings are not benchmark data');
    if CliLabel <> '' then Say('k', 'Label: ' + CliLabel);
    RunSelected(AutoSuites, AutoTiers);
    ReportScreen(True);
  end
  else
  begin
    { Worth a line of its own: a run that lands here is waiting for a key,
      and on a machine started by a script there is nobody to press one -
      which reads exactly like a hang unless the trace says otherwise. }
    Dbg('menu, waiting for a key');
    Menu;
  end;
end.
