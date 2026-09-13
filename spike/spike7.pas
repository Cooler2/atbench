program spike7;
{ ATBench spike 7 - the memory tests, printed as a table.
  The sequential-read rows are the cache curve: read them top to bottom and
  the steps are the cache boundaries. }

uses attime, atharn, atcpuid, atmemx, attmem;

{$I at.inc}

function M2(V: LongWord): String;
var
  W, F : LongWord;
  S, T : String;
begin
  W := V div 1000000;
  F := (V mod 1000000) div 10000;
  Str(W, S);
  Str(F, T);
  if Length(T) < 2 then T := '0' + T;
  M2 := S + '.' + T;
end;

{ nanoseconds per access, from accesses per second }
function NsOf(AccPerSec: LongWord): String;
var
  Ns : LongWord;
  S  : String;
begin
  if AccPerSec = 0 then
  begin
    NsOf := '-';
    Exit;
  end;
  Ns := LongWord(1000000000 div AccPerSec);
  Str(Ns, S);
  NsOf := S + ' ns';
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
  I: Integer;

begin
  WriteLn('ATBench spike 7 - memory tests');
  WriteLn('=================================');
  WriteLn;

  CpuDetect;
  WriteLn('  ', CpuName, ', free conventional: ', FarMaxAvail div 1024, ' KB');

  TimerInstall;

  if not MemTestsInit then
  begin
    WriteLn('  not enough memory for any working set - nothing to do');
    TimerRemove;
    Halt(1);
  end;

  WriteLn('  buffer ', MemBufBytes div 1024, ' KB, sweep to ',
          MemMaxSweep div 1024, ' KB, ', MemTestN, ' tests');
  WriteLn;
  WriteLn('  ', Pad('test', 30), LPad('result', 10), '  unit     latency  spread');
  WriteLn('  ---------------------------------------------------------------');

  for I := 0 to MemTestN - 1 do
  begin
    MemTestRun(I);
    Write('  ', Pad(MemTests[I].Title, 30));
    if MemTestRes[I].Ran then
    begin
      Write(LPad(M2(MemTestRes[I].Value), 10), '  ',
            Pad(MemTests[I].Metric, 7));
      if MemTests[I].Metric = 'Macc/s' then
        Write(LPad(NsOf(MemTestRes[I].Value), 8))
      else
        Write(LPad('', 8));
      WriteLn(LPad('', 2), MemTestRes[I].SpreadPc, '%');
    end
    else
      WriteLn(LPad('-', 10), '  ', MemTestRes[I].Why);
    if BenchAborted then
    begin
      WriteLn('  cancelled');
      Break;
    end;
  end;

  MemTestsDone;
  TimerRemove;

  WriteLn;
  WriteLn('  The sequential-read rows are the cache curve; the pointer-chase');
  WriteLn('  rows are latency, which bandwidth cannot show.');

  if ParamStr(1) <> '/auto' then
  begin
    WriteLn;
    Write('press ENTER');
    ReadLn;
  end;
end.
