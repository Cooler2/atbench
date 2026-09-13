unit attvbe;
{ ----------------------------------------------------------------------------
  ATBench - what a VBE bank switch costs.

  Mode 13h fits in one 64K window, so nothing in ATTVID ever pays for a bank
  switch. Every SVGA mode of the era does: 640x480x8 is 300 KB seen through a
  64 KB hole, so a program that touches the whole frame moves that hole four
  times, and on some cards moving it costs more than filling it. That number
  is missing from every period benchmark, and it decides whether an SVGA mode
  is usable at all on the machine in front of you.

  Two ways to move the window, measured separately because the difference is
  the point:

    INT 10h AX=4F05h   the documented call. Pays for the interrupt, for the
                       BIOS dispatcher, and for whatever the VBE layer does
                       before it reaches the card - which on a BIOS shadowed
                       into RAM is one thing and on a BIOS still being read
                       out of ROM through an 8-bit path is quite another.

    window function    VBE 1.2 and later hand out a far pointer straight to
                       the code that programs the card (ModeInfoBlock+0Ch).
                       Same registers, no status returned, no dispatcher. Any
                       program of the period that scrolled at all called this
                       one.

  The gap between them is what a program could win by taking the documented
  shortcut, in microseconds, on this machine. Both are honest numbers; only
  one of them is what a fast program would have paid.

  One unit is two switches - out to the second bank and back. Alternating is
  the whole trick: a BIOS asked for the bank it is already showing is entitled
  to notice and return at once, and several do. Measured against one fixed
  position, this test would report the speed of a comparison.

  Not scored. It is a cost, so lower is better, while every constant in
  ATSCORE reads the other way; and it is missing entirely at the VGA end of
  the range, which would mark the Video category partial on exactly the
  machines that have nothing wrong with them. It is diagnosis, and it is
  reported as diagnosis.
  ---------------------------------------------------------------------------- }

interface

uses atharn, attime;

{$I at.inc}

const
  BankMode   = $0101;          { 640x480x8 - the one SVGA mode a VBE BIOS
                                 without any extensions still has to offer }
  BankFrame  = LongWord(640) * 480;

var
  BankTried  : Boolean;        { the phase was attempted at all }
  BankWhy    : String[38];     { empty, or why there is nothing to report }

  BankWinKb    : Word;         { size of the window the card exposes }
  BankGranKb   : Word;         { the units a window position is counted in }
  BankWinSeg   : Word;         { where it appears - A000h, usually }
  BankWinNo    : Byte;         { 0 = window A, 1 = window B }
  BankVerified : Boolean;      { the two banks were shown to be two }

  BankIntOk     : Boolean;
  BankIntRate   : LongWord;    { bank switches per second, through INT 10h }
  BankIntSpread : Word;

  BankDirOk     : Boolean;
  BankDirWhy    : String[38];
  BankDirRate   : LongWord;    { ... and through the window function }
  BankDirSpread : Word;

