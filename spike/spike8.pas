program spike8;
{ Integration check for the iteration-1 UI/report/database slice. }

uses attime, atharn, atcpuid, atsys, attcpu, atmemx, attmem,
     atui, atrep, atdb;

{$I at.inc}

var
  DbName : String;
  MemOk  : Boolean;

begin
  ReportEmulated := ParamStr(1) = '/auto';
  WriteLn('ATBench spike 8 - report and database');
  WriteLn('==========================================');

  CpuDetect;
  SysDetect;
  TimerInstall;
  CpuMeasureMhz;

  CpuTestsInit;
  CpuTestRun(0);
  MemOk := MemTestsInit;
  if MemOk then MemTestRun(0);

  ReportScreen(True);
  if ReportFile('REPORT.TXT') then WriteLn('REPORT.TXT: OK')
  else WriteLn('REPORT.TXT: FAIL ', ReportError);

  if DbSave('integration check', 'spike8', DbName) then
    WriteLn(DbName, ': OK, records=', DbCount)
  else WriteLn('database: FAIL ', DbError);

  if MemOk then MemTestsDone;
  TimerRemove;

  if ParamStr(1) <> '/auto' then
  begin
    Write('press ENTER'); ReadLn;
  end;
end.
