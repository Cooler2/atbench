unit attime;
{ ----------------------------------------------------------------------------
  ATBench - the clock everything else is built on.

  Requirements it has to satisfy: run on a 286 (so no RDTSC), never touch the
  FPU, resolve far better than the 55 ms BIOS tick, and leave the DOS
  time-of-day correct afterwards.

  PIT channel 0 is reprogrammed to mode 2 with a reload value of 4096, giving
  1193182/4096 = 291.3 interrupts per second. Our INT 08h handler counts them
  and hands control to the original handler on every 16th tick - and 291.3/16
  is exactly the stock 18.206 Hz, so the BIOS tick count and the DOS clock
  advance at precisely the right rate. No SetTime fixup afterwards, which is
  what the old benchmarks needed because they ran the PIT at 100 Hz.

  Sub-tick resolution comes from latching the counter itself, so a timestamp
  is good to about a microsecond. Because the counter can wrap between the
  latch and the moment the ISR runs, the master PIC's IRR is checked in the
  same interrupts-off window and a whole period added when IRQ0 is pending.

  Timestamps are unsigned and are meant to wrap; always take differences with
  StampDiff, which wraps correctly. One wrap takes about an hour.
  ---------------------------------------------------------------------------- }

interface

uses dos;

{$I at.inc}

const
  PitInHz    = 1193182;   { PIT input clock, Hz }
  PitDiv     = 4096;      { our reload value  -> 291.27 Hz }
  ChainEvery = 16;        { 291.27/16 = 18.206 Hz, the stock BIOS rate }

type
  TStamp = LongWord;      { PIT ticks, 0.8381 us each, wraps after ~1 hour }

var
  TimerOn: Boolean;

  { False when IRQ0 never reached our handler. The counter can be running
    perfectly while the interrupt it raises never arrives - a BIOS that runs
    the keyboard out of SMM, a TSR that hooks INT 08h and forgets to chain,
    an EMM386 that declines to reflect the interrupt back down. Nothing can
    be measured in that state: Ticks stands still, every timestamp saturates
    against the last one, and every wait for time to pass becomes a wait for
    something that will never happen. So it is answered once, here, and
    callers check it instead of hanging - see BeginRun. }
  TimerIrqOk: Boolean;

procedure TimerInstall;
procedure TimerRemove;