{ How many switches a full 640x480x8 frame costs, given this card's window. }
function  BankPerFrame: Word;

{ Sets the mode, measures, and puts the screen back the way it found it. }
procedure BankRun;

{ ------------------------------------------------------- using the mode }

{ The other reason to want 101h: drawing in it. The composite suite presents
  a 640x480 frame through the same window this unit measures, and the setting
  up - describe the mode, pick a window, work out its granularity, keep the
  pointer the BIOS handed out - is the same work either way. It lives here
  rather than being written twice, because two copies of a window selection
  would eventually disagree about which window this card can be driven by.

  BankOpen leaves the mode set and the screen unusable for text; the caller
  owns it until BankClose. Neither touches what BankRun measured. }
var
  BankOpenWhy : String[38];

  { True when the window can be read as well as written. A write-only window
    is enough to draw through and not enough to check the drawing. }
  BankWinReadable : Boolean;

function  BankOpen: Boolean;
procedure BankClose;

{ Whether this card's window call leaves the clock able to see it.

  ATTIME counts elapsed time out of IRQ0, so a BIOS that holds interrupts off
  across the switch is a BIOS whose switches take no measurable time at all -
  and anything built on the harness then doubles its workload for ever,
  looking for a duration it will never find. That is not a hypothetical: it is
  what happens under QEMU, and it is why the bank measurement above grows its
  own batch and keeps a CMOS witness.

  Whoever wants to *use* the mode - the composite suite presenting a frame -
  needs the same answer before it hands a window-moving kernel to the harness.
  It is that measurement, run once and reported as a yes or a no. }
function  BankTimerOk(var Why: String): Boolean;

{ Move the window. Through the pointer the BIOS published when there is one,
  and through INT 10h when there is not - the fast path is what a program of
  the period used, and here we are the program. }
procedure BankGoto(Pos: Word);

{ Window position showing byte Ofs of the frame, in granularity units, with
  the window placed on a multiple of its own size.

  Granularity and window size are two different numbers, and on most cards of
  the era they are 4 KB and 64 KB - so a position is not a window index and
  the two must not be mixed up. Aligning the window to its own size is what
  makes "the offset inside the window" simply Ofs mod the window size, which
  is what every caller wants to compute; positioning it finely would buy
  nothing here, since a frame is walked from its start. }
function  BankPosOf(Ofs: LongWord): Word;

implementation

uses atsys, atdbg;

const
  { A batch is grown until it lasts this long, and never past this many pairs.
    Both bounds are here because the clock cannot be trusted to end the loop -
    see BankMeasure. }
  BatchTicks   = 5 * TicksPerMs;
  { The cap only ever bites on the fast path: growth stops the moment a batch
    lasts BatchTicks, so a slow BIOS settles long before here. The window
    function on a quick card is a couple of microseconds a call, and 8192
    pairs of it is still only tens of milliseconds. }
  BatchMaxPair = 8192;
  Passes3      = 3;

var
  MiBuf    : array[0..255] of Byte;   { the VBE ModeInfoBlock }
  BankWin  : Word;      { BH=0 "set window", BL = which window - as one Word,
                          because that is how the kernels want it in BX }
  BankStep : Word;      { window position of the second bank }
  BankFunc : record Ofs, Seg: Word end;
  BankLoop : Word;
  OldMode  : Byte;

function MiWord(At: Word): Word;
begin
  MiWord := MiBuf[At] or (Word(MiBuf[At + 1]) shl 8);
end;

function CurrentMode: Byte; assembler;
asm
    mov ah, 0Fh
    int 10h
end;

procedure SetMode(Mode: Byte); assembler;
asm
    mov ah, 00h
    mov al, Mode
    int 10h
end;

function GetModeInfo: Boolean;
var Ok: Byte;
begin
  FillChar(MiBuf, SizeOf(MiBuf), 0);
  Ok := 0;
  asm
    push si
    push di
    push es
    mov  ax, ds
    mov  es, ax
    lea  di, MiBuf
    mov  ax, 4F01h
    mov  cx, BankMode
    int  10h
    cmp  ax, 004Fh
    jne  @@no
    mov  Ok, 1
  @@no:
    pop  es
    pop  di
    pop  si
  end;
  GetModeInfo := Ok = 1;
end;

function SetBankMode: Boolean;
var Ok: Byte;
begin
  Ok := 0;
  asm
    push si
    push di
    mov  ax, 4F02h
    mov  bx, BankMode
    int  10h
    { Before anything looks at the result: a mode set that came back with
      interrupts disabled leaves the clock stopped, and a stopped clock is
      indistinguishable from an infinitely fast machine. }
    sti
    cmp  ax, 004Fh
    jne  @@no
    mov  Ok, 1
  @@no:
    pop  di
    pop  si
  end;
  SetBankMode := Ok = 1;
end;

{ One switch, through the documented call, with its status checked. The
  kernels below do the same thing without checking, which is exactly what is
  being timed; this one is for setting things up. }
function SetWindow(Pos: Word): Boolean;
var Ok: Byte;
begin
  Ok := 0;
  asm
    push si
    push di
    mov  ax, 4F05h
    mov  bx, BankWin
    mov  dx, Pos
    int  10h
    cmp  ax, 004Fh
    jne  @@no
    mov  Ok, 1
  @@no:
    pop  di
    pop  si
  end;
  SetWindow := Ok = 1;
  { Every path out of the BIOS gets the clock checked back in. }
  TimerReassert;
end;

{ True when the two banks really are two. Marks the first byte of each, comes
  back, and expects both marks to have survived. A BIOS that quietly ignored
  the switch would have written both to the same byte - and a bank switch that
  does nothing is the one way this measurement could come out fast and mean
  nothing at all. }
function BanksDiffer: Boolean;
var A, B: Byte;
begin
  BanksDiffer := False;
  if not SetWindow(0) then Exit;
  Mem[BankWinSeg:0] := $A5;
  if not SetWindow(BankStep) then Exit;
  Mem[BankWinSeg:0] := $5A;
  if not SetWindow(0) then Exit;
  A := Mem[BankWinSeg:0];
  if not SetWindow(BankStep) then Exit;
  B := Mem[BankWinSeg:0];
  BanksDiffer := (A = $A5) and (B = $5A);
end;

{ ----------------------------------------------------------------- kernels }

{ The counter lives in memory, not in a register, because what runs between
  two of its decrements is somebody else's code. VBE promises the call
  preserves everything but AX; the window function promises rather less, and
  a card whose window code is a few instructions of its own invention is
  precisely the kind of thing this test exists to find. DS is pushed for the
  same reason and popped back before the counter is touched. }

procedure KBankInt(Units: Word); assembler;
asm
    push si
    push di
    push bp
    mov  ax, Units
    mov  BankLoop, ax
    or   ax, ax
    jz   @@x
  @@loop:
    push ds
    push es
    mov  ax, 4F05h
    mov  bx, BankWin
    xor  dx, dx
    int  10h
    pop  es
    pop  ds
    push ds
    push es
    mov  ax, 4F05h
    mov  bx, BankWin
    mov  dx, BankStep
    int  10h
    pop  es
    pop  ds
    dec  word ptr BankLoop
    jnz  @@loop
  @@x:
    pop  bp
    pop  di
    pop  si
end;

{ The same two switches through the far pointer the BIOS handed out. No status
  comes back - there is nothing to check and nothing to check it with, which
  is half of why it is quicker. }
procedure KBankDir(Units: Word); assembler;
asm
    push si
    push di
    push bp
    mov  ax, Units
    mov  BankLoop, ax
    or   ax, ax
    jz   @@x
  @@loop:
    push ds
    push es
    mov  bx, BankWin
    xor  dx, dx
    call far [BankFunc]
    pop  es
    pop  ds
    push ds
    push es
    mov  bx, BankWin
    mov  dx, BankStep
    call far [BankFunc]
    pop  es
    pop  ds
    dec  word ptr BankLoop
    jnz  @@loop
  @@x:
    pop  bp
    pop  di
    pop  si
end;

{ ------------------------------------------------------------- the measure }

{ The harness is not used here, and for a reason worth stating: it is the only
  kernel in the suite that hands the CPU to somebody else's code, and that code
  is entitled to hold interrupts off. ATTIME counts elapsed time out of IRQ0
  ticks plus the counter inside the current period, so a stretch that eats the
  interrupt is a stretch the clock cannot see: every reading comes back smaller
  than one period, whatever the work. The harness reads that as "still too
  fast" and doubles the work, and doubles it again, up to 32768 units of a
  kernel that is in fact the slowest thing it will ever run. Under QEMU that is
  a quarter of an hour of bank switching and no number at the end of it.

  So: a batch grown until it lasts a few milliseconds, three passes, keep the
  fastest - the same shape as the harness, minus the assumption it rests on -
  and a second clock that does not depend on interrupts being delivered at all
  to say whether the first one was telling the truth. }

{ Seconds off the CMOS clock, 0..59, or 255 when the register is unreadable.
  Reg 0Ah bit 7 says the chip is mid-update and the time bytes are in flux;
  waiting it out costs at most a microsecond or two. The RTC counts on its own
  crystal and is not touched by whether anybody serviced an interrupt, which
  is exactly the property wanted here. }
function RtcSec: Byte;
var V, Busy: Byte; Guard: Word;
begin
  Guard := 0;
  repeat
    asm
      pushf
      cli
      mov al, 0Ah
      out 70h, al
      jmp @@d
    @@d:
      in  al, 71h
      and al, 80h
      mov Busy, al
      popf
    end;
    Inc(Guard);
  until (Busy = 0) or (Guard > 10000);
  if Busy <> 0 then begin RtcSec := 255; Exit end;
  { Interrupts off across the index/data pair: port 70h is a single register
    shared with anybody else who reads the CMOS, and a handler that lands
    between the out and the in leaves this reading whatever it asked for. }
  asm
    pushf
    cli
    mov al, 00h
    out 70h, al
    jmp @@d2
  @@d2:
    in  al, 71h
    mov V, al
    mov al, 0Bh
    out 70h, al
    jmp @@d3
  @@d3:
    in  al, 71h
    and al, 04h
    mov Busy, al
    popf
  end;
  { BCD unless the status register just said binary. }
  if Busy = 0 then V := (V shr 4) * 10 + (V and 15);
  if V > 59 then V := 255;
  RtcSec := V;
end;

{ Seconds from S to now, over the minute wrap. 0 when either reading failed:
  a witness that cannot speak does not get to accuse. }
function RtcSince(S: Byte): Word;
var N: Byte;
begin
  RtcSince := 0;
  if S = 255 then Exit;
  N := RtcSec;
  if N = 255 then Exit;
  if N >= S then RtcSince := N - S else RtcSince := 60 - S + N;
end;

function TimeBatch(K: TKernel; Pairs: Word): TStamp;
var T0, T1: TStamp;
begin
  T0 := Stamp;
  K(Pairs);
  T1 := Stamp;
  TimeBatch := StampDiff(T0, T1);
end;

function BankMeasure(K: TKernel; var Rate: LongWord; var SpreadPc: Word;
                     var Why: String): Boolean;
var
  Pairs        : Word;
  T, Best, Worst, Total : TStamp;
  P            : Integer;
  S0           : Byte;
  Secs, Zeros  : Word;
begin
  BankMeasure := False;
  Rate := 0; SpreadPc := 0; Why := '';

  S0 := RtcSec;
  Pairs := 8;
  repeat
    T := TimeBatch(K, Pairs);
    if T >= LongWord(BatchTicks) then Break;
    if Pairs >= BatchMaxPair then Break;
    { The stamp says there is time to spare and the RTC says there is not.
      One of them is wrong, and it is not the one with its own crystal. }
    if RtcSince(S0) >= 2 then Break;
    Pairs := Pairs * 2;
  until False;

  Best := $FFFFFFFF; Worst := 0; Total := 0; Zeros := 0;
  for P := 1 to Passes3 do
  begin
    T := TimeBatch(K, Pairs);
    Total := Total + T;
    if T = 0 then Inc(Zeros);
    if T < Best then Best := T;
    if T > Worst then Worst := T;
    if EscPressed then
    begin
      BenchAborted := True;
      Why := 'cancelled';
      Exit;
    end;
  end;

  { A pass that came back as no time at all. Two very different things look
    like this, and telling them apart is the whole point of counting them:
    every pass at zero is a batch genuinely under the timer's resolution,
    while some passes at zero and some not is a clock that stopped - ATTIME
    refuses to run backwards, so a stamp taken after lost ticks is pinned to
    the previous one and the difference comes out exactly zero. }
  if Best = 0 then
  begin
    if Zeros >= Passes3 then Why := 'too fast for this timer'
    else Why := 'clock stops in the BIOS call';
    Exit;
  end;

  { The witness. Everything above is bounded to a few milliseconds a batch, so
    the whole measurement owes the wall clock well under a second. If the RTC
    has counted seconds that the stamps cannot account for, then IRQ0 went
    missing inside the BIOS call - and the fast figure the stamps imply is a
    fiction built out of a clock that stopped. Said plainly rather than
    reported. }
  Secs := RtcSince(S0);
  if (Secs >= 2) and (StampMs(Total) < LongWord(Secs) * 250) then
  begin
    Why := 'BIOS call loses clock ticks';
    Exit;
  end;

  Rate := RateOf(LongWord(Pairs) * 2, Best);
  SpreadPc := Word(((Worst - Best) * 100) div Best);
  BankMeasure := True;
end;

{ ----------------------------------------------------------------- driving }

function BankPerFrame: Word;
var WinBytes, N: LongWord;
begin
  BankPerFrame := 0;
  if BankWinKb = 0 then Exit;
  WinBytes := LongWord(BankWinKb) * 1024;
  N := (BankFrame + WinBytes - 1) div WinBytes;
  if N > 0 then Dec(N);
  BankPerFrame := Word(N);
end;

{ Which window to drive. Readable as well as writable is worth going out of
  the way for: a window that can only be written cannot be checked, and an
  unchecked measurement of a switch that may not be happening is the one
  result this unit must not report as though it were solid. }
function PickWindow: Boolean;
var A, B: Byte;
begin
  A := MiBuf[2];
  B := MiBuf[3];
  PickWindow := True;
  BankVerified := True;
  if (A and 7) = 7 then BankWinNo := 0
  else if (B and 7) = 7 then BankWinNo := 1
  else
  begin
    BankVerified := False;
    if (A and 5) = 5 then BankWinNo := 0
    else if (B and 5) = 5 then BankWinNo := 1
    else PickWindow := False;
  end;
  if BankWinNo = 0 then BankWinSeg := MiWord(8) else BankWinSeg := MiWord(10);
  BankWin := BankWinNo;                    { BH stays 0: "set the window" }
  if BankWinSeg = 0 then PickWindow := False;
end;

procedure Reset;
begin
  BankWhy := '';
  BankWinKb := 0; BankGranKb := 0; BankWinSeg := 0; BankWinNo := 0;
  BankVerified := False;
  BankIntOk := False; BankIntRate := 0; BankIntSpread := 0;
  BankDirOk := False; BankDirRate := 0; BankDirSpread := 0;
  BankDirWhy := '';
  BankStep := 1;
  BankFunc.Ofs := 0; BankFunc.Seg := 0;
end;

procedure BankRun;
var W: String;
begin
  BankTried := True;
  Reset;

  { A skipped probe is not an absent feature (DESIGN 13.6), so /safe says so
    in as many words rather than letting the line read "no VBE BIOS". }
  if SafeProbe then
  begin
    BankWhy := 'VBE probe skipped by /safe';
    Exit;
  end;
  if not VbeOk then begin BankWhy := 'no VBE BIOS'; Exit end;
  Dbg('bank: 4F01h mode info');
  if not GetModeInfo then begin BankWhy := 'mode 101h not described'; Exit end;

  if (MiWord(0) and 1) = 0 then
  begin
    BankWhy := 'mode 101h not supported by the card';
    Exit;
  end;

  BankGranKb := MiWord(4);
  BankWinKb  := MiWord(6);
  BankFunc.Ofs := MiWord(12);
  BankFunc.Seg := MiWord(14);

  { A mode reached only through a linear frame buffer reports no granularity,
    and in real mode that is the end of the road - the aperture lives above
    the megabyte, where nothing here can address it. Said plainly, because on
    a late PCI card it is the answer rather than a failure. }
  if (BankGranKb = 0) or (BankWinKb = 0) then
  begin
    BankWhy := 'mode is linear only; no real-mode window';
    Exit;
  end;
  if not PickWindow then
  begin
    BankWhy := 'no CPU-addressable window';
    Exit;
  end;

  { The second bank has to be memory the card actually has, or the switch to
    it measures a BIOS refusing. }
  if (VbeMemKb <> 0) and (LongWord(BankWinKb) * 2 > VbeMemKb) then
  begin
    BankWhy := 'window covers all of video memory';
    Exit;
  end;

  BankStep := BankWinKb div BankGranKb;
  if BankStep = 0 then BankStep := 1;

  Dbg('bank: 4F02h set 101h');
  OldMode := CurrentMode;
  if not SetBankMode then
  begin
    TimerReassert;
    BankWhy := 'mode 101h would not set';
    Exit;
  end;
  TimerReassert;

  Dbg('bank: verify');
  if BankVerified and (not BanksDiffer) then
  begin
    SetMode(OldMode and $7F);
    TimerReassert;
    BankWhy := 'the two banks read as the same memory';
    Exit;
  end;

  Dbg('bank: INT 10h kernel');
  BankIntOk := BankMeasure(@KBankInt, BankIntRate, BankIntSpread, W);
  { Thousands of BIOS calls have just run, and whether interrupts came back
    from the last of them is exactly the question this unit exists to raise. }
  TimerReassert;
  Dbg('bank: INT 10h done');
  if not BankIntOk then BankWhy := W;

  if (BankFunc.Seg = 0) and (BankFunc.Ofs = 0) then
    BankDirWhy := 'BIOS published no window function'
  else
  begin
    Dbg('bank: window function kernel');
    BankDirOk := BankMeasure(@KBankDir, BankDirRate, BankDirSpread, W);
    TimerReassert;
    Dbg('bank: window function done');
    if not BankDirOk then BankDirWhy := W;
  end;

  Dbg('bank: mode restore');
  SetMode(OldMode and $7F);
  TimerReassert;
end;

{ ------------------------------------------------------- using the mode }

var
  OpenOldMode : Byte;
  OpenOn      : Boolean;

{ Deliberately does not touch BankVerified or anything else the measurement
  above reports: a window good enough to draw through is a weaker requirement
  than one good enough to time a switch on, and the two must not be confused
  in the report. }
function BankOpen: Boolean;
var A, B: Byte;
begin
  BankOpen := False;
  BankOpenWhy := '';
  if OpenOn then begin BankOpen := True; Exit end;

  if SafeProbe then
  begin BankOpenWhy := 'VBE probe skipped by /safe'; Exit end;
  if not VbeOk then begin BankOpenWhy := 'no VBE BIOS'; Exit end;
  if not GetModeInfo then
  begin BankOpenWhy := 'mode 101h not described'; Exit end;
  if (MiWord(0) and 1) = 0 then
  begin BankOpenWhy := 'mode 101h not supported by the card'; Exit end;

  BankGranKb   := MiWord(4);
  BankWinKb    := MiWord(6);
  BankFunc.Ofs := MiWord(12);
  BankFunc.Seg := MiWord(14);
  if (BankGranKb = 0) or (BankWinKb = 0) then
  begin BankOpenWhy := 'mode is linear only; no real-mode window'; Exit end;

  { Writable is enough here. The measurement insists on a window it can also
    read back, because a switch that quietly did nothing would otherwise look
    infinitely fast; drawing has no such problem. }
  A := MiBuf[2];
  B := MiBuf[3];
  if (A and 5) = 5 then BankWinNo := 0
  else if (B and 5) = 5 then BankWinNo := 1
  else begin BankOpenWhy := 'no CPU-addressable window'; Exit end;
  if BankWinNo = 0 then
  begin
    BankWinSeg := MiWord(8);
    BankWinReadable := (A and 2) <> 0;
  end
  else
  begin
    BankWinSeg := MiWord(10);
    BankWinReadable := (B and 2) <> 0;
  end;
  BankWin := BankWinNo;
  { The kernels that measure a switch move between position 0 and this one,
    and BankRun may never have run to work it out. }
  BankStep := BankWinKb div BankGranKb;
  if BankStep = 0 then BankStep := 1;
  if BankWinSeg = 0 then
  begin BankOpenWhy := 'window has no real-mode address'; Exit end;

  OpenOldMode := CurrentMode;
  if not SetBankMode then
  begin
    TimerReassert;
    BankOpenWhy := 'mode 101h would not set';
    Exit;
  end;
  TimerReassert;

  OpenOn := True;
  BankOpen := True;
end;

procedure BankClose;
begin
  if not OpenOn then Exit;
  OpenOn := False;
  SetMode(OpenOldMode and $7F);
  TimerReassert;
end;

{ One switch, no status checked - which is what the period's own code did, and
  what the direct kernel above measures. }
{ The STI at the end is not tidiness, it is the clock.

  ATTIME counts elapsed time out of IRQ0, so code that returns with interrupts
  disabled does not slow the clock down - it stops it. Everything measured
  afterwards then comes back as no time at all, the harness reads that as "too
  fast to time", and the whole suite reports nothing while looking like it ran.
  That is what a VBE BIOS did here, and a card's own window routine is under
  even less obligation to be careful than the BIOS is.

  Putting interrupts back is also what a program of the period did after
  calling into a card's window code, so it costs the measurement one clock and
  nothing in realism. }
procedure WinDirect(Pos: Word); assembler;
asm
    push si
    push di
    push bp
    push ds
    push es
    mov  bx, BankWin
    mov  dx, Pos
    call far [BankFunc]
    pop  es
    pop  ds
    pop  bp
    pop  di
    pop  si
    sti
end;

procedure WinInt(Pos: Word); assembler;
asm
    push si
    push di
    push bp
    push ds
    push es
    mov  ax, 4F05h
    mov  bx, BankWin
    mov  dx, Pos
    int  10h
    pop  es
    pop  ds
    pop  bp
    pop  di
    pop  si
    sti
end;

procedure BankGoto(Pos: Word);
begin
  if (BankFunc.Seg <> 0) or (BankFunc.Ofs <> 0) then WinDirect(Pos)
  else WinInt(Pos);
end;

function BankTimerOk(var Why: String): Boolean;
var Rate: LongWord; Sp: Word;
begin
  Why := '';
  if not OpenOn then
  begin
    BankTimerOk := False;
    Why := 'the mode is not open';
    Exit;
  end;
  { Whichever way the window will actually be moved is the way to ask. }
  if (BankFunc.Seg <> 0) or (BankFunc.Ofs <> 0) then
    BankTimerOk := BankMeasure(@KBankDir, Rate, Sp, Why)
  else
    BankTimerOk := BankMeasure(@KBankInt, Rate, Sp, Why);
end;

function BankPosOf(Ofs: LongWord): Word;
var Win, Steps: LongWord;
begin
  BankPosOf := 0;
  if (BankGranKb = 0) or (BankWinKb = 0) then Exit;
  Win   := LongWord(BankWinKb) * 1024;
  Steps := BankWinKb div BankGranKb;
  if Steps = 0 then Steps := 1;
  BankPosOf := Word((Ofs div Win) * Steps);
end;

begin
  OpenOn := False;
  BankOpenWhy := '';
  BankWinReadable := False;
  BankTried := False;
  Reset;
end.
