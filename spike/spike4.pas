program spike4;
{ ----------------------------------------------------------------------------
  ATBench spike 4 - CPU/FPU detection.

  Prints everything ATCPUID believes about the machine, plus the raw values
  it derived that from, so that a wrong answer on real hardware can be traced
  without a debugger.
  ---------------------------------------------------------------------------- }

uses attime, atharn, atcpuid;

{$I at.inc}
{$asmcpu PENTIUM}

function HexW(W: Word): String;
const D: array[0..15] of Char = '0123456789ABCDEF';
begin
  HexW := D[(W shr 12) and 15] + D[(W shr 8) and 15] +
          D[(W shr 4) and 15] + D[W and 15];
end;

function HexL(L: LongWord): String;
begin
  HexL := HexW(Word(L shr 16)) + HexW(Word(L and $FFFF));
end;

function YesNo(B: Boolean): String;
begin
  if B then YesNo := 'yes' else YesNo := 'no';
end;

function RawMsw: Word; assembler;
asm
    smsw ax
end;

procedure Line(const Caption, Value: String);
var
  S: String;
begin
  S := '  ' + Caption;
  while Length(S) < 24 do S := S + ' ';
  WriteLn(S, Value);
end;

var
  MSW: Word;

begin
  WriteLn('ATBench spike 4 - CPU detection');
  WriteLn('----------------------------------');
  WriteLn;

  CpuDetect;
  MSW := RawMsw;

  Line('class',      CpuClassStr);
  Line('name',       CpuName);
  if HasCpuid then
  begin
    Line('vendor',   Vendor);
    Line('cpuid max leaf', HexL(CpuidMax));
    WriteLn('  family/model/step   ', CpuFamily, ' / ', CpuModel, ' / ', CpuStep);
    Line('features EDX',  HexL(FeatEdx));
  end
  else
    Line('cpuid',    'not available');

  WriteLn;
  Line('MSW',        HexW(MSW));
  Line('V86 mode',   YesNo(InV86));
  Line('MSW.EM',     YesNo(EmuFpuBit));
  WriteLn;
  Line('FPU',        YesNo(HasFpu));
  Line('FPU class',  FpuClassStr);
  Line('TSC',        YesNo(HasTsc));
  Line('CMOV',       YesNo(HasCmov));
  Line('MMX',        YesNo(HasMmx));

  WriteLn;
  Write('  measuring clock speed ... ');
  TimerInstall;
  CpuMeasureMhz;
  TimerRemove;
  if CpuMhz = 0 then
    WriteLn('failed')
  else if MhzExact then
    WriteLn(CpuMhz, ' MHz (RDTSC, exact)')
  else
    WriteLn(CpuMhz, ' MHz (estimate from a calibrated loop)');

  WriteLn;
  WriteLn('If the class is right but the name is not, the family/model table');
  WriteLn('needs an entry. If the class itself is wrong, the ladder is.');

  if ParamStr(1) <> '/auto' then
  begin
    WriteLn;
    Write('press ENTER');
    ReadLn;
  end;
end.
