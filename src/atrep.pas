unit atrep;
{ Human-readable and machine-readable serialization of the current run. }

interface

{$I at.inc}

procedure ReportScreen(AutoMode: Boolean);

{ Just the four indices and the total, for showing the moment a run ends. }
procedure ReportSummary;

{ The bank-switch block, for showing the moment the video suite ends - from
  the writers that put the same block in REPORT.TXT. }
procedure ReportBankLines;

{ The same for the composite suite: the headline, where the frame went and the
  checksum, printed the moment a frame run ends. }
procedure ReportFrameLines;

{ What a line of kind K is made of, as a mask for UiPutMask: 't' a heading,
  'h' a column header, 'c' a row of cells, 'b' a score row, 'r' a curve row,
  'm' a method row, 'k' a key and its value, 'w' a warning, 'e' a failure,
  anything else prose. The paged report colours itself with this, and so does whatever a run
  prints while it is running - one table, so the same block cannot be one
  colour on the way past and another one in the report. }
function  ReportLineMask(K: Char; const S: String): String;

function  ReportFile(const FileName: String): Boolean;
procedure ReportWriteAtr(var F: Text; const LabelText, NotesText: String);
function  ReportError: Word;

var ReportEmulated: Boolean;

implementation

uses dos, atui, atcpuid, atsys, attcpu, attmem, attvid, attvbe, attdsk,
     attcmp, atscore;

var LastError: Word;

function N2(V: LongWord): String;
var A, B: LongWord; S, T: String;
begin
  A := V div 1000000;
  B := (V mod 1000000) div 10000;
  Str(A, S); Str(B, T);
  if Length(T) < 2 then T := '0' + T;
  N2 := S + '.' + T;
end;

function Two(V: Word): String;
var S: String;
begin
  Str(V, S);
  if Length(S) < 2 then S := '0' + S;
  Two := S;
end;

function Ascii(const S: String): String;
var I: Integer; R: String;
begin
  R := '';
  for I := 1 to Length(S) do
    if (Ord(S[I]) >= 32) and (Ord(S[I]) <= 126) then R := R + S[I]
    else R := R + '?';
  Ascii := R;
end;

function Pad(const S: String; W: Integer): String;
var R: String;
begin
  R := S;
  while Length(R) < W do R := R + ' ';
  Pad := R;
end;

function LeftPad(const S: String; W: Integer): String;
var R: String;
begin
  R := S;
  while Length(R) < W do R := ' ' + R;
  LeftPad := R;
end;

function RTrim(const S: String): String;
var R: String;
begin
  R := S;
  while (Length(R) > 0) and (R[Length(R)] = ' ') do Delete(R, Length(R), 1);
  RTrim := R;
end;

{ A bar Width columns wide, at half-column resolution: '#' is a full column
  and '-' is its left half. Both are ASCII, because REPORT.TXT is meant to
  survive being pasted into a forum post (DESIGN 8.2), and the screen shows
  the same characters: a bar stands on every row of these tables, and solid
  CP437 blocks with no blank row between them merge into one field. What the
  screen adds is colour - the filled part in the bar colour, the empty part of
  the groove dim.

  Scaled by dividing the maximum first. Value is a metric in millionths and
  runs to billions, so Value * Width would overflow a LongWord on exactly the
  machines whose bars are longest. }
function BarStr(Value, Maximum: LongWord; Width: Integer): String;
var
  Halves, I : Integer;
  Sc        : LongWord;
  S         : String;
begin
  Halves := 0;
  if Maximum > 0 then
  begin
    Sc := Maximum div LongWord(Width * 2);
    if Sc = 0 then Sc := 1;
    if Value div Sc > LongWord(Width * 2) then Halves := Width * 2
    else Halves := Value div Sc;
  end;
  S := '[';
  for I := 1 to Width do
    if Halves >= I * 2 then S := S + '#'
    else if Halves = I * 2 - 1 then S := S + '-'
    else S := S + '.';
  BarStr := S + ']';
end;

{ --- one result, one cell ----------------------------------------------- }

{ All four suites print the same four things - identifier, number, unit,
  spread - and printing each of them at whatever width it happens to need
  gives a column of figures that has to be read digit by digit, because 953.39
  and 3562.06 do not start in the same place. Fixed columns with the number
  right-aligned makes the column readable down its length, and it makes two
  results fit on one line, which is what turns two screens of CPU results into
  one. }

const
  CellW = 36;   { two of these and a two-space gap come to 74 of the 76 }

type
  { What a suite has to supply to be printed this way: its Ith result as a
    cell. One line of glue per suite, against one copy of the layout. }
  TCellFn = function(I: Integer): String;

function ResCell(const Id: String; Ran, Skipped: Boolean; V: LongWord;
                 const Metric, Why: String; Spread: Word;
                 HasSpread: Boolean): String;
var S, T: String;
begin
  S := Pad(Id, 9);
  if Ran then
  begin
    S := S + LeftPad(N2(V), 10) + ' ' + Pad(Metric, 7);
    if HasSpread then
    begin
      Str(Spread, T);
      S := S + LeftPad(T + '%', 4);
    end;
  end
  else if Skipped then S := S + LeftPad('N/A', 10) + '  ' + Why
  else S := S + LeftPad('not run', 10);
  { A reason longer than the cell would shove the right-hand column out of
    line, which is the one thing these widths exist to prevent. }
  if Length(S) > CellW then S := Copy(S, 1, CellW);
  ResCell := S;
end;

function CellHead(HasSpread: Boolean): String;
var S: String;
begin
  S := Pad('test', 9) + LeftPad('result', 10) + ' ' + Pad('unit', 7);
  if HasSpread then S := S + LeftPad('sprd', 4);
  CellHead := S;
end;

{ How many lines a suite of N results takes in two columns. }
function CellLines(N: Integer): Integer;
begin
  CellLines := (N + 1) div 2;
end;

{ Lines First..Last of the two-column form, under one header. The columns are
  the two halves of the list, not its odd and even entries: the tables are
  written in groups - the three 16-bit ALU tests together, the four FPU ones
  together - and interleaving would tear every group in half.

  A suite that never ran writes nothing at all, header included: an empty
  table under a full set of column titles reads as a bug, where nothing at
  all lets the caller say "(not run)" and be believed. }
procedure WriteCells(var F: Text; N, First, Last: Integer;
                     Cell: TCellFn; HasSpread: Boolean);
var I, H: Integer; S: String;
begin
  if N <= 0 then Exit;
  H := CellLines(N);
  if Last > H - 1 then Last := H - 1;
  WriteLn(F, RTrim(Pad(CellHead(HasSpread), CellW) + '  ' +
                   CellHead(HasSpread)));
  for I := First to Last do
  begin
    S := Cell(I);
    if I + H <= N - 1 then S := Pad(S, CellW) + '  ' + Cell(I + H);
    WriteLn(F, RTrim(S));
  end;
end;

function MhzText: String;
var S: String;
begin
  if CpuMhz = 0 then MhzText := 'unknown'
  else
  begin
    Str(CpuMhz, S);
    if MhzExact then MhzText := S + ' MHz measured'
    else MhzText := S + ' MHz estimated';
  end;
end;

