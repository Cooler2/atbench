unit atharn;
{ ----------------------------------------------------------------------------
  ATBench - the measurement harness.

  This is what makes one binary meaningful on both a 6 MHz 286 and a 233 MHz
  Pentium MMX. Nothing in the suite ever runs a fixed number of iterations;
  the harness works out how much work fits in a fixed amount of *time*, and
  reports a rate. The old benchmarks did the opposite, which is why they took
  minutes on a 286 and finished before you noticed on a K6-2.

  A kernel is a procedure taking a unit count. What one "unit" means is the
  kernel's business - a loop iteration, a kilobyte moved, a pixel drawn - and
  the caller converts the resulting units/second into a physical metric.

  Three phases:

    calibrate  Start at one unit and double until one call takes longer than
               CalMinMs. Units per call is capped at 32768 so the doubling
               never leaves a Word; past that point the harness scales by
               calling more often instead.

               Starting at one matters for the heavy kernels. A memory test
               whose unit is a pass over a 512 KB working set takes half a
               second per unit on a 286 - beginning at 64 would have spent
               half a minute on the first calibration call alone. Starting
               low costs a cheap kernel about a dozen extra calls, each of
               which is by definition shorter than CalMinMs.

    measure    Compute how many calls fill one pass - MeasureMs unless the
               caller asked for a length of its own, see RunBenchFor - then
               run them grouped into chunks of about ChunkMs. Between
               chunks - never inside one - the harness checks for ESC and
               against the abort budget. So no single stretch of
               uninterruptible work lasts longer than a chunk, which is what
               keeps the program responsive and makes a runaway test
               impossible.

    repeat     Passes runs, and both statistics are kept: the fastest pass,
               and the total of all of them.

               The minimum is the honest figure for a kernel that does the
               same work every time it is called. What varies between its
               passes is interference - interrupts, DRAM refresh, SMI - and
               interference can only ever add time, never remove it, so the
               fastest pass is the one that saw the least of it and is the
               best estimate of what the machine can do.

               That argument fails when the passes do not do the same work.
               The composite frame kernels draw a different frame every time
               round, and how long a frame takes depends on what is in it -
               the rotozoom's texture walk is dense along one angle and a
               cache line a pixel at another - so their spread is the picture
               and not the noise. Taking the minimum there answers a question
               nobody asked: the frame rate of the cheapest frame in the
               cycle. Those tests use the totals instead, which give the mean
               weighted by time, and attcmp is the only caller that does.

               The spread between best and worst is kept either way as a
               quality signal - for the first kind it means something else
               was running and the number deserves suspicion, and for the
               second it is a real property of the animation. Both are worth
               printing; neither is worth silently averaging into.
  ---------------------------------------------------------------------------- }

interface

uses attime;

{$I at.inc}

type
  TKernel = procedure(Units: Word);

  TBenchResult = record
    Ok       : Boolean;    { the number below is worth reporting }
    Aborted  : Boolean;    { user pressed ESC }
    TooFast  : Boolean;    { never rose above the timer noise floor }
    Overrun  : Boolean;    { hit the abort budget }
    Units    : LongWord;   { units executed during the best pass }
    Ticks    : TStamp;     { duration of that pass, PIT ticks }
    Us       : LongWord;
    { Every completed pass, added up. Units over Ticks is then the mean rate
      weighted by time, which is what a kernel whose passes differ in content
      has to be read by - see the note on 'repeat' above. }
    AllUnits : LongWord;
    AllTicks : TStamp;
    AllUs    : LongWord;
    SpreadPc : Word;       { (worst-best)*100/best }
    Rate     : LongWord;   { units per second }
  end;

const
  TicksPerMs  = 1193;      { PIT ticks in a millisecond }

  CalMinMs    = 25;        { calibration is done once a call exceeds this }
  ChunkMs     = 50;        { longest uninterruptible stretch }
  MeasureMs   = 250;       { target duration of one pass }
  AbortMs     = 8000;      { hard ceiling; past this the test is abandoned }
  Passes      = 3;

  MaxUnits    = 32768;     { cap on units per call, keeps doubling in a Word }

var
  { Sticky: once the user has pressed ESC every later test bails out at once,
    so a whole suite can be cancelled with a single keypress. }
  BenchAborted : Boolean;

function  RunBench(K: TKernel): TBenchResult;

{ The same, with a pass of the caller's own length. There is one reason to ask
  for a longer one and it is not accuracy: the composite suite draws its frame
  on the screen, and a pass short enough to measure a frame is far too short to
  see one. A quarter of a second of animation reads as a flicker of unrelated
  pictures, so the frame tests ask for a few seconds and the person in front of
  the machine gets something to look at for the price of a better sample.

  The abort budget is deliberately not a parameter. It is what protects a slow
  machine from spending an afternoon on one row, and a caller in the mood to
  watch its own animation is exactly the caller that should not be raising it. }
function  RunBenchFor(K: TKernel; MsPerPass: LongWord): TBenchResult;

{ units/second from a unit count and a duration, without overflowing }
function  RateOf(Units: LongWord; Ticks: TStamp): LongWord;

{ Non-blocking ESC test, straight through the BIOS - no CRT dependency and
  nothing that could misbehave on an unusual keyboard controller. }
