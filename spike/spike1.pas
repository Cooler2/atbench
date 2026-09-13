program spike1;
{ ----------------------------------------------------------------------------
  ATBench spike 1 - proves the two foundations before anything is built on
  them:

    * far buffers  - can we really get half a megabyte from DOS in the medium
                     memory model, and is our segment arithmetic correct
                     across 64K boundaries? The pattern check answers the
                     second question: if two chunks aliased each other the
                     pseudo-random sequence would not read back.

    * the PIT clock - does it resolve microseconds, and does the DOS
                     time-of-day still advance at the right rate while our
                     handler owns INT 08h? The run is timed three ways at
                     once (our clock, the BIOS tick counter, the DOS clock)
                     and the three are compared.
  ---------------------------------------------------------------------------- }

uses dos, atmemx, attime;

{$I at.inc}

const
  WantBytes  = 524288;        { 512K }
  CrcZero512 = $75660AAC;     { CRC32 of 524288 zero bytes, checked on a PC }
  MeasureFor = 182;           { BIOS ticks ~ 10.0 s }

var
  Buf   : TFarBuf;
  Avail : LongInt;
  Bad   : LongInt;
  Crc   : LongInt;
  Want  : LongInt;
  T0, T1, Cost : TStamp;
  MinDelta, D  : TStamp;
  I     : Integer;
  B0, B1: LongWord;
  H0,M0,S0,C0 : Word;
  H1,M1,S1,C1 : Word;
  DosMs : LongInt;
  OurMs : LongWord;

const
  HexDigits: array[0..15] of Char = '0123456789ABCDEF';

function HexN(V: LongInt; Width: Integer): string;
var
  S: string;
  I: Integer;
begin
  S := '';
  for I := Width - 1 downto 0 do
    S := S + HexDigits[(V shr (I * 4)) and 15];
  HexN := S;
end;

function HexL(V: LongInt): string;
begin
  HexL := HexN(V, 8);
end;

function HexW(V: LongInt): string;
begin
  HexW := HexN(V, 4);
end;

begin
  WriteLn;
  WriteLn('ATBench spike 1 - far memory + PIT clock');
  WriteLn('-------------------------------------------');

  { ---------------------------------------------------------------- memory }

  WriteLn('[mem] SizeOf(Pointer)=', SizeOf(Pointer),
          '  SizeOf(FarPointer)=', SizeOf(FarPointer));

  Avail := FarMaxAvail;
  WriteLn('[mem] largest free DOS block: ', Avail, ' bytes');

  Want := WantBytes;
  if Want > Avail - 16384 then
    Want := (Avail - 16384) and not LongInt(15);
  if Want < 65536 then
  begin
    WriteLn('[mem] FAILED: less than 64K available, cannot continue');
    Halt(1);
  end;

  if not FarAlloc(Want, Buf) then
  begin
    WriteLn('[mem] FAILED: FarAlloc(', Want, ') refused');
    Halt(1);
  end;
  WriteLn('[mem] allocated ', Buf.Size, ' bytes at ', HexW(Buf.Base), ':0000');

  FarPattern(Buf, $1234);
  Bad := FarVerify(Buf, $1234);
  if Bad < 0 then
    WriteLn('[mem] pattern write+verify across ',
            (Buf.Size + ChunkBytes - 1) div ChunkBytes, ' chunks: OK')
  else
  begin
    WriteLn('[mem] FAILED: first mismatch at offset ', Bad);
    FarFree(Buf);
    Halt(1);
  end;

  Crc := FarCrc32(Buf);
  WriteLn('[mem] CRC32 of pattern     : ', HexL(Crc));

  FarFill(Buf, 0);
  Crc := FarCrc32(Buf);
  Write('[mem] CRC32 of ', Buf.Size, ' zeros: ', HexL(Crc));
  if (Buf.Size = 524288) then
  begin
    if Crc = CrcZero512 then WriteLn('  (matches reference)')
                        else WriteLn('  MISMATCH, expected ', HexL(CrcZero512));
  end
  else
    WriteLn('  (no reference for this size)');

  FarFree(Buf);
  WriteLn('[mem] freed');
  WriteLn;

  { ----------------------------------------------------------------- clock }

  TimerInstall;
  WriteLn('[clk] installed: ', PitInHz div PitDiv, ' Hz nominal, ',
          'chain every ', ChainEvery, ' ticks');

  { What does one timestamp cost, and what is the smallest gap it can see? }
  MinDelta := $FFFFFFFF;
  T0 := Stamp;
  for I := 1 to 200 do
  begin
    T1 := Stamp;
    D  := StampDiff(T0, T1);
    if (D > 0) and (D < MinDelta) then MinDelta := D;
    T0 := T1;
  end;
  Cost := MinDelta;
  WriteLn('[clk] Stamp() granularity : ', Cost, ' PIT tick(s) = ',
          StampNs(Cost), ' ns');

  WriteLn('[clk] timing ', MeasureFor, ' BIOS ticks (~10 s), please wait...');

  { Line the start up with a BIOS tick edge so the reference is exact. }
  B0 := BiosTicks;
  while BiosTicks = B0 do ;
  B0 := BiosTicks;
  GetTime(H0, M0, S0, C0);
  T0 := Stamp;

  while StampDiff(B0, BiosTicks) < MeasureFor do ;

  T1 := Stamp;
  B1 := BiosTicks;
  GetTime(H1, M1, S1, C1);

  OurMs := StampMs(StampDiff(T0, T1));
  DosMs := (LongInt(H1) * 3600000 + LongInt(M1) * 60000 + LongInt(S1) * 1000
            + LongInt(C1) * 10)
         - (LongInt(H0) * 3600000 + LongInt(M0) * 60000 + LongInt(S0) * 1000
            + LongInt(C0) * 10);
  if DosMs < 0 then Inc(DosMs, LongInt(24) * 3600000);

  WriteLn('[clk] our PIT clock  : ', OurMs, ' ms');
  WriteLn('[clk] DOS time-of-day: ', DosMs, ' ms');
  WriteLn('[clk] BIOS ticks     : ', B1 - B0, '  (expected ', MeasureFor, ')');
  WriteLn('[clk] reference      : ', (LongInt(MeasureFor) * 549254) div 10000,
          ' ms  <- ', MeasureFor, ' x 54.9254 ms');

  TimerRemove;
  WriteLn('[clk] removed, PIT back to 18.2 Hz');
  WriteLn;
  WriteLn('If our clock, the DOS clock and the reference all agree to within');
  WriteLn('a few ms, the timer core is sound.');
  WriteLn;

  { /auto is for unattended runs under an emulator - nothing to press. }
  if (ParamCount = 0) or (ParamStr(1) <> '/auto') then
  begin
    Write('Press ENTER...');
    ReadLn;
  end;
end.
