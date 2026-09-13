program spike2;
{ ----------------------------------------------------------------------------
  ATBench spike 2 - does the adaptive harness actually measure the machine
  rather than its own scaling decisions?

  Four kernels, three questions:

    repeatability  add8 twice. Two runs that picked the same scale should
                   agree closely; if they do not, the noise floor is too high
                   to build on.

    linearity      add8x2 runs the add8 loop twice, so it does exactly twice
                   the work and its rate must come out at half. This is the
                   important one: it holds regardless of how fast the machine
                   is, so a 286 and a Pentium must both produce 2.00. If the
                   harness were really measuring its own overhead, the ratio
                   would drift away from 2.

    absolute       the "1 ms" kernel spends a known amount of wall-clock time
                   per unit, so its rate must land near 1000 units/s on any
                   machine whatsoever. That pins the harness to real time.
  ---------------------------------------------------------------------------- }

uses attime, atharn;

{$I at.inc}

{ ---------------------------------------------------------------- kernels }

procedure KernAdd8(Units: Word); assembler;
asm
    push bx
    mov  cx, Units
    or   cx, cx
    jz   @@done
@@loop:
    add  ax, bx
    add  bx, dx
    add  dx, ax
    add  ax, bx
    add  bx, dx
    add  dx, ax
    add  ax, bx
    add  bx, dx
    dec  cx
    jnz  @@loop
@@done:
    pop  bx
end;

{ Exactly twice the work of KernAdd8 - the same loop, run through twice,
  loop overhead included. Doubling the number of adds inside one loop would
  *not* double the work, because the dec/jnz would still be paid once: on a
  486 that gives (16+1+3)/(8+1+3) = 1.667, not 2. }
procedure KernAdd8Twice(Units: Word);
begin
  KernAdd8(Units);
  KernAdd8(Units);
end;

{ Not a benchmark kernel - a ruler. Burns one millisecond of wall clock per
  unit, so whatever the harness reports can be checked against a number we
  knew in advance. }
procedure KernMillisecond(Units: Word);
var
  I: Word;
  T: TStamp;
begin
  for I := 1 to Units do
  begin
    T := Stamp;
    while StampDiff(T, Stamp) < TicksPerMs do ;
  end;
end;

{ ----------------------------------------------------------------- report }

var
  R8a, R8b, R16, RMs : TBenchResult;
  Ratio, Drift       : Real;

procedure Show(const Name: string; const R: TBenchResult);
begin
  Write(Name:20);
  if R.TooFast then
  begin
    WriteLn('   too fast to measure');
    Exit;
  end;
  if R.Aborted then
  begin
    WriteLn('   aborted');
    Exit;
  end;
  if R.Overrun then
  begin
    WriteLn('   overran the time budget');
    Exit;
  end;
  WriteLn(R.Units:12, StampMs(R.Ticks):10, R.SpreadPc:8, R.Rate:14);
end;

function SafeRatio(A, B: LongWord): Real;
begin
  if B = 0 then SafeRatio := 0 else SafeRatio := A / B;
end;

begin
  WriteLn;
  WriteLn('ATBench spike 2 - adaptive harness');
  WriteLn('-------------------------------------');
  WriteLn('target pass length ', MeasureMs, ' ms, ', Passes,
          ' passes, best of, chunk ', ChunkMs, ' ms');
  WriteLn;

  TimerInstall;

  R8a := RunBench(@KernAdd8);
  R8b := RunBench(@KernAdd8);
  R16 := RunBench(@KernAdd8Twice);
  RMs := RunBench(@KernMillisecond);

  TimerRemove;

  WriteLn('kernel                     units  pass ms  spread%   units/sec');
  WriteLn('---------------------------------------------------------------');
  Show('add8', R8a);
  Show('add8 again', R8b);
  Show('add8 x2 (2x work)', R16);
  Show('1 ms per unit', RMs);
  WriteLn;

  WriteLn('checks');
  WriteLn('------');

  Drift := SafeRatio(R8a.Rate, R8b.Rate);
  Write('  repeatability   add8 vs add8 : ', Drift:6:4);
  if (Drift > 0.95) and (Drift < 1.05) then WriteLn('   OK (want 1.00 +-5%)')
                                       else WriteLn('   SUSPECT');

  Ratio := SafeRatio(R8a.Rate, R16.Rate);
  Write('  linearity      add8 / add8x2 : ', Ratio:6:4);
  if (Ratio > 1.90) and (Ratio < 2.10) then WriteLn('   OK (want 2.00 +-5%)')
                                       else WriteLn('   SUSPECT');

  Write('  absolute        1 ms kernel  : ', RMs.Rate:6, '/s');
  if (RMs.Rate > 950) and (RMs.Rate < 1050) then WriteLn('   OK (want ~1000)')
                                            else WriteLn('   SUSPECT');
  WriteLn;

  if (RMs.Rate > 0) then
    WriteLn('  one "1 ms" unit really took ',
            (LongWord(1000000) div RMs.Rate), ' us');
  WriteLn;

  if (ParamCount = 0) or (ParamStr(1) <> '/auto') then
  begin
    Write('Press ENTER...');
    ReadLn;
  end;
end.