{ Hex, up here rather than beside its first table because the system block
  prints the program's own checksum and that block comes first. }
function Hex4(V: Word): String;
const D: array[0..15] of Char = '0123456789ABCDEF';
var I: Integer; R: String;
begin
  R := '';
  for I := 3 downto 0 do R := R + D[(V shr (I * 4)) and 15];
  Hex4 := R;
end;

function Hex8(V: LongInt): String;
begin
  Hex8 := Hex4(Word((LongWord(V) shr 16) and $FFFF)) + Hex4(Word(V and $FFFF));
end;

procedure WriteSystem(var F: Text);
begin
  WriteLn(F, 'CPU: ', Ascii(CpuName), ' (', CpuClassStr, '), ', MhzText);
  WriteLn(F, 'FPU: ', FpuClassStr, '  MMX: ', Ord(HasMmx));
  { One line for the whole memory map. It was three - DOS, then XMS, then EMS -
    which is three of a page's nineteen lines spent on four numbers, and the
    page has a score to fit on it as well. }
  Write(F, 'RAM: ', ConvKb, 'K conventional, ', FreeDosKb, 'K free');
  if XmsOk then Write(F, ', XMS ', XmsFreeKb, 'K');
  if EmsOk then Write(F, ', EMS ', EmsFreeKb, 'K');
  WriteLn(F);
  WriteLn(F, 'Video: ', Ascii(VideoKind), '  BIOS: ', Ascii(VideoBios));
  { The OEM string is often the only place the card names itself: a ROM whose
    copyright notice we failed to find still answers INT 10h AX=4F00h. }
  if VbeOk then
  begin
    Write(F, 'VBE: ', BcdVerStr(VbeVer), '  ', VbeMemKb, ' KB');
    if VbeOem <> '' then Write(F, '  ', Ascii(VbeOem));
    WriteLn(F);
  end;
  WriteLn(F, 'DOS: ', DosVerStr, '   Disks: ', Floppies, ' floppy, ',
          HardDisks, ' hard');
  { Which build produced this page. Two reports that disagree are either two
    machines or two programs, and without this line there is no way to tell
    which - the frame checksums identify the picture, not the binary that
    drew it, and a change anywhere else in the suite leaves them untouched. }
  if SysExeCrc <> 0 then
    WriteLn(F, 'Build: CRC ', Hex8(SysExeCrc), ', ', SysExeSize, ' bytes')
  else
    WriteLn(F, 'Build: CRC unavailable');
  { Without this line a skipped probe reads as a machine with no XMS, no EMS
    and no VBE, which is a different and wrong claim. }
  if SafeProbe then
    WriteLn(F, 'NOTE: /safe - XMS, EMS and VBE were not probed');
  if InV86 then WriteLn(F, 'WARNING: V86 mode; timing and I/O may be distorted');
  if ReportEmulated then WriteLn(F, 'WARNING: emulated run; timings are not benchmark data');
  if SmartDrv then
    WriteLn(F, 'WARNING: ', Ascii(DiskCache),
            ' is resident; disk results may be cached');
end;

{ The key=value form of a row, which is what the database reads back. It is
  deliberately not the two-column form: padding is for eyes, and a parser that
  had to strip it would be a parser that could get it wrong. }
procedure WriteCpuKey(var F: Text; I: Integer);
begin
  Write(F, 'CPU.', CpuTests[I].Id, '=');
  if CpuTestRes[I].Ran then
    WriteLn(F, N2(CpuTestRes[I].Value), ' ', CpuTests[I].Metric,
            ' spread=', CpuTestRes[I].SpreadPc, '%')
  else if CpuTestRes[I].Skipped then WriteLn(F, 'N/A ', Ascii(CpuTestRes[I].Why))
  else WriteLn(F, 'not-run');
end;

function CpuCell(I: Integer): String;
begin
  CpuCell := ResCell(CpuTests[I].Id, CpuTestRes[I].Ran, CpuTestRes[I].Skipped,
                     CpuTestRes[I].Value, CpuTests[I].Metric,
                     Ascii(CpuTestRes[I].Why), CpuTestRes[I].SpreadPc, True);
end;

procedure WriteCpu(var F: Text; Keys: Boolean);
var I: Integer;
begin
  if Keys then
    for I := 0 to CpuTestN - 1 do WriteCpuKey(F, I)
  else WriteCells(F, CpuTestN, 0, CellLines(CpuTestN) - 1, @CpuCell, True);
end;

procedure WriteMemKey(var F: Text; I: Integer);
begin
  Write(F, 'MEM.', MemTests[I].Id, '=');
  if MemTestRes[I].Ran then
    WriteLn(F, N2(MemTestRes[I].Value), ' ', MemTests[I].Metric,
            ' spread=', MemTestRes[I].SpreadPc, '%')
  else if MemTestRes[I].Skipped then WriteLn(F, 'N/A ', Ascii(MemTestRes[I].Why))
  else WriteLn(F, 'not-run');
end;

function MemCell(I: Integer): String;
begin
  MemCell := ResCell(MemTests[I].Id, MemTestRes[I].Ran, MemTestRes[I].Skipped,
                     MemTestRes[I].Value, MemTests[I].Metric,
                     Ascii(MemTestRes[I].Why), MemTestRes[I].SpreadPc, True);
end;

procedure WriteMem(var F: Text; Keys: Boolean);
var I: Integer;
begin
  if Keys then
    for I := 0 to MemTestN - 1 do WriteMemKey(F, I)
  else WriteCells(F, MemTestN, 0, CellLines(MemTestN) - 1, @MemCell, True);
end;

procedure WriteVidKey(var F: Text; I: Integer);
begin
  Write(F, 'VID.', VidTests[I].Id, '=');
  if VidTestRes[I].Ran then
    WriteLn(F, N2(VidTestRes[I].Value), ' ', VidTests[I].Metric,
            ' spread=', VidTestRes[I].SpreadPc, '%')
  else if VidTestRes[I].Skipped then WriteLn(F, 'N/A ', Ascii(VidTestRes[I].Why))
  else WriteLn(F, 'not-run');
end;

function VidCell(I: Integer): String;
begin
  VidCell := ResCell(VidTests[I].Id, VidTestRes[I].Ran, VidTestRes[I].Skipped,
                     VidTestRes[I].Value, VidTests[I].Metric,
                     Ascii(VidTestRes[I].Why), VidTestRes[I].SpreadPc, True);
end;

procedure WriteVid(var F: Text; Keys: Boolean);
var I: Integer;
begin
  if Keys then
    for I := 0 to VidTestN - 1 do WriteVidKey(F, I)
  else WriteCells(F, VidTestN, 0, CellLines(VidTestN) - 1, @VidCell, True);
end;

{ ------------------------------------------------------ VESA bank switch }

{ The cost of one switch in hundredths of a microsecond, from switches per
  second. Integer throughout, like every other number here (DESIGN 7): a
  hundred million over the rate is the cost in hundredths. }
function BankUs100(Rate: LongWord): LongWord;
begin
  if Rate = 0 then BankUs100 := 0 else BankUs100 := 100000000 div Rate;
end;

function Us2(V: LongWord): String;
var A, B: LongWord; S, T: String;
begin
  A := V div 100; B := V mod 100;
  Str(A, S); Str(B, T);
  if Length(T) < 2 then T := '0' + T;
  Us2 := S + '.' + T;
end;

{ The reason a row has no number. A row-level reason where there is one - the
  window function is missing far more often than the whole phase fails - and
  the phase-level reason otherwise. }
function BankWhyFor(const Own: String): String;
begin
  if Own <> '' then BankWhyFor := Own else BankWhyFor := BankWhy;
end;

function BankRow(const Title: String; Ok: Boolean; Rate: LongWord;
                 Spread: Word; const Own: String): String;
var S, T: String;
begin
  S := '  ' + Pad(Title, 15) + ': ';
  if Ok then
  begin
    S := S + LeftPad(Us2(BankUs100(Rate)), 8) + ' us';
    Str(Rate, T);
    S := S + LeftPad(T, 9) + ' /s   spread ';
    Str(Spread, T);
    S := S + T + '%';
  end
  else S := S + 'N/A ' + Ascii(BankWhyFor(Own));
  BankRow := S;
end;

function BankWinLetter: Char;
begin
  if BankWinNo = 0 then BankWinLetter := 'A' else BankWinLetter := 'B';
end;

{ What a whole 640x480 frame pays in window moves. This is the line the rest
  of the block exists for: microseconds per switch is the measurement, but
  what a program of the period actually felt was this number against the
  16.6 ms it had to draw a frame in. }
function BankFrameRow: String;
var S, T: String; PF: Word;
begin
  PF := BankPerFrame;
  Str(PF, T);
  S := '  ' + Pad('640x480 frame', 15) + ': ' + T + ' switches';
  if BankIntOk then
    S := S + ', ' + Us2(BankUs100(BankIntRate) * PF) + ' us via INT 10h';
  if BankDirOk then
    S := S + ', ' + Us2(BankUs100(BankDirRate) * PF) + ' us direct';
  BankFrameRow := S;
end;

function BankHeadRow: String;
var S, T: String;
begin
  S := 'VESA bank switch: mode 101h, window ' + BankWinLetter +
       ' at ' + Hex4(BankWinSeg) + 'h, ';
  Str(BankWinKb, T);  S := S + T + ' KB window, ';
  Str(BankGranKb, T); S := S + T + ' KB granularity';
  BankHeadRow := S;
end;

procedure WriteBank(var F: Text; Keys: Boolean);
begin
  if Keys then
  begin
    WriteLn(F, 'VBE.bankmode=101h');
    if BankWinKb <> 0 then
    begin
      WriteLn(F, 'VBE.window=', BankWinLetter, ' at ', Hex4(BankWinSeg), 'h');
      WriteLn(F, 'VBE.winkb=', BankWinKb);
      WriteLn(F, 'VBE.grankb=', BankGranKb);
      WriteLn(F, 'VBE.verified=', Ord(BankVerified));
      WriteLn(F, 'VBE.perframe=', BankPerFrame);
    end;
    Write(F, 'VID.bankint=');
    if BankIntOk then
      WriteLn(F, BankIntRate, ' switch/s spread=', BankIntSpread, '%')
    else WriteLn(F, 'N/A ', Ascii(BankWhyFor('')));
    Write(F, 'VID.bankdir=');
    if BankDirOk then
      WriteLn(F, BankDirRate, ' switch/s spread=', BankDirSpread, '%')
    else WriteLn(F, 'N/A ', Ascii(BankWhyFor(BankDirWhy)));
    Exit;
  end;

  if BankWinKb = 0 then
  begin
    WriteLn(F, 'VESA bank switch: not measured - ', Ascii(BankWhy));
    Exit;
  end;
  WriteLn(F, BankHeadRow);
  WriteLn(F, BankRow('INT 10h 4F05h', BankIntOk, BankIntRate,
                     BankIntSpread, ''));
  WriteLn(F, BankRow('window function', BankDirOk, BankDirRate,
                     BankDirSpread, BankDirWhy));
  WriteLn(F, BankFrameRow);
  if not BankVerified then
    WriteLn(F, 'WARNING: window cannot be read back; the switch was not verified');
end;

{ --- the composite suite ------------------------------------------------- }

{ Microseconds as milliseconds with two decimals. The composite suite states
  its stage times in microseconds because that is what the harness measured,
  and a frame is read in milliseconds because that is what a frame is. }
function MsText(Us: LongWord): String;
var A, B: LongWord; S, T: String;
begin
  A := Us div 1000;
  B := (Us mod 1000) div 10;
  Str(A, S); Str(B, T);
  if Length(T) < 2 then T := '0' + T;
  MsText := S + '.' + T;
end;

function Pct(Part, Whole: LongWord): String;
var S: String;
begin
  if Whole = 0 then Pct := '  -'
  else
  begin
    Str((Part * 100 + Whole div 2) div Whole, S);
    Pct := LeftPad(S, 3);
  end;
end;

{ The five stages a frame is made of, in the order they are drawn, and the
  identifier prefix each of them is measured under. One table, because the
  row that prints them and the mask that colours it have to agree about how
  many there are and how wide a column is. }
const
  StageN     = 5;
  FrmKeyW    = 11;   { 'Frame std  ', 'CRC std    ': what the row is about }
  StageKeyW  = 6;    { the tier's name, at the head of the row }
  StageColW  = 8;    { ' spr' and ' 13%': one stage's worth of columns }
  StageId  : array[0..StageN - 1] of String[3] =
    ('bg', 'spr', 'lns', 'txt', 'pre');
  StagePre : array[0..StageN - 1] of String[4] =
    ('bg.', 'spr', 'lns', 'txt', 'pre');

{ The first stage of this tier whose identifier starts with Pre, and how long
  one frame's worth of it took. Every stage in the suite is measured in units
  of one frame's worth, which is what lets the four of them be added up and
  compared with the frame itself. }
function CmpStageUs(T: TCmpTier; const Pre: String; var Us: LongWord): Boolean;
var I: Integer;
begin
  CmpStageUs := False;
  Us := 0;
  for I := 0 to CmpTestN - 1 do
    if (CmpTests[I].Tier = T) and (Pos(Pre, CmpTests[I].Id) = 1) and
       CmpTestRes[I].Ran then
    begin
      Us := CmpTestRes[I].UsPer;
      CmpStageUs := True;
      Exit;
    end;
end;

{ The present the frame actually used, which is the fastest of the forms that
  ran - not the first of them. }
function CmpPresentUs(T: TCmpTier; var Us: LongWord): Boolean;
var I: Integer;
begin
  CmpPresentUs := False;
  Us := 0;
  for I := 0 to CmpTestN - 1 do
    if (CmpTests[I].Tier = T) and (Pos('pre', CmpTests[I].Id) = 1) and
       CmpTestRes[I].Ran then
      if (Us = 0) or (CmpTestRes[I].UsPer < Us) then
      begin
        Us := CmpTestRes[I].UsPer;
        CmpPresentUs := True;
      end;
end;

{ Why a tier that was attempted has no numbers in it. Every row of it was
  skipped for some reason, and the reasons are the same one often enough that
  the first is the answer - but not always, so a row that names the frame
  itself is preferred to one that names a stage.

  Empty only when nothing was skipped either, which is a tier that ran and
  produced results. }
function FrameWhy(T: TCmpTier): String;
var I: Integer; S: String;
begin
  S := '';
  for I := 0 to CmpTestN - 1 do
    if (CmpTests[I].Tier = T) and CmpTestRes[I].Skipped and
       (CmpTestRes[I].Why <> '') then
      if (S = '') or (Pos('frm.', CmpTests[I].Id) = 1) then
        S := Ascii(CmpTestRes[I].Why);
  FrameWhy := S;
end;

{ The headline. One line per tier that ran, and the fastest of the two paths
  through it - which is the number this whole suite exists to produce.

  A tier that produced nothing says why on the same line, in the place the
  numbers would have been. It used to print 'no result' and then the tier's
  geometry, which is a description of what was asked for and no answer at all
  to the only question a reader has at that point. }
procedure WriteFrameHead(var F: Text);
var
  T    : TCmpTier;
  Ran  : Boolean;
  Fps, Us : LongWord;
  Path, Why : String;
begin
  for T := ctLow to ctHigh do
    if CmpTierRan[T] then
    begin
      CmpBestFrame(T, Ran, Fps, Us, Path);
      Write(F, Pad('Frame ' + CmpTierCfg[T].Id, FrmKeyW));
      if Ran then
        WriteLn(F, LeftPad(N2(Fps), 8), ' FPS ', LeftPad(MsText(Us), 8),
                ' ms ', Pad(Path, 10), CmpTierCfg[T].Title)
      else
      begin
        Why := FrameWhy(T);
        if Why = '' then Why := CmpTierCfg[T].Title;
        WriteLn(F, LeftPad('no result', 8), '   ', Why);
      end;
    end;
end;

{ Which number these are, since the frame suite is the one part of ATBench
  that does not report its fastest pass - see the note on 'repeat' in atharn.
  Two lines and not three because every character of them is data segment, and
  a frame rate is still the one figure here a reader will quote from memory:
  'up to' and 'about' are different claims and the page has to say which. }
procedure WriteFrameMean(var F: Text);
begin
  WriteLn(F);
  WriteLn(F, 'Frame rates are the mean of every pass, not the fastest. A ' +
             'frame costs what');
  WriteLn(F, 'its angle costs, so the spread below is the animation and ' +
             'not the noise.');
end;

{ What the two paths do differently, beyond the present. Printed only when a
  direct path ran, because that is the only time the difference can mislead
  somebody reading two frame rates side by side - and only for a tier that has
  lenses to leave out, since the low tier has none and the sentence would then
  be explaining a difference that is not there. }
procedure WriteFrameNote(var F: Text);
var I: Integer; Said: Boolean;
begin
  Said := False;
  for I := 0 to CmpTestN - 1 do
    if (Pos('dir.', CmpTests[I].Id) = 1) and CmpTestRes[I].Ran and
       (CmpTierCfg[CmpTests[I].Tier].Lenses > 0) and (not Said) then
    begin
      WriteLn(F);
      WriteLn(F, 'The direct path draws the frame without the lenses: they ' +
                 'read the frame back,');
      WriteLn(F, 'and on that path the frame is in video memory. Its frame ' +
                 'rate is for that frame.');
      Said := True;
    end;
end;

{ Where the frame went. The five stages are measured separately and in the
  same unit as the frame, so their sum can be held against it: a sum that
  misses by more than a few per cent means a stage is being counted twice or
  not at all, and it is worth seeing rather than worth hiding.

  Against the buffered frame, always, and not against whichever path came out
  fastest. The stages are measured drawing into the back buffer, so that is
  the frame they add up to; holding them against a frame drawn straight into
  video memory would compare four RAM writes with one VRAM write and call the
  difference an inconsistency. }
procedure WriteFrameStages(var F: Text);
var
  T   : TCmpTier;
  K   : Integer;
  Us  : array[0..StageN - 1] of LongWord;
  Sum, Fr : LongWord;
  Row : String;
begin
  for T := ctLow to ctHigh do
    if CmpTierRan[T] then
    begin
      Sum := 0;
      for K := 0 to StageN - 1 do
      begin
        { The present is the one stage measured three ways, and the frame uses
          whichever of them was fastest - so the row has to ask for the
          fastest and not for the first, which is the only reason this loop
          has a branch in it at all. }
        if StageId[K] = 'pre' then CmpPresentUs(T, Us[K])
        else CmpStageUs(T, StagePre[K], Us[K]);
        Sum := Sum + Us[K];
      end;
      CmpStageUs(T, 'frm.', Fr);
      { Every column of this line is arithmetic on StageColW, and so is the
        mask that colours it - see MaskStageRow. Two places counting the same
        columns is how a table ends up with its headings a space out from the
        figures under them. }
      Row := Pad(CmpTierCfg[T].Id, StageKeyW);
      for K := 0 to StageN - 1 do
        Row := Row + ' ' + Pad(StageId[K], 3) + Pct(Us[K], Sum) + '%';
      Row := Row + '  sum ' + LeftPad(MsText(Sum), 5) + ' ms' +
                   '  frame ' + LeftPad(MsText(Fr), 5) + ' ms';
      WriteLn(F, Row);
    end;
end;

procedure WriteFrameCrc(var F: Text);
var T: TCmpTier;
begin
  for T := ctLow to ctHigh do
    if CmpTierRan[T] and CmpCrcOk[T] then
      WriteLn(F, Pad('CRC ' + CmpTierCfg[T].Id, FrmKeyW), Hex8(CmpCrc[T]),
              '   the same on every machine that draws it right');
end;

{ Only the tiers that ran, and all of their rows: a tier nobody chose has
  nothing to say, and printing eight "not run" rows for each of them would
  bury the tier that did run. }
var
  CmpIx  : array[0..MaxCmpTests - 1] of Integer;
  CmpIxN : Integer;

procedure CmpIndex;
var I: Integer;
begin
  CmpIxN := 0;
  for I := 0 to CmpTestN - 1 do
    if CmpTierRan[CmpTests[I].Tier] then
    begin
      CmpIx[CmpIxN] := I;
      Inc(CmpIxN);
    end;
end;

function CmpCell(I: Integer): String;
var J: Integer;
begin
  J := CmpIx[I];
  CmpCell := ResCell(CmpTests[J].Id, CmpTestRes[J].Ran, CmpTestRes[J].Skipped,
                     CmpTestRes[J].Value, CmpTests[J].Metric,
                     Ascii(CmpTestRes[J].Why), CmpTestRes[J].SpreadPc, True);
end;

procedure WriteCmpKey(var F: Text; I: Integer);
begin
  Write(F, 'CMP.', CmpTests[I].Id, '=');
  if CmpTestRes[I].Ran then
    WriteLn(F, N2(CmpTestRes[I].Value), ' ', CmpTests[I].Metric,
            ' us=', CmpTestRes[I].UsPer, ' spread=', CmpTestRes[I].SpreadPc, '%')
  else if CmpTestRes[I].Skipped then
    WriteLn(F, 'N/A ', Ascii(CmpTestRes[I].Why))
  else WriteLn(F, 'not-run');
end;

procedure WriteCmp(var F: Text; Keys: Boolean);
var I: Integer; T: TCmpTier;
begin
  if not CmpAnyRan then Exit;
  CmpIndex;
  if Keys then
  begin
    for T := ctLow to ctHigh do
      if CmpTierRan[T] and CmpCrcOk[T] then
        WriteLn(F, 'CMP.crc.', CmpTierCfg[T].Id, '=', Hex8(CmpCrc[T]));
    for I := 0 to CmpTestN - 1 do
      if CmpTierRan[CmpTests[I].Tier] then WriteCmpKey(F, I);
    Exit;
  end;
  WriteCells(F, CmpIxN, 0, CellLines(CmpIxN) - 1, @CmpCell, True);
end;

procedure WriteFrame(var F: Text);
begin
  if not CmpAnyRan then
  begin
    WriteLn(F, '(not run)');
    Exit;
  end;
  WriteFrameHead(F);
  WriteLn(F);
  WriteFrameStages(F);
  WriteFrameMean(F);
  WriteFrameNote(F);
  WriteLn(F);
  WriteFrameCrc(F);
end;


procedure WriteDskKey(var F: Text; I: Integer);
begin
  Write(F, 'DSK.', DskTests[I].Id, '=');
  if DskTestRes[I].Ran then
    WriteLn(F, N2(DskTestRes[I].Value), ' ', DskTests[I].Metric)
  else if DskTestRes[I].Skipped then WriteLn(F, 'N/A ', Ascii(DskTestRes[I].Why))
  else WriteLn(F, 'not-run');
end;

{ The disk phases run once each rather than best-of-many, so there is no
  spread to print and the column is left out rather than filled with zeroes. }
function DskCell(I: Integer): String;
begin
  DskCell := ResCell(DskTests[I].Id, DskTestRes[I].Ran, DskTestRes[I].Skipped,
                     DskTestRes[I].Value, DskTests[I].Metric,
                     Ascii(DskTestRes[I].Why), 0, False);
end;

{ The header lines matter as much as the numbers here: a disk figure without
  the drive it came from, and without whether the file was long enough to
  outrun the cache, is not worth keeping. }
procedure WriteDskHead(var F: Text; Keys: Boolean);
begin
  if Keys then
  begin
    WriteLn(F, 'DSK.drive=', DskLetter);
    WriteLn(F, 'DSK.filekb=', DskFileBytes div 1024);
    WriteLn(F, 'DSK.cachedoubt=', Ord(DskCacheDoubt));
  end
  else
  begin
    WriteLn(F, 'drive ', DskLetter, ':, test file ',
            DskFileBytes div 1024, ' KB');
    if DskCacheDoubt then
      WriteLn(F, 'WARNING: file too small to be sure the cache was beaten');
  end;
end;

procedure WriteDsk(var F: Text; Keys: Boolean);
var I: Integer;
begin
  WriteDskHead(F, Keys);
  if Keys then
    for I := 0 to DskTestN - 1 do WriteDskKey(F, I)
  else WriteCells(F, DskTestN, 0, CellLines(DskTestN) - 1, @DskCell, False);
end;

{ --- the cache curve ---------------------------------------------------- }

{ The sweep is fifteen numbers whose *shape* is the answer: bandwidth holds
  flat while the working set fits a cache and steps down when it stops
  fitting, so where the steps are is where the caches end. A column of
  figures hides that; the same figures as bars are the shape itself.

  The scale is linear and relative - full width is the fastest row on this
  machine - because a step is only legible when half the length means half
  the speed. The Summary bar above is logarithmic and absolute for the
  opposite reason: it is read against other machines, this is read against
  itself. }

const
  CurveWide = 40;

{ Value is the metric in millionths, so for a chase - measured in Macc/s -
  it is accesses per second exactly, and a nanosecond is a billionth. }
function NsText(V: LongWord): String;
var S: String;
begin
  if V = 0 then NsText := ''
  else
  begin
    Str(1000000000 div V, S);
    NsText := S;
  end;
end;

{ The fastest row, which is what full width means. Zero when the sweep never
  ran, and then there is no scale and nothing to draw. }
function CurveBest: LongWord;
var I, Rd: Integer; Best: LongWord;
begin
  Best := 0;
  for I := 0 to MemCurveN - 1 do
  begin
    Rd := MemCurve[I].Read;
    if (Rd >= 0) and MemTestRes[Rd].Ran and (MemTestRes[Rd].Value > Best) then
      Best := MemTestRes[Rd].Value;
  end;
  CurveBest := Best;
end;

procedure WriteCurveRow(var F: Text; I: Integer; Best: LongWord);
var
  Rd, Lt : Integer;
  V      : LongWord;
  S, T   : String;
begin
  Rd := MemCurve[I].Read;
  Lt := MemCurve[I].Lat;
  Str(MemCurve[I].Kb, T);
  S := LeftPad(T + 'K', 5) + ' ';

  if (Rd >= 0) and MemTestRes[Rd].Ran and (Best > 0) then
  begin
    V := MemTestRes[Rd].Value;
    S := S + BarStr(V, Best, CurveWide) + ' ' + LeftPad(N2(V), 8) + ' MB/s';
  end
  { As wide as '[' + bar + '] ', so the column stays put. }
  else S := S + Pad('', CurveWide + 3) + LeftPad('not run', 8) + '     ';

  { Blank past 64 KB rather than absent: the chase walks 16-bit offsets and
    cannot cross a segment, so the gap is a limit of the test, not of the
    machine. }
  if (Lt >= 0) and MemTestRes[Lt].Ran then
    S := S + LeftPad(NsText(MemTestRes[Lt].Value), 7) + ' ns';

  WriteLn(F, S);
end;

{ Split in two so that whoever is building a screen can say where the table
  ends and the prose begins. Nothing else needs to know. }
procedure WriteCurveTable(var F: Text);
var I: Integer; Best: LongWord;
begin
  if MemCurveN = 0 then
  begin
    WriteLn(F, 'no sweep data');
    Exit;
  end;
  Best := CurveBest;
  WriteLn(F, LeftPad('size', 5), '  ', Pad('read bandwidth', CurveWide + 2),
          LeftPad('rate', 8), LeftPad('latency', 12));
  for I := 0 to MemCurveN - 1 do WriteCurveRow(F, I, Best);
end;

procedure WriteCurveLegend(var F: Text);
var Best: LongWord;
begin
  Best := CurveBest;
  if (MemCurveN = 0) or (Best = 0) then Exit;
  WriteLn(F);
  WriteLn(F, 'Linear and relative: full width is the fastest row, ',
          N2(Best), ' MB/s. Half the');
  WriteLn(F, 'length is half the speed; a step down is a working set ',
          'outgrowing a cache.');
end;

procedure WriteCurve(var F: Text);
begin
  WriteCurveTable(F);
  WriteCurveLegend(F);
end;

{ --- the access methods -------------------------------------------------- }

{ Seventeen ways of moving memory, each measured at two working sets. As rows
  in the results list they are seventeen numbers, then a page-turn, then
  seventeen more, and the comparison the set exists for - which method is
  fastest here, and whether that changes when the data stops fitting the
  cache - has to be done in the reader's head across two screens. Side by
  side, both questions are answered by looking down a column.

  The columns are labelled by size, never by 'cache' and 'RAM': which of them
  a given machine caches is exactly what the curve above is there to say, and
  this table would be assuming the answer. }

procedure WriteMethodVal(var F: Text; Ix: Integer);
begin
  if Ix < 0 then Write(F, LeftPad('-', 10))
  else if MemTestRes[Ix].Ran then Write(F, LeftPad(N2(MemTestRes[Ix].Value), 10))
  else if MemTestRes[Ix].Skipped then Write(F, LeftPad('N/A', 10))
  else Write(F, LeftPad('not run', 10));
end;

procedure WriteMethodRow(var F: Text; I: Integer);
var Ix: Integer;
begin
  Write(F, Pad(MemMethod[I].Name, 18));
  Ix := MemMethod[I].Small;
  if Ix >= 0 then Write(F, Pad(MemTests[Ix].Metric, 7))
  else Write(F, Pad('', 7));
  WriteMethodVal(F, MemMethod[I].Small);
  WriteMethodVal(F, MemMethod[I].Big);
  WriteLn(F);
end;

procedure WriteMethodHead(var F: Text);
var S, T: String;
begin
  Str(MemSmallKb, S);
  if MemBigKb = 0 then T := '-' else Str(MemBigKb, T);
  WriteLn(F, Pad('method', 18), Pad('unit', 7),
          LeftPad(S + 'K', 10), LeftPad(T + 'K', 10));
end;

procedure WriteMethodTable(var F: Text; First, Last: Integer);
var I: Integer;
begin
  if MemMethodN = 0 then
  begin
    WriteLn(F, 'no method data');
    Exit;
  end;
  if Last > MemMethodN - 1 then Last := MemMethodN - 1;
  WriteMethodHead(F);
  for I := First to Last do WriteMethodRow(F, I);
end;

procedure WriteMethodLegend(var F: Text);
begin
  if MemMethodN = 0 then Exit;
  if MemBigKb = 0 then
    WriteLn(F, 'One column only: no room for a second working set twice its size.')
  else
    WriteLn(F, 'Sizes, not names: the curve above says which of them this ',
            'machine caches.');
end;

procedure WriteMethods(var F: Text; First, Last: Integer);
begin
  WriteMethodTable(F, First, Last);
  WriteMethodLegend(F);
end;

{ --- the indices ------------------------------------------------------- }

{ Logarithmic, four columns to the doubling.

  It used to be linear at 40 columns for 200 points. The first real machine to
  run this - a Pentium 120 - scored 374, 334 and 347 in three of the four
  categories and pinned all three bars at full width, which is the one thing a
  bar must not do: three identical bars over three different numbers say the
  numbers are the same. Doubling the linear range only moves the wall.

  So each column is 2^(1/4), the table below is 100 points scaled by that
  factor either way, and the reference machine lands at column 25 of 40. The
  span is 1.6 to 1600 points, which holds a 6 MHz 286 at one end and anything
  this suite will ever meet at the other. Comparing two reports column by
  column stays meaningful, which an auto-scaled bar would have given up. }
const
  BarSteps : array[0..39] of LongWord =
    (   156,    186,    221,    263,    313,    371,    442,    525,
        625,    743,    884,   1051,   1250,   1486,   1768,   2102,
       2500,   2972,   3536,   4203,   5000,   5945,   7071,   8406,
      10000,  11892,  14142,  16818,  20000,  23784,  28284,  33636,
      40000,  47568,  56569,  67272,  80000,  95137, 113137, 134543);

{ Half a column is half a step, and a step is 2^(1/4), so the middle of one
  sits at 2^(1/8) = 1.0905 times the step below it - eight columns to the
  doubling where there were four, for the price of one comparison. }
procedure ScoreBar(var F: Text; Points: LongWord);
var I, N: Word; Half: Boolean;
begin
  N := 0;
  for I := 0 to 39 do
    if Points >= BarSteps[I] then N := I + 1;
  Half := (N > 0) and (N < 40) and
          (Points >= (BarSteps[N - 1] * 1090) div 1000);
  Write(F, '[');
  for I := 1 to 40 do
    if I <= N then Write(F, '#')
    else if Half and (I = N + 1) then Write(F, '-')
    else Write(F, '.');
  Write(F, ']');
end;

{ No key-value variant here, unlike every other section: DESIGN 7 keeps points
  out of the database on purpose, so there is nothing for one to write. }
procedure WriteScoreRow(var F: Text; C: TScoreCat);
var Ran: Integer;
begin
  Ran := ScoreCat[C].Slots - ScoreCat[C].Missing;
  Write(F, Pad(ScoreCatName(C), 7));
  if ScoreCat[C].Have then
  begin
    ScoreBar(F, ScoreCat[C].Index);
    Write(F, LeftPad(ScoreText(ScoreCat[C].Index), 9));
    if ScoreCat[C].Partial then
      Write(F, '  partial, ', Ran, '/', ScoreCat[C].Slots, ' slots');
    WriteLn(F);
  end
  else WriteLn(F, 'not run');
end;

{ Five rows and no total, on purpose (see atscore's header). Four of them are
  parts of the machine and the fifth is a workload that uses all of them; none
  of them is an average of the others. Each row is read against other
  machines' same row, never against its neighbours. }
procedure WriteScoreRows(var F: Text);
var C: TScoreCat;
begin
  ScoreCompute;
  for C := scCpu to scFrm do WriteScoreRow(F, C);
end;

procedure WriteScoreLegend(var F: Text);
var C: TScoreCat; AnyPartial: Boolean;
begin
  AnyPartial := False;
  for C := scCpu to scFrm do
    if ScoreCat[C].Have and ScoreCat[C].Partial then AnyPartial := True;
  WriteLn(F);
  { Three lines where there were five. The two that went said the baseline
    constants are still estimates and that raw metrics do not depend on them -
    true, and worth saying once in the design rather than on every screen and
    in every report: the formula version is recorded beside the numbers, which
    is what makes a later re-scoring possible in the first place.

    Under 78 columns, all of them: the report is read in a DOS window and on a
    forum, and one line of 81 wraps in both. }
  WriteLn(F, '486DX2-66 = 100 in each row.  Formula ', ScoreFormula,
          ', still on estimated constants.');
  WriteLn(F, 'Bar is logarithmic: 4 columns per doubling, full width 1.6 to ',
          '1600 points.');
  if AnyPartial then
    WriteLn(F, 'Partial: a category short of a slot is not strictly ',
            'comparable with a full run.');
end;

{ The score block, wherever it is printed. The frame headline sits between the
  rows and the legend because it is the answer the rows are evidence for - and
  it is here rather than only in ReportSummary so that no path can print the
  block without it. }
procedure WriteScore(var F: Text);
begin
  WriteScoreRows(F);
  if CmpAnyRan then
  begin
    WriteLn(F);
    WriteFrameHead(F);
  end;
  WriteScoreLegend(F);
end;

{ --- the same writers, aimed at memory ---------------------------------- }

{ Every procedure above takes a var F: Text and none of them knows or cares
  what is on the other end. That is what makes a paged screen safe: the page
  is built by the writer that builds the file, so the two cannot drift apart
  the way they would if the screen had its own copy of the formatting.

  So the other end becomes an array of lines. A Text with its own InOutFunc is
  the RTL's own mechanism for this - it is how WriteStr is implemented - and
  it costs one procedure. }

const
  CapMax = 40;

var
  CapF    : Text;
  CapLine : array[0..CapMax - 1] of String[80];
  CapN    : Integer;
  CapCur  : String[80];

  { What each captured line is: 'h' a table header, 'c' a row of cells, 'b' a
    score row, 'r' a curve row, 'm' a method row, 'k' a key and its value,
    'n' prose. Filled in by the page builder as it goes, because that is the
    one place where it is known rather than guessed. }
  LnKind  : array[0..CapMax - 1] of Char;
  LnAt    : Integer;

procedure CapPush;
begin
  if CapN < CapMax then
  begin
    CapLine[CapN] := CapCur;
    Inc(CapN);
  end;
  CapCur := '';
end;

procedure CapInOut(var T: TextRec);
var I: Integer; C: Char;
begin
  for I := 0 to T.BufPos - 1 do
  begin
    C := T.BufPtr^[I];
    if C = #10 then CapPush
    else if (C <> #13) and (Length(CapCur) < 80) then CapCur := CapCur + C;
  end;
  T.BufPos := 0;
end;

procedure CapBegin;
begin
  CapN := 0;
  LnAt := 0;
  CapCur := '';
  { Assign lays the record out - buffer, size, line ending - and then the
    three hooks say where the bytes go. No Rewrite: there is nothing to open. }
  Assign(CapF, '');
  TextRec(CapF).Mode := fmOutput;
  TextRec(CapF).OpenFunc := nil;
  TextRec(CapF).CloseFunc := nil;
  TextRec(CapF).InOutFunc := @CapInOut;
  TextRec(CapF).FlushFunc := @CapInOut;
end;

procedure CapEnd;
begin
  Flush(CapF);
  { A writer that ended without a newline still wrote a line. }
  if CapCur <> '' then CapPush;
  while LnAt < CapN do
  begin
    LnKind[LnAt] := 'n';
    Inc(LnAt);
  end;
end;

{ Everything written since the last call was of this kind. The Flush is what
  makes the boundary exact: the writer has finished its section, so the lines
  it produced are the lines that exist now. }
procedure Mark(K: Char);
begin
  Flush(CapF);
  while LnAt < CapN do
  begin
    LnKind[LnAt] := K;
    Inc(LnAt);
  end;
end;

{ As Mark, for a writer whose first line is a column header. }
procedure MarkTable(K: Char);
var First: Integer;
begin
  First := LnAt;
  Mark(K);
  if CapN > First then LnKind[First] := 'h';
end;

{ --- what each column of a line is --------------------------------------- }

{ Colour is decided about the line after it is written, never woven into it.
  The writers hand the same characters to a file, to a redirected stream and
  to the screen, and only the screen has attributes to spend; markers in the
  text would also throw off every Pad and LeftPad above, because those count
  characters. So the screen gets a second string of the same length saying
  what each column holds - built here, from the same constants the layout was
  built from.

  What a line is is recorded as it is captured (see LnKind), not recognised
  afterwards from its wording. Recognising it would be the same mistake as
  telling a sweep from a method by how its identifier is spelled. }

function MaskFill(const S: String; M: Char): String;
var R: String; I: Integer;
begin
  R := S;
  for I := 1 to Length(R) do R[I] := M;
  MaskFill := R;
end;

{ Columns A..B, one-based and clipped, but never over a space: padding has no
  colour of its own, and colouring it makes a bright block instead of a
  bright word. }
procedure MaskSet(var M: String; const S: String; A, B: Integer; C: Char);
var I: Integer;
begin
  if A < 1 then A := 1;
  if B > Length(M) then B := Length(M);
  for I := A to B do
    if S[I] <> ' ' then M[I] := C;
end;

{ A token is a measurement when it starts with a digit and is digits and
  punctuation the rest of the way, with at most one letter allowed at the very
  end for a unit stuck to it. '3573.25', '639K' and '0%' are measurements;
  'alu16' is not, because it starts with a letter, and '486DX4' is not,
  because two letters follow the digits. That is what keeps test identifiers
  and part numbers out of the colour that means "this is the figure". }
function MaskNums(const S: String): String;
var
  R       : String;
  I, B, J : Integer;
  Num     : Boolean;
begin
  R := MaskFill(S, ' ');
  I := 1;
  while I <= Length(S) do
    if S[I] = ' ' then Inc(I)
    else
    begin
      B := I;
      while (I <= Length(S)) and (S[I] <> ' ') do Inc(I);
      Num := S[B] in ['0'..'9'];
      if Num then
        for J := B to I - 1 do
          if not (S[J] in ['0'..'9', '.', ',', '%', '-']) then
            if not ((J = I - 1) and (UpCase(S[J]) in ['A'..'Z'])) then
              Num := False;
      if Num then
        for J := B to I - 1 do R[J] := UiMkNum;
    end;
  MaskNums := R;
end;

{ Wherever a line has a bar in it - the score draws one, the curve draws one -
  the UI layer knows which columns those are, because the progress line needs
  the same answer. }
procedure MaskBar(var M: String; const S: String);
var I: Integer; B: String;
begin
  B := UiBarMask(S);
  for I := 1 to Length(M) do
    if (I <= Length(B)) and (B[I] <> ' ') then M[I] := B[I];
end;

{ Two cells to the line, each of them nine columns of identifier, ten of
  number, a space, seven of unit and four of spread. The unit and the spread
  say how to read the number rather than being it, so they read as prose. }
function MaskCells(const S: String): String;
var M: String; K, O: Integer;
begin
  M := MaskNums(S);
  for K := 0 to 1 do
  begin
    O := K * (CellW + 2);
    MaskSet(M, S, O + 1, O + 9, UiMkName);
    MaskSet(M, S, O + 21, O + 31, UiMkNote);
  end;
  MaskCells := M;
end;

{ Size, bar, the reading, ' MB/s', the latency, ' ns' - the two units being
  the columns after each number rather than tokens found in the line, since
  a row with no chase for it has nothing there at all. }
function MaskCurveRow(const S: String): String;
var M: String;
begin
  M := MaskNums(S);
  MaskBar(M, S);
  MaskSet(M, S, 1, 5, UiMkName);
  MaskSet(M, S, CurveWide + 18, CurveWide + 22, UiMkNote);
  MaskSet(M, S, CurveWide + 30, CurveWide + 32, UiMkNote);
  MaskCurveRow := M;
end;

function MaskScoreRow(const S: String): String;
var M: String;
begin
  M := MaskNums(S);
  MaskBar(M, S);
  MaskSet(M, S, 1, 7, UiMkName);
  MaskScoreRow := M;
end;

function MaskMethodRow(const S: String): String;
var M: String;
begin
  M := MaskNums(S);
  MaskSet(M, S, 1, 18, UiMkName);
  MaskSet(M, S, 19, 25, UiMkNote);
  MaskMethodRow := M;
end;

{ A line whose figures are figures and whose words are prose. The base is the
  note colour rather than the plain one, which is the difference between a
  sentence that reads as a legend and a sentence that reads as a result. }
function MaskProse(const S: String): String;
var M, N: String; I: Integer;
begin
  M := MaskFill(S, UiMkNote);
  N := MaskNums(S);
  for I := 1 to Length(M) do
    if N[I] <> ' ' then M[I] := N[I];
  MaskProse := M;
end;

{ 'Frame std   2298.85 FPS     0.43 ms into VRAM 320x200 13h, tex 256...'

  Which row this is, then the two figures, then the words that say how the
  frame was drawn. The path and the tier's description are prose: they are
  what the numbers are about and not numbers themselves, which is the same
  division the result tables make between an identifier and its unit. }
function MaskFrameRow(const S: String): String;
var M: String;
begin
  M := MaskProse(S);
  MaskSet(M, S, 1, FrmKeyW, UiMkName);
  MaskFrameRow := M;
end;

{ 'CRC std    1DD1738B   the same on every machine that draws it right'

  The checksum is the figure of this row, and MaskNums will not have it -
  it is hexadecimal, so it reads as a part number and is refused for exactly
  the reason that keeps 486DX4 out of the figure colour. The column it sits
  in is known here, so it is said here. }
function MaskCrcRow(const S: String): String;
var M: String;
begin
  M := MaskProse(S);
  MaskSet(M, S, FrmKeyW + 1, FrmKeyW + 8, UiMkNum);
  MaskSet(M, S, 1, FrmKeyW, UiMkName);
  MaskCrcRow := M;
end;

{ 'std    bg  49% spr 13% ...  sum 0.57 ms  frame 0.60 ms'

  Five stages, then the sum and the frame it is held against. Every one of
  those words names something that was measured, so they take the colour the
  tables give an identifier - which is the whole of what was wrong here: the
  stage names read as filler and a sentence underneath them read as a
  heading, because a line of this shape was being coloured as though the
  first colon in it meant something.

  The columns come from the constants the row was built from (StageColW and
  its neighbours), not from looking for the words. }
function MaskStageRow(const S: String): String;
var M: String; K, At: Integer;
begin
  M := MaskProse(S);
  MaskSet(M, S, 1, StageKeyW, UiMkName);
  for K := 0 to StageN - 1 do
    MaskSet(M, S, StageKeyW + K * StageColW + 1,
                  StageKeyW + K * StageColW + 4, UiMkName);
  At := StageKeyW + StageN * StageColW;
  MaskSet(M, S, At + 1, At + 6, UiMkName);          { '  sum ' }
  MaskSet(M, S, At + 15, At + 22, UiMkName);        { '  frame ' }
  MaskStageRow := M;
end;

{ 'CPU: 486DX4 (80486), 3849 MHz estimated' - what is being reported up to
  the colon, what it says after it. }
function MaskKeyVal(const S: String): String;
var M: String; P: Integer;
begin
  M := MaskNums(S);
  P := Pos(':', S);
  if P > 0 then MaskSet(M, S, 1, P, UiMkName);
  MaskKeyVal := M;
end;

{ --- the report as pages ------------------------------------------------ }

type
  TPageKind = (pgSum, pgCpu, pgCurve, pgMeth, pgVid, pgBank, pgFrm,
               pgCmp, pgDsk);

const
  PageMax = 24;

var
  PgKind  : array[0..PageMax - 1] of TPageKind;
  PgFirst : array[0..PageMax - 1] of Integer;
  PgCount : Integer;

{ N rows of this kind, Chunk of them to a page - at least one page even when
  there are no rows at all, because a section that ran and found nothing is
  itself worth seeing. }
procedure AddPages(K: TPageKind; N, Chunk: Integer);
var I: Integer;
begin
  if Chunk < 1 then Chunk := 1;
  I := 0;
  repeat
    if PgCount >= PageMax then Exit;
    PgKind[PgCount] := K;
    PgFirst[PgCount] := I;
    Inc(PgCount);
    Inc(I, Chunk);
  until I >= N;
end;

procedure BuildPageMap;
begin
  PgCount := 0;
  { Summary first, not last as DESIGN 8.1 originally had it. The four indices
    are the answer; everything after them is the evidence, and a reader who
    wants only the answer should not have to page through forty rows of
    megabytes per second to reach it.

    Summary and system info share that page. They were one apiece, and neither
    filled half of what it had: what a machine is and what it scored are read
    together, and a page-turn between them is a page-turn for nothing. }
  AddPages(pgSum, 1, 1);
  { Two columns, so a suite takes half the lines it has results - and the CPU
    suite, which needed two pages, now needs one. The column header takes the
    other line. }
  AddPages(pgCpu, CellLines(CpuTestN), UiPageRows - 1);
  { The RAM suite is two pages and neither is a list of rows. The curve is the
    sweep, drawn; the method table is the method set, paired. Between them
    they hold every RAM figure worth reading on a screen, and the raw rows -
    which is all the third page ever was - stay in REPORT.TXT and in the
    database, where nothing is dropped for want of room. }
  AddPages(pgCurve, 1, 1);
  AddPages(pgMeth, MemMethodN, UiPageRows - 2);
  AddPages(pgVid, CellLines(VidTestN), UiPageRows - 1);
  { A page of its own for four lines, because it is not a fifth kind of VRAM
    throughput - it is what the frame costs before any of that throughput is
    spent, and folding it under the mode 13h table would file it as one more
    row there. }
  if BankTried then AddPages(pgBank, 1, 1);
  { The frame first and its rows after it. The headline, where the frame went
    and the checksum are what the suite is for; the per-stage rates are the
    evidence, and a reader who wants only the answer should not have to page
    past twenty of them to reach it. }
  if CmpAnyRan then
  begin
    CmpIndex;
    AddPages(pgFrm, 1, 1);
    AddPages(pgCmp, CellLines(CmpIxN), UiPageRows - 1);
  end;
  { The disk header is two of the page's rows and the column header a third. }
  if DskRun then AddPages(pgDsk, CellLines(DskTestN), UiPageRows - 3);
end;

function PageTitle(P: Integer): String;
var S: String;
begin
  case PgKind[P] of
    pgSum    : S := 'Summary';
    pgCpu    : S := 'CPU results';
    pgCurve  : S := 'RAM cache curve';
    pgMeth   : S := 'RAM access methods';
    pgVid    : S := 'VGA mode 13h results';
    pgBank   : S := 'VESA bank switch';
    pgFrm    : S := 'Game frame';
    pgCmp    : S := 'Composite results';
    pgDsk    : S := 'Disk results';
  else S := '';
  end;
  if PgFirst[P] > 0 then S := S + ' (continued)';
  PageTitle := S;
end;

{ A warning is a warning whatever section it turns up in, and it is the one
  line on a page that has to be seen before the page is read. }
function LineMask(K: Char; const S: String): String;
begin
  if S = '' then LineMask := ''
  else if (Copy(S, 1, 7) = 'WARNING') or (Copy(S, 1, 4) = 'NOTE') then
    LineMask := MaskFill(S, UiMkWarn)
  else
    case K of
      't' : LineMask := MaskFill(S, UiMkTitle);
      'h' : LineMask := MaskFill(S, UiMkHdr);
      'c' : LineMask := MaskCells(S);
      'b' : LineMask := MaskScoreRow(S);
      'r' : LineMask := MaskCurveRow(S);
      'm' : LineMask := MaskMethodRow(S);
      'f' : LineMask := MaskFrameRow(S);
      'g' : LineMask := MaskStageRow(S);
      'x' : LineMask := MaskCrcRow(S);
      'k' : LineMask := MaskKeyVal(S);
      'w' : LineMask := MaskFill(S, UiMkWarn);
      'e' : LineMask := MaskFill(S, UiMkErr);
    else
      LineMask := MaskFill(S, UiMkNote);
    end;
end;

function ReportLineMask(K: Char; const S: String): String;
begin
  ReportLineMask := LineMask(K, S);
end;

procedure BuildPage(P: Integer);
var I, First: Integer;
begin
  UiPageClear;
  First := PgFirst[P];
  CapBegin;
  case PgKind[P] of
    pgSum    :
      begin
        WriteScoreRows(CapF);   Mark('b');
        WriteScoreLegend(CapF); Mark('n');
        WriteLn(CapF);          Mark('n');
        WriteSystem(CapF);      Mark('k');
      end;
    pgCurve  :
      begin
        WriteCurveTable(CapF);  MarkTable('r');
        WriteCurveLegend(CapF); Mark('n');
      end;
    pgMeth   :
      begin
        WriteMethodTable(CapF, First, First + UiPageRows - 3);
        MarkTable('m');
        WriteMethodLegend(CapF); Mark('n');
      end;
    pgCpu    :
      begin
        WriteCells(CapF, CpuTestN, First, First + UiPageRows - 2, @CpuCell, True);
        MarkTable('c');
      end;
    pgVid    :
      begin
        WriteCells(CapF, VidTestN, First, First + UiPageRows - 2, @VidCell, True);
        MarkTable('c');
      end;
    pgBank   :
      begin
        WriteBank(CapF, False); Mark('k');
      end;
    pgFrm    :
      begin
        WriteFrameHead(CapF);   Mark('f');
        WriteLn(CapF);          Mark('n');
        WriteFrameStages(CapF); Mark('g');
        WriteFrameNote(CapF);   Mark('n');
        WriteLn(CapF);          Mark('n');
        WriteFrameCrc(CapF);    Mark('x');
      end;
    pgCmp    :
      begin
        CmpIndex;
        WriteCells(CapF, CmpIxN, First, First + UiPageRows - 2, @CmpCell, True);
        MarkTable('c');
      end;
    pgDsk    :
      begin
        WriteDskHead(CapF, False); Mark('k');
        WriteCells(CapF, DskTestN, First, First + UiPageRows - 4, @DskCell, False);
        MarkTable('c');
      end;
  end;
  CapEnd;
  { A suite that never ran has no rows, and an empty page under a heading
    looks like a bug rather than like an answer. }
  if CapN = 0 then UiPageAdd('(not run)');
  for I := 0 to CapN - 1 do
    UiPageAddM(CapLine[I], LineMask(LnKind[I], CapLine[I]));
end;

function PageFoot(P: Integer): String;
var S, T: String;
begin
  S := 'PgUp/PgDn: page   Home/End: first/last   Esc: back';
  Str(P + 1, T);
  S := S + '   page ' + T;
  Str(PgCount, T);
  S := S + ' of ' + T;
  PageFoot := S;
end;

procedure ReportPaged;
var P: Integer; K: Word;
begin
  BuildPageMap;
  if PgCount = 0 then Exit;
  P := 0;
  repeat
    BuildPage(P);
    K := UiPageShow(PageTitle(P), PageFoot(P));
    case K of
      UiKeyPgDn, UiKeyEnter, UiKeySpace, UiKeyRight, UiKeyDown:
        if P < PgCount - 1 then Inc(P);
      UiKeyPgUp, UiKeyLeft, UiKeyUp:
        if P > 0 then Dec(P);
      UiKeyHome : P := 0;
      UiKeyEnd  : P := PgCount - 1;
      UiKeyEsc  : P := -1;
    else
      if (K = Ord('q')) or (K = Ord('Q')) then P := -1;
    end;
  until P < 0;
  UiClear;
end;

procedure ReportScreen(AutoMode: Boolean);
begin
  { An automated run prints the whole thing and asks nothing, and a redirected
    one has no screen to page: both keep the line output they always had, and
    that output is a contract (DESIGN 13.6). }
  if UiDrawable and (not AutoMode) then
  begin
    ReportPaged;
    Exit;
  end;
  UiBeginPages(AutoMode);
  { Summary first, not last as DESIGN 8.1 originally had it. The four indices
    are the answer; everything after them is the evidence, and a reader who
    wants only the answer should not have to page through forty rows of
    megabytes per second to reach it. }
  if not UiNextPage('ATBench - Summary') then Exit;
  WriteScore(Output);
  WriteLn(Output);
  WriteSystem(Output);
  { No chunking here. This path is a stream read afterwards or scrolled
    through once, so a suite is one page however long it is - the page breaks
    that used to fall every twenty rows were the paged screen's arithmetic
    leaking into a form that has no screen. }
  if not UiNextPage('CPU results') then Exit;
  WriteCpu(Output, False);
  if not UiNextPage('RAM cache curve') then Exit;
  WriteCurve(Output);
  if not UiNextPage('RAM access methods') then Exit;
  WriteMethods(Output, 0, MemMethodN - 1);
  if not UiNextPage('RAM results') then Exit;
  WriteMem(Output, False);
  if not UiNextPage('VGA mode 13h results') then Exit;
  WriteVid(Output, False);
  if BankTried then
  begin
    if not UiNextPage('VESA bank switch') then Exit;
    WriteBank(Output, False);
  end;
  if CmpAnyRan then
  begin
    if not UiNextPage('Game frame') then Exit;
    WriteFrame(Output);
    if not UiNextPage('Composite results') then Exit;
    WriteCmp(Output, False);
  end;
  if DskRun then
  begin
    if not UiNextPage('Disk results') then Exit;
    WriteDsk(Output, False);
  end;
end;

{ The block a run ends with, and the top of the report's first page: the same
  writers either way. Printed straight out where there is no screen - that
  output is a contract (DESIGN 13.6) - and captured first where there is one,
  because a captured line is a line with a kind attached, which is what the
  colour is chosen from. }
procedure ReportSummary;
var I: Integer;
begin
  UiTitle('Score');
  if not UiDrawable then
  begin
    WriteScore(Output);
    Exit;
  end;
  CapBegin;
  WriteScoreRows(CapF);   Mark('b');
  if CmpAnyRan then
  begin
    WriteLn(CapF);        Mark('n');
    WriteFrameHead(CapF); Mark('f');
  end;
  WriteScoreLegend(CapF); Mark('n');
  CapEnd;
  for I := 0 to CapN - 1 do
    UiSay(CapLine[I], LineMask(LnKind[I], CapLine[I]));
end;

procedure ReportFrameLines;
var I: Integer;
begin
  if not UiDrawable then
  begin
    WriteFrame(Output);
    Exit;
  end;
  { The same sections WriteFrame writes, captured one at a time: a kind is
    what the colour is chosen from, and this block holds four different
    shapes of line. Capturing it as one kind is what had a sentence about
    the direct path painted as though it were a heading. }
  CapBegin;
  WriteFrameHead(CapF);   Mark('f');
  WriteLn(CapF);          Mark('n');
  WriteFrameStages(CapF); Mark('g');
  WriteFrameNote(CapF);   Mark('n');
  WriteLn(CapF);          Mark('n');
  WriteFrameCrc(CapF);    Mark('x');
  CapEnd;
  for I := 0 to CapN - 1 do
    UiSay(CapLine[I], LineMask(LnKind[I], CapLine[I]));
end;

procedure ReportBankLines;
var I: Integer;
begin
  if not UiDrawable then
  begin
    WriteBank(Output, False);
    Exit;
  end;
  CapBegin;
  WriteBank(CapF, False); Mark('k');
  CapEnd;
  for I := 0 to CapN - 1 do
    UiSay(CapLine[I], LineMask(LnKind[I], CapLine[I]));
end;

procedure WriteTextReport(var F: Text);
begin
  WriteLn(F, 'ATBench report');
  WriteLn(F, '==============');
  WriteLn(F);
  WriteLn(F, '[System]'); WriteSystem(F);
  WriteLn(F); WriteLn(F, '[Summary]'); WriteScore(F);
  WriteLn(F); WriteLn(F, '[CPU]'); WriteCpu(F, False);
  WriteLn(F); WriteLn(F, '[RAM]'); WriteCurve(F);
  WriteLn(F); WriteMethods(F, 0, MemMethodN - 1);
  WriteLn(F); WriteMem(F, False);
  WriteLn(F); WriteLn(F, '[Video]'); WriteVid(F, False);
  if BankTried then
  begin
    WriteLn(F); WriteBank(F, False);
  end;
  if CmpAnyRan then
  begin
    WriteLn(F); WriteLn(F, '[Frame]'); WriteFrame(F);
    WriteLn(F); WriteCmp(F, False);
  end;
  if DskRun then
  begin
    WriteLn(F); WriteLn(F, '[Disk]'); WriteDsk(F, False);
  end;
end;

function ReportFile(const FileName: String): Boolean;
var F: Text; E, CloseError: Word;
begin
  LastError := 0;
  Assign(F, FileName); Rewrite(F); E := IOResult;
  if E = 0 then
  begin
    WriteTextReport(F); E := IOResult;
    Close(F); CloseError := IOResult;
    if E = 0 then E := CloseError;
  end;
  LastError := E;
  ReportFile := E = 0;
end;

procedure ReportWriteAtr(var F: Text; const LabelText, NotesText: String);
var Y, Mo, D, Dow, H, Mi, S, Hu: Word;
begin
  GetDate(Y, Mo, D, Dow); GetTime(H, Mi, S, Hu);
  WriteLn(F, '[ATBench]');
  WriteLn(F, 'Version=1.0');
  { The record format's version says how to read the file; these say what
    wrote it. A comparison across two records is only a comparison of two
    machines when they agree. }
  if SysExeCrc <> 0 then
  begin
    WriteLn(F, 'ExeCrc=', Hex8(SysExeCrc));
    WriteLn(F, 'ExeSize=', SysExeSize);
  end;
  { The formula version, but no scores: DESIGN 7 keeps points out of the
    database on purpose, so that a later formula re-scores every old record
    instead of leaving it behind. }
  WriteLn(F, 'ScoreFormula=', ScoreFormula);
  WriteLn(F, 'DateTime=', Y, '-', Two(Mo), '-', Two(D), ' ',
          Two(H), ':', Two(Mi));
  WriteLn(F, 'Label=', Ascii(LabelText));
  WriteLn(F, 'Notes=', Ascii(NotesText));
  WriteLn(F, 'Emulated=', Ord(ReportEmulated));
  WriteLn(F, 'V86=', Ord(InV86));
  WriteLn(F, '[System]');
  WriteLn(F, 'CPU=', Ascii(CpuName), ', ', MhzText);
  WriteLn(F, 'FPU=', FpuClassStr);
  WriteLn(F, 'RAM=', ConvKb, ' KB conventional');
  WriteLn(F, 'Video=', Ascii(VideoKind), ' ', Ascii(VideoBios));
  if VbeOk and (VbeOem <> '') then
    WriteLn(F, 'VideoOem=', Ascii(VbeOem));
  WriteLn(F, '[Raw]');
  WriteCpu(F, True); WriteMem(F, True); WriteVid(F, True);
  if BankTried then WriteBank(F, True);
  if CmpAnyRan then WriteCmp(F, True);
  if DskRun then WriteDsk(F, True);
end;

function ReportError: Word;
begin ReportError := LastError end;

begin
  LastError := 0;
  ReportEmulated := False;
end.
