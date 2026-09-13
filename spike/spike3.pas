program spike3;
{ ----------------------------------------------------------------------------
  ATBench spike 3 - why does a calibrated one-millisecond wait come back
  after 771 us?

  Spike 1 showed the clock agreeing with the BIOS to 0.05% over ten seconds,
  yet in spike 2 the sum of many short waits fell 23% short of the interval
  containing them - measured with the same clock. Something about the way the
  clock is *used* changes what it reports, so this spike varies the usage and
  keeps the BIOS tick counter as the independent witness throughout.

  A: long interval, idle spin        - the spike 1 case, expected good
  B: long interval, hammering Stamp  - the only thing spike 2 did differently
  C: distribution of the latch value and how often IRQ0 shows up pending
  D: the failing case itself - N one-millisecond waits against the BIOS
  ---------------------------------------------------------------------------- }

uses attime;

{$I at.inc}

const
  BiosTicksFor5s = 91;      { 91 * 54.9254 ms = 4998 ms }
  Waits          = 1000;
  Probes         = 20000;

var
  B0, B1     : LongWord;
  T0, T1     : TStamp;
  OurMs, BiosMs : LongWord;
  I          : LongWord;
  PendCount  : LongWord;
  CMin, CMax : Word;
  T          : TStamp;

var
  RawPend : Byte;    { set as a side effect of ProbeRaw }

{ Same read as Stamp, but hands back the raw pieces so we can see what the
  hardware is actually saying. Results come back in the accumulator and a
  global rather than through var parameters: in the medium memory model a
  var parameter is a *near* pointer, so the obvious `les di, Param` would
  load four bytes where only two exist. }
function ProbeRaw: Word; assembler;
asm
    pushf
    cli
    mov  al, 0
    out  43h, al
    in   al, 40h
    mov  bl, al
    jmp  @@d1
@@d1:
    in   al, 40h
    mov  bh, al
    mov  al, 0Ah
    out  20h, al
    jmp  @@d2
@@d2:
    in   al, 20h
    and  al, 1
    mov  RawPend, al
    popf
    mov  ax, bx
end;

procedure ReportInterval(const Name: string; Our, Bios: LongWord);
var
  Pc: LongInt;
begin
  Write(Name:34, Our:8, ' ms   bios ', Bios:6, ' ms   ');
  if Bios = 0 then
    WriteLn('n/a')
  else
  begin
    Pc := (LongInt(Our) * 1000) div LongInt(Bios);
    WriteLn('ratio ', Pc div 1000, '.', (Pc mod 1000):3, '');
  end;
end;

var
  C: Word;
  Back, Jumps : LongWord;
  MaxD, D     : TStamp;

begin
  WriteLn;
  WriteLn('ATBench spike 3 - clock behaviour under different usage');
  WriteLn('----------------------------------------------------------');
  WriteLn;

  TimerInstall;

  { --- A: long interval, idle spin ---------------------------------------- }
  B0 := BiosTicks;
  while BiosTicks = B0 do ;
  B0 := BiosTicks;
  T0 := Stamp;
  while BiosTicks - B0 < BiosTicksFor5s do ;
  T1 := Stamp;
  B1 := BiosTicks;
  OurMs  := StampMs(StampDiff(T0, T1));
  BiosMs := ((B1 - B0) * 549254) div 10000;
  ReportInterval('A idle spin', OurMs, BiosMs);

  { --- B: long interval, hammering Stamp ---------------------------------- }
  B0 := BiosTicks;
  while BiosTicks = B0 do ;
  B0 := BiosTicks;
  T0 := Stamp;
  while BiosTicks - B0 < BiosTicksFor5s do
    T := Stamp;
  T1 := Stamp;
  B1 := BiosTicks;
  OurMs  := StampMs(StampDiff(T0, T1));
  BiosMs := ((B1 - B0) * 549254) div 10000;
  ReportInterval('B spinning on Stamp', OurMs, BiosMs);

  { --- C: what the hardware reports --------------------------------------- }
  PendCount := 0;
  CMin := $FFFF;
  CMax := 0;
  for I := 1 to Probes do
  begin
    C := ProbeRaw;
    if RawPend <> 0 then Inc(PendCount);
    if C < CMin then CMin := C;
    if C > CMax then CMax := C;
  end;
  WriteLn;
  WriteLn('C  latch value over ', Probes, ' probes: min ', CMin,
          '  max ', CMax, '  (reload is ', PitDiv, ')');
  WriteLn('   IRQ0 seen pending: ', PendCount, ' times (',
          (PendCount * 100) div Probes, '%)');

  { --- D: the failing case ------------------------------------------------ }
  WriteLn;
  B0 := BiosTicks;
  while BiosTicks = B0 do ;
  B0 := BiosTicks;
  T0 := Stamp;
  for I := 1 to Waits do
  begin
    T := Stamp;
    while StampDiff(T, Stamp) < 1193 do ;
  end;
  T1 := Stamp;
  B1 := BiosTicks;
  OurMs  := StampMs(StampDiff(T0, T1));
  BiosMs := ((B1 - B0) * 549254) div 10000;
  WriteLn('D ', Waits, ' waits of 1193 PIT ticks each');
  ReportInterval('  should be 1000 ms', OurMs, BiosMs);
  WriteLn('   our clock says each wait took ', (OurMs * 1000) div Waits, ' us');
  WriteLn('   bios says each wait took      ', (BiosMs * 1000) div Waits, ' us');

  { --- E: is the clock monotonic? ----------------------------------------- }
  { A short wait can only end early if the clock sometimes jumps forward.
    Consecutive reads should differ by a few ticks; anything else is a jump. }
  WriteLn;
  Back := 0;
  Jumps := 0;
  MaxD := 0;
  T0 := Stamp;
  for I := 1 to Probes do
  begin
    T1 := Stamp;
    D := StampDiff(T0, T1);
    if D > $80000000 then
      Inc(Back)                       { wrapped negative: went backwards }
    else
    begin
      if D > MaxD then MaxD := D;
      if D > 100 then Inc(Jumps);
    end;
    T0 := T1;
  end;
  WriteLn('E monotonicity over ', Probes, ' consecutive reads');
  WriteLn('   backwards steps : ', Back);
  WriteLn('   forward jumps   : ', Jumps, ' (delta > 100 ticks)');
  WriteLn('   largest delta   : ', MaxD, ' ticks');

  TimerRemove;

  WriteLn;
  WriteLn('If A is right and B is wrong, reading the clock disturbs it.');
  WriteLn('If both are right but D is short, the fault is in the wait, not');
  WriteLn('in the clock.');
  WriteLn;

  if (ParamCount = 0) or (ParamStr(1) <> '/auto') then
  begin
    Write('Press ENTER...');
    ReadLn;
  end;
end.