function  EscPressed: Boolean;

implementation

function EscPressed: Boolean;
var
  Hit: Byte;
  Key: Word;
begin
  Hit := 0;
  asm
    mov  ah, 1
    int  16h
    jz   @@none
    mov  Hit, 1
  @@none:
  end;
  EscPressed := False;
  if Hit = 0 then Exit;
  asm
    mov  ah, 0
    int  16h
    mov  Key, ax
  end;
  if (Key and $FF) = 27 then
  begin
    EscPressed := True;
    BenchAborted := True;
  end;
end;

function RateOf(Units: LongWord; Ticks: TStamp): LongWord;
begin
  if (Ticks = 0) or (Units = 0) then
    RateOf := 0
  else
    RateOf := LongWord((Int64(Units) * PitInHz) div Int64(Ticks));
end;

{ One timed call. Returns the elapsed PIT ticks. }
function TimeCall(K: TKernel; Units: Word): TStamp;
var
  T0, T1: TStamp;
begin
  T0 := Stamp;
  K(Units);
  T1 := Stamp;
  TimeCall := StampDiff(T0, T1);
end;

function RunBenchFor(K: TKernel; MsPerPass: LongWord): TBenchResult;
var
  R              : TBenchResult;
  UnitsPerCall   : Word;
  T              : TStamp;
  TicksPerCall   : TStamp;
  CallsTotal     : LongWord;
  CallsPerChunk  : LongWord;
  Done           : LongWord;
  ThisChunk      : LongWord;
  Best, Worst    : TStamp;
  PassTicks      : TStamp;
  PassUnits      : LongWord;
  BestUnits      : LongWord;
  AllTicks       : TStamp;
  AllUnits       : LongWord;
  T0, TNow       : TStamp;
  P              : Integer;
  I              : LongWord;
begin
  FillChar(R, SizeOf(R), 0);
  if BenchAborted then
  begin
    R.Aborted := True;
    RunBenchFor := R;
    Exit;
  end;

  { ------------------------------------------------------------- calibrate }

  UnitsPerCall := 1;
  T := 0;
  repeat
    T := TimeCall(K, UnitsPerCall);
    if T >= LongWord(CalMinMs) * TicksPerMs then
      Break;
    if UnitsPerCall >= MaxUnits then
      Break;
    UnitsPerCall := UnitsPerCall * 2;
  until False;

  TicksPerCall := T;
  if TicksPerCall = 0 then
  begin
    { Even MaxUnits units finished inside one timer tick. Nothing sensible
      can be said about this kernel on this machine. }
    R.TooFast := True;
    RunBenchFor := R;
    Exit;
  end;

  { --------------------------------------------------------------- measure }

  CallsTotal := (LongWord(MsPerPass) * TicksPerMs) div TicksPerCall;
  if CallsTotal < 1 then CallsTotal := 1;

  CallsPerChunk := (LongWord(ChunkMs) * TicksPerMs) div TicksPerCall;
  if CallsPerChunk < 1 then CallsPerChunk := 1;

  { Warm-up: fill the caches and settle the branch predictor so the first
    timed pass is not systematically slower than the others. }
  K(UnitsPerCall);

  Best  := $FFFFFFFF;
  Worst := 0;
  BestUnits := 0;
  AllTicks  := 0;
  AllUnits  := 0;

  for P := 1 to Passes do
  begin
    Done := 0;
    T0 := Stamp;
    TNow := T0;

    while Done < CallsTotal do
    begin
      ThisChunk := CallsPerChunk;
      if Done + ThisChunk > CallsTotal then
        ThisChunk := CallsTotal - Done;

      for I := 1 to ThisChunk do
        K(UnitsPerCall);

      Inc(Done, ThisChunk);

      TNow := Stamp;
      if StampDiff(T0, TNow) > LongWord(AbortMs) * TicksPerMs then
      begin
        R.Overrun := True;
        Break;
      end;
      if EscPressed then
      begin
        R.Aborted := True;
        Break;
      end;
    end;

    PassTicks := StampDiff(T0, TNow);
    PassUnits := Done * LongWord(UnitsPerCall);

    if R.Aborted or R.Overrun then
      Break;

    Inc(AllTicks, PassTicks);
    Inc(AllUnits, PassUnits);

    if PassTicks < Best then
    begin
      Best := PassTicks;
      BestUnits := PassUnits;
    end;
    if PassTicks > Worst then
      Worst := PassTicks;
  end;

  if R.Aborted or R.Overrun or (BestUnits = 0) then
  begin
    RunBenchFor := R;
    Exit;
  end;

  R.Ok    := True;
  R.Units := BestUnits;
  R.Ticks := Best;
  R.Us    := StampUs(Best);
  R.Rate  := RateOf(BestUnits, Best);
  R.AllUnits := AllUnits;
  R.AllTicks := AllTicks;
  R.AllUs    := StampUs(AllTicks);
  if Best > 0 then
    R.SpreadPc := Word(((Worst - Best) * 100) div Best)
  else
    R.SpreadPc := 0;

  RunBenchFor := R;
end;

function RunBench(K: TKernel): TBenchResult;
begin
  RunBench := RunBenchFor(K, MeasureMs);
end;

begin
  BenchAborted := False;
end.
