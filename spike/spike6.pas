program spike6;
{ ATBench spike 6 - run the CPU test set and print it as a table.
  This is the first program that produces actual benchmark numbers. }

uses attime, atharn, atcpuid, atsys, attcpu;

{$I at.inc}

{ value/1e6 with two decimals, without touching the FPU }
function M2(V: LongWord): String;
var
  W, F: LongWord;
  S, T: String;
begin
  W := V div 1000000;
  F := (V mod 1000000) div 10000;
  Str(W, S);
  Str(F, T);
  if Length(T) < 2 then T := '0' + T;
  M2 := S + '.' + T;
end;

function Pad(const S: String; N: Integer): String;
var R: String;
begin
  R := S;
  while Length(R) < N do R := R + ' ';
  Pad := R;
end;

function LPad(const S: String; N: Integer): String;
var R: String;
begin
  R := S;
  while Length(R) < N do R := ' ' + R;
  LPad := R;
end;

var
  I   : Integer;
  Chk : String;

begin
  WriteLn('ATBench spike 6 - CPU tests');
  WriteLn('==============================');
  WriteLn;

  CpuDetect;
  SysDetect;
  WriteLn('  ', CpuName, ', FPU: ', FpuClassStr);
  if InV86 then
    WriteLn('  WARNING: V86 mode - a memory manager is loaded');

  TimerInstall;
  CpuMeasureMhz;
  if CpuMhz > 0 then
  begin
    Write('  clock: ', CpuMhz, ' MHz');
    if MhzExact then WriteLn(' (RDTSC)') else WriteLn(' (estimate)');
  end;
  WriteLn;

  CpuTestsInit;
  WriteLn('  ', CpuTestN, ' tests');
  Chk := CpuSelfCheck;
  if Chk = '' then
    WriteLn('  self-check: rotation kernels agree')
  else
    WriteLn('  SELF-CHECK FAILED: ', Chk);
  WriteLn;
  WriteLn('  ', Pad('test', 30), LPad('result', 10), '  unit      spread');
  WriteLn('  ------------------------------------------------------------');

  for I := 0 to CpuTestN - 1 do
  begin
    CpuTestRun(I);
    Write('  ', Pad(CpuTests[I].Title, 30));
    if CpuTestRes[I].Ran then
      WriteLn(LPad(M2(CpuTestRes[I].Value), 10), '  ',
              Pad(CpuTests[I].Metric, 9), CpuTestRes[I].SpreadPc, '%')
    else
      WriteLn(LPad('-', 10), '  ', CpuTestRes[I].Why);
    if BenchAborted then
    begin
      WriteLn('  cancelled');
      Break;
    end;
  end;

  TimerRemove;

  Chk := CpuSelfCheck;
  WriteLn;
  if Chk = '' then
    WriteLn('  self-check after the run: still consistent')
  else
    WriteLn('  SELF-CHECK AFTER THE RUN FAILED: ', Chk);

  WriteLn('  brpred vs brrand is the branch predictor.');
  WriteLn('  fix16/fix8 against frot is fixed point against the FPU.');

  if ParamStr(1) <> '/auto' then
  begin
    WriteLn;
    Write('press ENTER');
    ReadLn;
  end;
end.
