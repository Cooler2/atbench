program gfxhi;
{ ATBench spike - one composite tier, on its own.

  The high tier needs about 350K of free conventional memory and ATBENCH.EXE
  itself is a third of that, which is why the tier cannot be reached at all on
  a floppy-booted FreeDOS under an emulator: the program that wants the memory
  is the program that is using it. This spike is the same tier, the same unit
  and the same order of calls with none of the suite around it, so the
  arithmetic that puts a 512x480 viewport into a 640x480 mode can be checked
  where checking it is cheap.

  It prints what every step said, and it leaves the frame on the screen long
  enough to be photographed:

      python tools/gfxsnap.py bin/gfxhi.exe --args high --start 6 --shots 12
  ---------------------------------------------------------------------------- }

uses attime, atharn, atcpuid, atsys, atmemx, attvbe, attcmp;

{$I at.inc}

function NumStr(V: LongInt): String;
var S: String;
begin
  Str(V, S);
  NumStr := S;
end;

{ value/1e6 with two decimals, without touching the FPU }
function M2(V: LongWord): String;
var W, F: LongWord; S: String;
begin
  W := V div 1000000;
  F := (V mod 1000000) div 10000;
  Str(F, S);
  if Length(S) < 2 then S := '0' + S;
  M2 := NumStr(LongInt(W)) + '.' + S;
end;

var
  T     : TCmpTier;
  I     : Integer;
  S     : String;
  Crc   : LongInt;
begin
  T := ctHigh;
  S := ParamStr(1);
  if S = 'low' then T := ctLow
  else if S = 'std' then T := ctStd;

  CpuDetect;
  SysDetect;
  TimerInstall;

  WriteLn('gfxhi - frame tier ', CmpTierCfg[T].Id, ', ', CmpTierCfg[T].Title);
  WriteLn('free ', FarMaxAvail div 1024, 'K');

  S := CmpTierWhy(T);
  if S <> '' then
  begin
    WriteLn('tier unavailable: ', S);
    TimerRemove;
    Halt(1);
  end;

  if not CmpInit(T) then
  begin
    WriteLn('init failed: ', CmpWhy);
    TimerRemove;
    Halt(1);
  end;

  S := CmpSelfCheck;
  if S <> '' then WriteLn('SELF-CHECK FAILED: ', S)
  else WriteLn('self-check ok');

  Crc := CmpFrameCrc;
  WriteLn('frame crc ok');

  if not CmpEnterMode then
  begin
    WriteLn('mode failed: ', CmpWhy);
    CmpDone;
    TimerRemove;
    Halt(1);
  end;

  S := CmpPresentCheck;
  CmpLeaveMode;
  if S <> '' then WriteLn('PRESENT CHECK FAILED: ', S)
  else WriteLn('present check ok');
  if CmpPresentWhy <> '' then WriteLn('present note: ', CmpPresentWhy);
  if CmpTimerWhy <> '' then WriteLn('timer note: ', CmpTimerWhy);

  if not CmpEnterMode then
  begin
    WriteLn('mode failed on the second try: ', CmpWhy);
    CmpDone;
    TimerRemove;
    Halt(1);
  end;
  for I := CmpFirst(T) to CmpLast(T) do
  begin
    CmpStatus(CmpTierCfg[T].Id + ' ' + CmpTests[I].Id, CmpTests[I].Title);
    CmpRunTest(I);
  end;
  CmpLeaveMode;

  for I := CmpFirst(T) to CmpLast(T) do
  begin
    Write(CmpTests[I].Id:12, ' ');
    if CmpTestRes[I].Ran then
      WriteLn(M2(CmpTestRes[I].Value):12, ' ', CmpTests[I].Metric,
              '  us ', CmpTestRes[I].UsPer, '  spread ',
              CmpTestRes[I].SpreadPc, '%')
    else if CmpTestRes[I].Skipped then WriteLn('N/A  ', CmpTestRes[I].Why)
    else WriteLn('not run');
  end;

  S := CmpSelfCheck;
  if S <> '' then WriteLn('SELF-CHECK AFTER RUN FAILED: ', S);
  if CmpFrameCrc <> Crc then WriteLn('CHECKSUM CHANGED DURING THE RUN');
  if CmpTimerWhy <> '' then WriteLn('timer note: ', CmpTimerWhy);

  { The frame, held on the screen long enough to be photographed. Under an
    emulator whose window call the clock cannot follow, every test that
    presents anything is skipped - so the one thing this spike exists to look
    at would never appear. The present check draws a frame and puts it on the
    card, which is exactly the picture wanted, and it says whether the card
    got it as well. }
  if ParamStr(2) = 'show' then
  begin
    if CmpEnterMode then
    begin
      for I := 1 to 12 do
      begin
        CmpStatus('ATBENCH - FRAME ' + CmpTierCfg[T].Id,
                  CmpTierCfg[T].Title);
        S := CmpPresentCheck;
        if S <> '' then WriteLn('show ', I, ': ', S);
      end;
      CmpLeaveMode;
    end;
  end;

  CmpDone;
  TimerRemove;
  WriteLn('done');
end.
