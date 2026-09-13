program spike5;
{ ATBench spike 5 - system inventory. Prints what ATSYS found, in the
  shape the report header will eventually take. }

uses atcpuid, atsys, attime;

{$I at.inc}

function YesNo(B: Boolean): String;
begin
  if B then YesNo := 'yes' else YesNo := 'no';
end;

function N(W: LongWord): String;
var S: String;
begin
  Str(W, S);
  N := S;
end;

procedure Line(const Caption, Value: String);
var S: String;
begin
  S := '  ' + Caption;
  while Length(S) < 22 do S := S + ' ';
  WriteLn(S, Value);
end;

begin
  WriteLn('ATBench spike 5 - system inventory');
  WriteLn('-------------------------------------');
  WriteLn;

  CpuDetect;
  SysDetect;

  WriteLn('machine');
  Line('model byte', MachineIdStr);
  Line('CPU', CpuName + ' (' + CpuClassStr + ')');
  Line('FPU', FpuClassStr);
  if InV86 then
    Line('WARNING', 'running in V86 mode - a memory manager is loaded');

  WriteLn;
  WriteLn('memory');
  Line('conventional', N(ConvKb) + ' KB total, ' + N(FreeDosKb) + ' KB free');
  if XmsOk then
    Line('XMS', BcdVerStr(XmsVer) + ', ' + N(XmsFreeKb) +
                ' KB free, largest ' + N(XmsLargeKb) + ' KB')
  else
    Line('XMS', 'not present');
  if EmsOk then
    Line('EMS', BcdVerStr(EmsVer) + ', ' + N(EmsFreeKb) + ' KB free')
  else
    Line('EMS', 'not present');

  WriteLn;
  WriteLn('video');
  Line('adapter', VideoKind);
  if VideoBios <> '' then
    Line('BIOS string', VideoBios);
  if VbeOk then
  begin
    Line('VESA VBE', BcdVerStr(VbeVer) + ', ' + N(VbeMemKb) + ' KB');
    if VbeOem <> '' then Line('VBE OEM', VbeOem);
  end
  else
    Line('VESA VBE', 'not present');

  WriteLn;
  WriteLn('storage and software');
  Line('floppy drives', N(Floppies));
  Line('hard disks', N(HardDisks));
  Line('DOS', DosVerStr);
  if SmartDrv then
    Line('WARNING', 'SMARTDRV is loaded - disk results will be cache speeds')
  else
    Line('disk cache', 'none detected');

  if ParamStr(1) <> '/auto' then
  begin
    WriteLn;
    Write('press ENTER');
    ReadLn;
  end;
end.