{ Puts the clock back together after somebody else's code has run.

  A video BIOS is entitled to disable interrupts and to return without
  enabling them again, and at least one does. What that costs here is not
  accuracy, it is the clock: Ticks stops advancing, every timestamp saturates
  against the last one (see Stamp's last line of defence), and every interval
  measured afterwards comes back as zero. The harness reads zero as "still too
  fast to time" and doubles its workload, so a whole suite reports nothing at
  all while appearing to have run - which is exactly how this was found.

  The same call also writes our reload value back, since a BIOS that wants a
  delay loop is equally entitled to reprogram the counter it finds.

  It does not wait for the new period to settle, unlike TimerInstall: this is
  called on a machine that may have no interrupts at the time, and a wait for
  a tick that cannot arrive is a hang. One timestamp taken across the change
  may be off by up to a period, which matters nowhere - it happens between
  measurements, never inside one, and the harness keeps the fastest pass. }
procedure TimerReassert;

function  Stamp: TStamp;
function  StampDiff(FromS, ToS: TStamp): TStamp;

{ The counter latched and read raw, with none of Stamp's continuity
  bookkeeping and no dependence on the ISR having run. It advances whether or
  not IRQ0 is delivered to us, which is what makes it the one clock in here
  that can be trusted to watch the others. }
function  PitCount: Word;

{ Waits for D ticks to pass. False means the clock stopped advancing before
  they did, and the caller has to give up rather than wait forever: a wait
  for a tick that cannot arrive is a hang, and this unit is the only one in a
  position to tell the difference. }
function  StampWait(D: TStamp): Boolean;

function  StampUs(D: TStamp): LongWord;
function  StampMs(D: TStamp): LongWord;
function  StampNs(D: TStamp): LongWord;

{ Raw BIOS tick counter at 0040:006C - untouched by us, so it doubles as an
  independent witness that our clock keeps honest time. }
function  BiosTicks: LongWord;

implementation

const
  { Watchdog limits for the install-time wait. 64 periods of 3.43 ms is 220
    ms - two orders of magnitude more than the two ticks being waited for, so
    it can only expire on a machine where those ticks are not coming. The
    iteration cap underneath catches the other failure, a counter that is not
    running either, and is set high enough that it can never expire first: a
    latch-and-read pair costs microseconds even on a 286. }
  PitWatchPeriods = 64;
  PitWatchIters   = 400000;

  { Consecutive identical timestamps that mean the clock has stopped. Stamp
    saturates rather than let time run backwards, so a stalled clock reads as
    the same number over and over; a live one cannot, because one call to
    Stamp takes longer than a tick on every machine this runs on. }
  StampIdleMax    = 100000;

var
  OldInt8  : FarPointer;
  Ticks    : LongWord;
  ChainCt  : Word;
  PrevExit : FarPointer;

  { Carried across calls to Stamp so that a period boundary can be recognised
    even when the interrupt controller cannot tell us about it - see Stamp. }
  LastTicks : LongWord;
  LastC     : Word;
  Carried   : Boolean;
  LastStamp : TStamp;

{ ------------------------------------------------------------------ the ISR }

procedure TimerIsr; interrupt;
begin
  Inc(Ticks);
  Inc(ChainCt);
  if ChainCt >= ChainEvery then
  begin
    ChainCt := 0;
    { Hand over to the BIOS handler as if this were a real INT 08h: it will
      update the tick count, call INT 1Ch and issue the EOI for us. }
    asm
      pushf
      call far [OldInt8]
    end;
  end
  else
    { Our own tick - nobody else will acknowledge the interrupt controller. }
    asm
      mov al, 20h
      out 20h, al
    end;
end;

{ ------------------------------------------------------------- install/remove }

procedure SetPit(Divisor: Word); assembler;
asm
    mov  al, 34h          { channel 0, access lo/hi, mode 2, binary }
    out  43h, al
    mov  ax, Divisor
    out  40h, al
    mov  al, ah
    out  40h, al
end;

procedure TimerInstall;
var
  T            : LongWord;
  Guard, Wraps : LongWord;
  C, PrevC     : Word;
begin
  if TimerOn then Exit;
  Ticks     := 0;
  ChainCt   := 0;
  LastTicks := 0;
  LastC     := PitDiv;
  Carried   := False;
  LastStamp := 0;
  GetIntVec($08, OldInt8);
  asm cli end;
  SetIntVec($08, @TimerIsr);
  SetPit(PitDiv);
  asm sti end;
  TimerOn := True;

  { A new reload value only takes effect at the end of the period already in
    progress, and the BIOS period is the full 55 ms. Wait for two of our own
    ticks so that no timestamp is ever taken while the counter is still
    sweeping the old, much larger range.

    The wait is watched, because on some machines it is a wait for two ticks
    that never arrive - and an unwatched one is indistinguishable from a dead
    computer at the exact moment the user pressed a key to start a benchmark.
    What watches it is the counter itself, read directly: it runs whether or
    not the interrupt reaches us, so counting the periods it completes
    measures real time even while Ticks stands still. }
  T     := Ticks;
  Guard := 0;
  Wraps := 0;
  PrevC := PitCount;
  TimerIrqOk := False;
  while Guard < LongWord(PitWatchIters) do
  begin
    if Ticks - T >= 2 then
    begin
      TimerIrqOk := True;
      Break;
    end;
    { Within a period the counter only falls, so a reading above the previous
      one is a period boundary. Reading it through a call is also what keeps
      Ticks out of a register for the length of the loop. }
    C := PitCount;
    if C > PrevC then
    begin
      Inc(Wraps);
      if Wraps > PitWatchPeriods then Break;
    end;
    PrevC := C;
    Inc(Guard);
  end;
end;

procedure TimerReassert;
begin
  if not TimerOn then Exit;
  asm cli end;
  SetPit(PitDiv);
  { The continuity state describes a counter that no longer exists. }
  LastC   := PitDiv;
  Carried := False;
  asm sti end;
end;

procedure TimerRemove;
begin
  if not TimerOn then Exit;
  asm cli end;
  SetPit(0);                  { 0 means 65536: back to the stock 18.2 Hz }
  SetIntVec($08, OldInt8);
  asm sti end;
  TimerOn := False;
end;

{ --------------------------------------------------------------- timestamps }

function Stamp: TStamp;
var
  T     : LongWord;
  C     : Word;
  Pend  : Byte;
  Carry : LongWord;
begin
  asm
    pushf
    cli

    { latch counter 0 and read it lo, hi }
    mov  al, 0
    out  43h, al
    in   al, 40h
    mov  bl, al
    jmp  @@d1                 { I/O settling delay for fast CPUs }
  @@d1:
    in   al, 40h
    mov  bh, al
    mov  C, bx

    { is IRQ0 already asserted but not yet serviced? }
    mov  al, 0Ah              { OCW3: read IRR }
    out  20h, al
    jmp  @@d2
  @@d2:
    in   al, 20h
    and  al, 1
    mov  Pend, al

    { snapshot the tick counter in the same interrupts-off window }
    mov  ax, word ptr Ticks
    mov  dx, word ptr Ticks+2
    mov  word ptr T, ax
    mov  word ptr T+2, dx

    popf
  end;

  { Right after installation the counter can still be ranging over the BIOS
    reload value of 65536; TimerInstall waits that out, but clamp anyway
    rather than let PitDiv-C underflow into four billion ticks. }
  if C > PitDiv then
    C := PitDiv;

  { --- deciding whether Ticks is one period behind -----------------------

    Elapsed within a period is PitDiv-C, so the whole timestamp is
    Ticks*PitDiv + (PitDiv-C). That is only right if the ISR has already
    counted every period that has completed. Around a period boundary it
    has not, and there are two distinct windows to catch:

      1. IRQ0 asserted, interrupt not yet dispatched. The controller still
         shows it in its request register, so Pend tells us. C is near
         PitDiv because the counter has just reloaded - which is what
         distinguishes this from IRQ0 firing in the microseconds *after* we
         latched, where C is near zero and no period is owed.

      2. The interrupt has been dispatched but our handler has not reached
         Inc(Ticks) yet. The request bit is already cleared, so the
         controller can no longer tell us anything at all. This window is
         only a handful of instructions wide, yet it accounted for 44
         backwards steps in 20000 reads - and a backwards step is fatal,
         because an unsigned difference turns it into four billion ticks and
         every waiting loop exits at once.

    Window 2 is caught by remembering the previous reading instead of asking
    the hardware: within one period C only ever decreases, so if C has gone
    *up* while Ticks stood still, a boundary was crossed that the ISR has yet
    to account for. The carry is then held until Ticks does advance. This
    needs Stamp to be called more than once per period, which is exactly the
    case where sub-period accuracy matters; for occasional calls window 1
    covers it and a residual one-period slip is 3.4 ms against an interval of
    hundreds of ms. }
  Carry := 0;
  if T <> LastTicks then
    Carried := False
  else if Carried or (C > LastC) then
    Carry := 1;

  if (Carry = 0) and (Pend <> 0) and (C > PitDiv div 2) then
    Carry := 1;

  LastTicks := T;
  LastC     := C;
  Carried   := Carry <> 0;

  T := (T + Carry) * PitDiv + (PitDiv - LongWord(C));

  { Last line of defence. Nothing downstream is prepared for time to run
    backwards, and the cost of being sure is one comparison. }
  if T < LastStamp then
    T := LastStamp;
  LastStamp := T;

  Stamp := T;
end;

function StampDiff(FromS, ToS: TStamp): TStamp;
begin
  StampDiff := ToS - FromS;    { unsigned, wraps correctly }
end;

function PitCount: Word; assembler;
asm
    pushf
    push bx
    cli
    mov  al, 0                { latch counter 0 }
    out  43h, al
    in   al, 40h
    mov  bl, al
    jmp  @@d1                 { I/O settling delay for fast CPUs }
  @@d1:
    in   al, 40h
    mov  bh, al
    mov  ax, bx
    pop  bx
    popf
end;

function StampWait(D: TStamp): Boolean;
var
  T0, T1, Prev : TStamp;
  Idle         : LongWord;
begin
  T0   := Stamp;
  Prev := T0;
  Idle := 0;
  repeat
    T1 := Stamp;
    if T1 = Prev then
    begin
      Inc(Idle);
      if Idle > LongWord(StampIdleMax) then
      begin
        StampWait := False;
        Exit;
      end;
    end
    else
    begin
      Idle := 0;
      Prev := T1;
    end;
  until StampDiff(T0, T1) >= D;
  StampWait := True;
end;

{ 1 PIT tick = 1e6/1193182 us = 0.8380953 us.
  3433/4096 = 0.8381348, which is 0.005% high - two orders of magnitude below
  our measurement noise. Splitting the multiply keeps it inside 32 bits. }
function StampUs(D: TStamp): LongWord;
begin
  StampUs := (D shr 12) * 3433 + (((D and 4095) * 3433) shr 12);
end;

function StampMs(D: TStamp): LongWord;
begin
  StampMs := StampUs(D) div 1000;
end;

{ Nanoseconds, for the short deltas where microseconds round to nothing -
  cache latencies and the cost of the timestamp itself. 838 ns per tick is
  0.011% low. Overflows past ~5.1M ticks (4.3 s), which is far beyond
  anything worth expressing in nanoseconds. }
function StampNs(D: TStamp): LongWord;
begin
  if D > 5000000 then
    StampNs := $FFFFFFFF
  else
    StampNs := D * 838;
end;

function BiosTicks: LongWord;
begin
  BiosTicks := MemL[$0040:$006C];
end;

{ ------------------------------------------------------------------ shutdown }

procedure TimerExit;
begin
  ExitProc := PrevExit;
  TimerRemove;
end;

begin
  TimerOn    := False;
  TimerIrqOk := False;
  PrevExit := ExitProc;
  ExitProc := @TimerExit;
end.
