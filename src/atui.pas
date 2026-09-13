unit atui;
{ ----------------------------------------------------------------------------
  ATBench - the text UI layer (DESIGN 13).

  Output goes straight into video memory at B800. The BIOS TTY call is one
  interrupt per character: a full 80x25 repaint is 2000 of them, which is
  visible on a 286 and happens on every keystroke in a menu. Direct stores
  make the same repaint 2000 word writes.

  CRT is not used, and the first of three reasons settles it: CRT writes past
  DOS handle 1, so ATBENCH /auto > OUT.TXT would stop filling the file - the
  only channel the correctness loop has. Beyond that, the msdos RTL is thinly
  exercised and CRT is its largest part, and the BP7 fallback in DESIGN 11
  keeps working only for code we wrote ourselves.

  Two things switch the layer off, and each is detected rather than assumed
  (DESIGN 13.5): output redirected to a file, and a real CGA, where storing
  outside the retrace produces snow and the BIOS is the honest way to write.
  What is left in those cases is plain line output, identical to what this
  program has always produced.

  An automated run is deliberately not one of them. Painting and waiting are
  different questions: painting needs a screen, waiting needs somebody in
  front of it. /auto has the first and not the second, so it paints and never
  waits.
  ---------------------------------------------------------------------------- }

interface

{$I at.inc}

const
  { INT 16h hands back an extended key as AL=0 with the scan code in AH, so
    the whole word is what names a key. }
  UiKeyEnter = $000D;
  UiKeyEsc   = $001B;
  UiKeySpace = $0020;
  UiKeyUp    = $4800;
  UiKeyDown  = $5000;
  UiKeyPgUp  = $4900;
  UiKeyPgDn  = $5100;
  UiKeyHome  = $4700;
  UiKeyEnd   = $4F00;
  UiKeyLeft  = $4B00;
  UiKeyRight = $4D00;

const
  { The screen, and the three zones of DESIGN 13.2: two rows of heading, then
    twenty-one of body, then one of status. The body is the only part a screen
    fills in for itself, which is why every screen has exactly as much room as
    every other one. }
  UiMaxCols  = 80;
  UiRows     = 25;
  UiBodyTop  = 3;
  UiBodyRows = 21;

const
  UiMenuMax = 12;

type
  { An item carries the reason it cannot be picked rather than a boolean.
    "Disabled" on its own is a dead end: the user is left guessing what would
    make it work, and the answer is always something they could do (DESIGN
    8.4). An empty reason means the item is available. }
  TUiMenuItem = record
    Key    : Char;
    Text   : String[42];
    Reason : String[28];
  end;

  TUiMenu = record
    N     : Integer;
    Cur   : Integer;
    Items : array[0..UiMenuMax - 1] of TUiMenuItem;
  end;

var
  { The attribute table, picked once at start-up (DESIGN 13.3). Colour never
    carries meaning on its own, so a mono machine losing the distinction
    loses nothing but the distinction. }
  AtNormal : Byte;
  AtBright : Byte;
  AtHead   : Byte;
  AtSel    : Byte;
  AtWarn   : Byte;
  AtErr    : Byte;

  { The colours a page of results is made of. A row of figures is four things
    at once - what was measured, what it came to, in what unit, and how much
    the passes disagreed - and on one attribute the eye has to parse the row
    to tell them apart. The measurement is the number, so the number is the
    brightest thing on the line and the prose around it steps back. }
  AtName   : Byte;   { identifiers - what was measured }
  AtHdr    : Byte;   { the row of column titles above them }
  AtNum    : Byte;   { the measurement itself }
  AtNote   : Byte;   { legends, units, everything said in sentences }
  AtBar    : Byte;   { the filled part of a bar }
  AtBarOff : Byte;   { and the groove it fills }

{ Call once, before anything is written. }
procedure UiInit(Auto: Boolean);


{ False when the screen may not be painted directly: redirected output, an
  automated run, or CGA. Callers then use ordinary Write/WriteLn. }
function  UiDrawable: Boolean;

function  UiCols: Byte;
function  UiKey: Word;
function  UiUpper(C: Char): Char;

{ Writes S at column X of row Y (both zero-based), clipped to the screen, into
  the shadow buffer. Nothing reaches the screen until UiFlush. Does not move
  the cursor and does not scroll. }
procedure UiPut(X, Y, Attr: Byte; const S: String);

{ As UiPut, but blanks the rest of the row - what a full-width line wants. }
procedure UiPutRow(Y, Attr: Byte; const S: String);

{ Pushes the rows that changed since the last call, and only those. }
procedure UiFlush;

{ The two heading rows every screen shares. Set once, repainted by UiFrame. }
procedure UiSetHead(const Title, Machine: String);

{ Heading and an empty body: what a screen calls before filling the body in.
  Forgets what was on screen first, so it is also the way back from ordinary
  DOS output, which scrolls without telling anybody. }
procedure UiFrame;
procedure UiStatus(const S: String);

{ A page of the body: a title, a blank row under it, and what is left. The
  caller fills it a line at a time and UiPageShow paints the lot and waits,
  handing back the key that ended the wait. }
const
  UiPageRows = UiBodyRows - 2;

{ A line and, optionally, what each of its characters is. The mask is one
  character per column of S, and the codes below say which attribute that
  column is painted in - anything else, the mask running short included, is
  ordinary text. The bar keeps the characters REPORT.TXT was written with, so
  that what is on screen is the same bar the file can be copy-pasted with;
  what the screen adds to it is brightness. }
const
  UiMkTitle = 't';
  UiMkName  = 'n';
  UiMkHdr   = 'h';
  UiMkNum   = 'v';
  UiMkNote  = 'o';
  UiMkWarn  = 'w';
  UiMkErr   = 'e';
  UiMkBar   = 'b';   { '#' and the half-column '-', in the bar colour }
  UiMkBarOff= '.';   { the rest of the groove, drawn as a dim '-' }

{ Which columns of a line, if any, are a bar - see UiPutMask. }
function  UiBarMask(const S: String): String;

procedure UiPutMask(X, Y: Byte; const S, Mask: String);

{ The mask for a line that is all one thing. }
function  UiMaskAll(const S: String; M: Char): String;

{ One line of the scrolling output - what a run prints while it is running -
  painted with its mask where there is a screen, and printed plainly where
  there is not. The blocks a run prints are the blocks the report prints, and
  this is what lets them be printed in the same colours. }
procedure UiSay(const S, Mask: String);

procedure UiPageClear;
procedure UiPageAdd(const S: String);
procedure UiPageAddM(const S, Mask: String);
function  UiPageShow(const Title, Foot: String): Word;

procedure UiMenuInit(var M: TUiMenu);
procedure UiMenuAdd(var M: TUiMenu; Key: Char; const Text, Reason: String);

{ Changes an item's reason after the fact - the menu is built once and the
  reasons change as the run does. }
procedure UiMenuReason(var M: TUiMenu; Key: Char; const Reason: String);

{ Runs the menu until something is picked, and hands back the hotkey of the
  chosen item (Esc gives #27, an empty line in the plain path gives #0). The
  selection survives in M, so the next call starts where this one stopped. }
function  UiMenuRun(var M: TUiMenu): Char;

{ Row the DOS cursor currently sits on - how the progress line finds the row
  ordinary output has just reached. }
function  UiCursorRow: Byte;

{ A painted screen has nothing for a cursor to mean: there is no insertion
  point, and the block sitting wherever the last store happened to end blinks
  at the reader for no reason. Hidden while a screen is painted, put back with
  its original shape the moment ordinary DOS output takes over again - DOS
  prompts do need it. }
procedure UiCursorHide;
procedure UiCursorShow;

procedure UiClear;
procedure UiTitle(const S: String);
procedure UiBar(Value, Maximum: LongWord; Width: Byte);
function  UiBarStr(Value, Maximum: LongWord; Width: Byte): String;

{ Progress is one line rewritten in place; UiProgressEnd releases it so later
  output starts on a fresh row. }
procedure UiProgress(Done, Total: Word; const S: String);
procedure UiProgressEnd;

procedure UiBeginPages(AutoMode: Boolean);
function  UiNextPage(const Title: String): Boolean;

implementation

uses dos, atsys;

const
  { Always B800. The mono adapter at B000 is not a machine this benchmark is
    ever going to run on, and detecting it would only buy a second code path
    nobody exercises. }
  ScreenSeg = $B800;

var
  Drawable  : Boolean;
  Cols      : Byte;
  CurShape  : Word;   { the shape the BIOS had before we hid it }
  CurHidden : Boolean;
  ProgLen   : Byte;   { characters the progress line still occupies }
  ProgRow   : Byte;
  PageNo    : Word;
  AutoPage  : Boolean;
  HeadTitle : String[78];
  HeadMach  : String[78];

  { The screen is assembled here and pushed out one row at a time, so a
    repaint costs a single REP MOVSW per row that changed and nothing at all
    for the rest. A menu redrawn on every arrow key is what makes this worth
    4000 bytes of the data segment (DESIGN 13.1). }
  Shadow    : array[0..UiRows - 1, 0..UiMaxCols - 1] of Word;
  Dirty     : array[0..UiRows - 1] of Boolean;

{ Bit 7 of the device word says "character device", which is what tells a
  console apart from a file. The automated run answers the same question by
  assumption; this asks it. }
function StdoutIsConsole: Boolean;
var Ok: Byte;
begin
  Ok := 0;
  asm
    push bx
    push dx
    mov  ax, 4400h
    mov  bx, 1
    int  21h
    jc   @@done
    test dx, 80h
    jz   @@done
    mov  Ok, 1
  @@done:
    pop  dx
    pop  bx
  end;
  StdoutIsConsole := Ok <> 0;
end;

procedure UiInit(Auto: Boolean);
var R: Registers;
begin
  ProgLen := 0;
  ProgRow := 0;
  PageNo := 0;
  AutoPage := Auto;
  CurHidden := False;
  FillChar(Shadow, SizeOf(Shadow), 0);
  FillChar(Dirty, SizeOf(Dirty), 0);

  { Only the width is asked for, and only because mode 13h is 40 columns wide:
    a progress line built for 80 would wrap and scroll exactly where scrolling
    costs a full BIOS frame move. }
  R.AH := $0F;
  Intr($10, R);
  Cols := R.AH;
  if Cols < 20 then Cols := 80;

  { Auto governs waiting, not drawing - see the note at the top of the unit.
    An automated run in a VM is watched by somebody even though it asks
    nothing of them, and one repainted line is what it should show instead of
    fifty scrolled ones. Redirected output still switches everything off:
    that form is a contract (DESIGN 13.6). }
  Drawable := StdoutIsConsole and (VideoKind <> 'CGA');
end;

function UiDrawable: Boolean;
begin
  UiDrawable := Drawable;
end;

function UiCols: Byte;
begin
  UiCols := Cols;
end;

function UiUpper(C: Char): Char;
begin
  if (C >= 'a') and (C <= 'z') then C := Chr(Ord(C) - 32);
  UiUpper := C;
end;

function UiCursorRow: Byte;
var R: Registers;
begin
  R.AH := $03; R.BH := $00;
  Intr($10, R);
  UiCursorRow := R.DH;
end;

{ Bit 5 of the start scan line is the BIOS's own "no cursor", so hiding and
  showing are the same call with one bit different. The shape is read back
  rather than assumed: 6-7 is the text default on a VGA and 11-12 on an MDA,
  and putting the wrong one back would leave the machine with a cursor it
  never had. }
procedure UiCursorHide;
var R: Registers;
begin
  if not Drawable then Exit;
  if CurHidden then Exit;
  R.AH := $03; R.BH := $00;
  Intr($10, R);
  CurShape := R.CX;
  { A cursor already hidden by somebody else would otherwise be saved as
    hidden and "restored" to nothing. }
  if (CurShape and $2000) <> 0 then CurShape := $0607;
  R.AH := $01; R.CX := CurShape or $2000;
  Intr($10, R);
  CurHidden := True;
end;

procedure UiCursorShow;
var R: Registers;
begin
  if not CurHidden then Exit;
  CurHidden := False;
  if not Drawable then Exit;
  R.AH := $01; R.CX := CurShape and $DFFF;
  Intr($10, R);
end;

{ One row of the shadow to the same row of the screen. The shadow row is
  always 80 words wide while the screen row is Cols wide, so mode 13h's 40
  columns take the first half of each row and the rest simply never travels. }
procedure FlushRow(Y: Byte);
var
  Src, Dst, Cnt : Word;
begin
  Src := Word(Y) * (UiMaxCols * 2);
  Dst := Word(Y) * Word(Cols) * 2;
  Cnt := Cols;
  asm
    push si
    push di
    push es
    mov  ax, ScreenSeg
    mov  es, ax
    mov  di, Dst
    lea  si, Shadow
    add  si, Src
    mov  cx, Cnt
    cld
    rep  movsw
    pop  es
    pop  di
    pop  si
  end;
end;

procedure UiFlush;
var Y: Byte;
begin
  if not Drawable then Exit;
  for Y := 0 to UiRows - 1 do
    if Dirty[Y] then
    begin
      FlushRow(Y);
      Dirty[Y] := False;
    end;
end;

{ Fills the shadow with Cell and considers the screen already to hold it.
  Cell = 0 is the "no idea what is up there" value: no paint ever produces a
  NUL on attribute zero, so every subsequent write differs and repaints. }
procedure ShadowFill(Cell: Word);
var X, Y: Integer;
begin
  for Y := 0 to UiRows - 1 do
  begin
    for X := 0 to UiMaxCols - 1 do Shadow[Y][X] := Cell;
    Dirty[Y] := False;
  end;
end;

procedure UiPut(X, Y, Attr: Byte; const S: String);
var
  Cell : Word;
  I, N : Integer;
begin
  if not Drawable then Exit;
  if (Y > UiRows - 1) or (X >= Cols) then Exit;
  N := Length(S);
  if X + N > Cols then N := Cols - X;
  for I := 1 to N do
  begin
    Cell := Word(Ord(S[I])) or (Word(Attr) shl 8);
    if Shadow[Y][X + I - 1] <> Cell then
    begin
      Shadow[Y][X + I - 1] := Cell;
      Dirty[Y] := True;
    end;
  end;
end;

procedure UiPutRow(Y, Attr: Byte; const S: String);
var T: String;
begin
  T := S;
  while Length(T) < Cols do T := T + ' ';
  UiPut(0, Y, Attr, T);
end;

{ One character, so that a line can change attribute in the middle of itself.
  Straight into the shadow rather than through UiPut: a page is 1400 columns
  and building a one-character string for each of them is 1400 heap-free but
  not free string copies on a machine where that shows. }
procedure UiPutC(X, Y, Attr: Byte; Ch: Char);
var Cell: Word;
begin
  if (Y > UiRows - 1) or (X >= Cols) then Exit;
  Cell := Word(Ord(Ch)) or (Word(Attr) shl 8);
  if Shadow[Y][X] <> Cell then
  begin
    Shadow[Y][X] := Cell;
    Dirty[Y] := True;
  end;
end;

{ The line, painted a column at a time under its mask. The bar stays the row
  of hashes the writer produced: CP437 219 and 221 were tried here and lost,
  because the curve and the summary put a bar on every row, and with no blank
  row between them solid blocks merge into one field. Hashes keep the gap
  between rows that makes them readable as separate bars. Only the empty part
  of the groove is redrawn, as a dim '-': it is filler, and dots asked to be
  read as figures. }
procedure UiPutMask(X, Y: Byte; const S, Mask: String);
var I: Integer; M, Ch: Char; A: Byte;
begin
  if not Drawable then Exit;
  for I := 1 to Length(S) do
  begin
    if I <= Length(Mask) then M := Mask[I] else M := ' ';
    Ch := S[I];
    case M of
      UiMkTitle  : A := AtBright;
      UiMkName   : A := AtName;
      UiMkHdr    : A := AtHdr;
      UiMkNum    : A := AtNum;
      UiMkNote   : A := AtNote;
      UiMkWarn   : A := AtWarn;
      UiMkErr    : A := AtErr;
      UiMkBar    : A := AtBar;
      UiMkBarOff : begin A := AtBarOff; Ch := '-' end;
    else
      A := AtNormal;
    end;
    UiPutC(X + I - 1, Y, A, Ch);
  end;
end;

{ Where the bar in a line is, if there is one: the span between the first
  '[' and the ']' after it. The report draws bars and so does the progress
  line, and both want the same span solid on a screen that can draw it. }
function UiBarMask(const S: String): String;
var I, A, B: Integer; R: String;
begin
  R := S;
  for I := 1 to Length(R) do R[I] := ' ';
  A := Pos('[', S);
  if A > 0 then
  begin
    B := A + 1;
    while (B <= Length(S)) and (S[B] <> ']') do Inc(B);
    R[A] := UiMkNote;
    if B <= Length(R) then R[B] := UiMkNote;
    for I := A + 1 to B - 1 do
      if S[I] = '.' then R[I] := UiMkBarOff else R[I] := UiMkBar;
  end;
  UiBarMask := R;
end;

function UiMaskAll(const S: String; M: Char): String;
var R: String; I: Integer;
begin
  R := S;
  for I := 1 to Length(R) do R[I] := M;
  UiMaskAll := R;
end;

{ A line of ordinary output, painted instead of printed. The characters go
  into the shadow and the newline still goes through DOS, which is what keeps
  the two in step: DOS owns the cursor and the scrolling, this owns only what
  the row says.

  The row is marked unknown first. Everything else on this screen was written
  by DOS, which has been scrolling it under the shadow buffer without telling
  anybody, so nothing the shadow claims about any row can be believed - and
  invalidating the one row about to be painted is the whole of what it takes
  to not care.

  Column zero is assumed free, the same assumption the progress line makes and
  true for the same reason: a line is said where the last one ended. }
procedure UiSay(const S, Mask: String);
var Row, I: Integer;
begin
  if not Drawable then
  begin
    WriteLn(S);
    Exit;
  end;
  Row := UiCursorRow;
  for I := 0 to UiMaxCols - 1 do Shadow[Row][I] := 0;
  UiPutMask(0, Row, S, Mask);
  for I := Length(S) to Cols - 1 do UiPutC(I, Row, AtNormal, ' ');
  UiFlush;
  WriteLn;
end;

procedure UiSetHead(const Title, Machine: String);
begin
  HeadTitle := Title;
  HeadMach  := Machine;
end;

procedure UiStatus(const S: String);
begin
  UiPutRow(UiRows - 1, AtHead, ' ' + S);
end;

procedure UiFrame;
var Y: Byte;
begin
  if not Drawable then Exit;
  UiCursorHide;
  ShadowFill(0);
  UiPutRow(0, AtHead, ' ' + HeadTitle);
  UiPutRow(1, AtHead, ' ' + HeadMach);
  UiPutRow(2, AtNormal, '');
  for Y := UiBodyTop to UiBodyTop + UiBodyRows - 1 do UiPutRow(Y, AtNormal, '');
  UiStatus('');
end;

procedure UiClear;
var R: Registers;
begin
  ProgLen := 0;
  { Whatever runs after this writes through DOS, and a DOS prompt without a
    cursor is a program that has hung. }
  UiCursorShow;
  if not Drawable then
  begin
    WriteLn;
    Exit;
  end;
  { Blank the window rather than set the mode: a mode set also reloads the
    palette, which would undo what a video test just restored. }
  R.AX := $0600; R.BH := AtNormal;
  R.CX := $0000; R.DX := $184F;
  Intr($10, R);
  R.AH := $02; R.BH := $00; R.DX := $0000;
  Intr($10, R);
  { The screen really is blank now, so the shadow says so too and a later
    paint of a blank line costs nothing. }
  ShadowFill($0020 or (Word(AtNormal) shl 8));
end;

{ A section heading in the scrolling output: the same white the paged report
  gives a page title, over a rule that is punctuation and is dim for it. }
procedure UiTitle(const S: String);
var I: Integer; U: String;
begin
  WriteLn;
  U := '';
  for I := 1 to Length(S) do U := U + '=';
  UiSay(S, UiMaskAll(S, UiMkTitle));
  UiSay(U, UiMaskAll(U, UiMkNote));
end;

function UiBarStr(Value, Maximum: LongWord; Width: Byte): String;
var I, N: Word; S: String;
begin
  if Maximum = 0 then N := 0
  else if Value >= Maximum then N := Width
  else N := LongWord(Value * Width) div Maximum;
  S := '[';
  for I := 1 to Width do
    if I <= N then S := S + '#' else S := S + '.';
  UiBarStr := S + ']';
end;

procedure UiBar(Value, Maximum: LongWord; Width: Byte);
begin
  Write(UiBarStr(Value, Maximum, Width));
end;

{ An ordinary key comes back with its character in AL and the scan code in AH,
  so the whole word is not the key: Enter is 1C0Dh on one keyboard and 0E0Dh
  after a Ctrl-M, and both are Enter. Extended keys have AL=0 and are nothing
  but their scan code. Hence: character if there is one, scan code otherwise -
  and the two can never collide, because a character normalises below 100h and
  a scan code sits above it. }
function UiKey: Word;
var R: Registers;
begin
  R.AH := $00;
  Intr($16, R);
  if R.AL <> 0 then UiKey := Word(R.AL)
  else UiKey := R.AX;
end;

{ The progress line, in the colours a results page uses: the test being run is
  an identifier, the counter is a figure, the bar is a bar, and the '/' between
  the two numbers is punctuation. A run had the bar coloured and nothing else,
  which left the one line on screen during the measuring looking like the only
  part of the program that had not been finished. }
function ProgMask(const Line: String; NameEnd: Integer): String;
var I: Integer; M: String;
begin
  M := UiBarMask(Line);
  for I := 1 to Length(Line) do
    if M[I] = ' ' then
      if I <= NameEnd then M[I] := UiMkName
      else if (Line[I] >= '0') and (Line[I] <= '9') then M[I] := UiMkNum
      else M[I] := UiMkNote;
  ProgMask := M;
end;

procedure UiProgress(Done, Total: Word; const S: String);
var
  Line, Tail, A, B             : String;
  Room, BarW, NameW, NameEnd, I : Integer;
begin
  Str(Done, A); Str(Total, B);

  { Padded on screen so that 9/54 turning into 10/54 does not shift what sits
    beside it. Redirected output keeps the plain form: that one is a contract
    (DESIGN 13.6) and cosmetics are not allowed to touch it. }
  if Drawable then
    while Length(A) < Length(B) do A := ' ' + A;
  Tail := ' ' + A + '/' + B;

  { One column stays unused: writing into the last cell scrolls the screen on
    some BIOSes, which is the one thing this line exists to avoid. }
  Room := Cols - 1 - Length(Tail);
  BarW := 30;
  if BarW > Room - 12 then BarW := Room - 12;
  if BarW < 6 then BarW := 6;

  Line := S;
  while Length(Line) + 1 + BarW + 2 > Room do Delete(Line, Length(Line), 1);

  { Test names differ in length, so a bar placed straight after the name
    starts in a different column on every test - which the eye reads as the
    whole line jumping about rather than as a bar filling up. Padding the
    name to whatever the bar leaves nails both the bar and the counter to
    fixed columns, and makes the line exactly Cols-1 wide every time. }
  if Drawable then
  begin
    NameW := Room - 1 - (BarW + 2);
    if NameW < 1 then NameW := 1;
    while Length(Line) < NameW do Line := Line + ' ';
  end;

  NameEnd := Length(Line);
  Line := Line + ' ' + UiBarStr(Done, Total, BarW) + Tail;

  { Redirected or automated: one line per test, because the output is a file
    read afterwards rather than a screen being watched. }
  if not Drawable then
  begin
    WriteLn(Line);
    Exit;
  end;

  { The cursor sits wherever ordinary output left it, and that row is the one
    to paint - so the progress line lands under the heading DOS output just
    wrote, without either of them having to track the other. }
  if ProgLen = 0 then
  begin
    ProgRow := UiCursorRow;
    { Nothing is typed at a progress line either, and this one is rewritten
      often enough that a cursor parked on it flickers. }
    UiCursorHide;
    { Ordinary output scrolled the screen to get here and the shadow knows
      nothing about it, so this row starts as unknown rather than as whatever
      stood on it during the previous suite. }
    for I := 0 to UiMaxCols - 1 do Shadow[ProgRow][I] := 0;
  end;
  UiPutMask(0, ProgRow, Line, ProgMask(Line, NameEnd));
  for I := Length(Line) to ProgLen - 1 do UiPut(I, ProgRow, AtNormal, ' ');
  ProgLen := Length(Line);
  UiFlush;
end;

procedure UiProgressEnd;
var R: Registers;
begin
  if ProgLen = 0 then Exit;
  ProgLen := 0;
  if not Drawable then Exit;
  { Nothing went through DOS while the line was being repainted, so the cursor
    never moved off that row; step it down so later output clears the line. }
  R.AH := $02; R.BH := $00;
  R.DH := ProgRow + 1; R.DL := 0;
  if R.DH > 24 then R.DH := 24;
  Intr($10, R);
  UiCursorShow;
end;

procedure UiBeginPages(AutoMode: Boolean);
begin
  PageNo := 0;
  AutoPage := AutoMode;
end;

function UiNextPage(const Title: String): Boolean;
var R: Registers;
begin
  UiNextPage := True;
  if PageNo <> 0 then
  begin
    if AutoPage then WriteLn
    else
    begin
      Write('PgDn/Enter: next, Esc: stop ');
      R.AH := $00;
      Intr($16, R);
      WriteLn;
      if R.AL = 27 then
      begin
        UiNextPage := False;
        Exit;
      end;
    end;
  end;
  Inc(PageNo);
  UiTitle(Title);
end;

{ ------------------------------------------------------------------- page }

var
  PgLine : array[0..UiPageRows - 1] of String[80];
  PgMask : array[0..UiPageRows - 1] of String[80];
  PgN    : Integer;

procedure UiPageClear;
begin
  PgN := 0;
end;

procedure UiPageAddM(const S, Mask: String);
begin
  if PgN >= UiPageRows then Exit;
  PgLine[PgN] := S;
  PgMask[PgN] := Mask;
  Inc(PgN);
end;

procedure UiPageAdd(const S: String);
begin
  UiPageAddM(S, '');
end;

function UiPageShow(const Title, Foot: String): Word;
var I: Integer;
begin
  UiFrame;
  UiPut(2, UiBodyTop, AtBright, Title);
  for I := 0 to PgN - 1 do
    UiPutMask(2, UiBodyTop + 2 + I, PgLine[I], PgMask[I]);
  UiStatus(Foot);
  UiFlush;
  UiPageShow := UiKey;
end;

{ ------------------------------------------------------------------- menu }

procedure UiMenuInit(var M: TUiMenu);
begin
  M.N := 0;
  M.Cur := 0;
end;

procedure UiMenuAdd(var M: TUiMenu; Key: Char; const Text, Reason: String);
begin
  if M.N >= UiMenuMax then Exit;
  M.Items[M.N].Key := Key;
  M.Items[M.N].Text := Text;
  M.Items[M.N].Reason := Reason;
  Inc(M.N);
end;

procedure UiMenuReason(var M: TUiMenu; Key: Char; const Reason: String);
var I: Integer;
begin
  for I := 0 to M.N - 1 do
    if UiUpper(M.Items[I].Key) = UiUpper(Key) then M.Items[I].Reason := Reason;
end;

function MenuOpen(var M: TUiMenu; I: Integer): Boolean;
begin
  MenuOpen := (I >= 0) and (I < M.N) and (M.Items[I].Reason = '');
end;

{ Moves the selection Delta items, skipping over what cannot be picked and
  wrapping at both ends. An unpickable item is never left under the cursor:
  its reason is on screen beside it either way, so stopping on it would only
  offer an Enter that does nothing. }
procedure MenuStep(var M: TUiMenu; Delta: Integer);
var I, P: Integer;
begin
  if M.N = 0 then Exit;
  P := M.Cur;
  for I := 1 to M.N do
  begin
    P := P + Delta;
    if P < 0 then P := M.N - 1;
    if P > M.N - 1 then P := 0;
    if MenuOpen(M, P) then
    begin
      M.Cur := P;
      Exit;
    end;
  end;
end;

procedure MenuFirst(var M: TUiMenu; From, Delta: Integer);
begin
  M.Cur := From;
  if not MenuOpen(M, M.Cur) then MenuStep(M, Delta);
end;

const
  MenuLeft = 8;
  MenuWide = 64;
  MenuWhy  = 36;   { column the reason starts in }

procedure MenuPaint(var M: TUiMenu; const Msg: String);
var
  I, Y : Integer;
  A    : Byte;
  Line : String;
begin
  UiFrame;
  Y := UiBodyTop + 1;
  for I := 0 to M.N - 1 do
  begin
    Line := ' ' + M.Items[I].Key + '  ' + M.Items[I].Text;
    if M.Items[I].Reason <> '' then
    begin
      while Length(Line) < MenuWhy do Line := Line + ' ';
      Line := Line + '[' + M.Items[I].Reason + ']';
    end;
    while Length(Line) < MenuWide do Line := Line + ' ';

    { Three states and three attributes, but the attribute is never what says
      which is which: the selected row is the one under the cursor keys, and
      an unavailable row is the one carrying a reason (DESIGN 13.3). }
    if I = M.Cur then A := AtSel
    else if M.Items[I].Reason <> '' then A := AtNormal
    else A := AtBright;
    UiPut(MenuLeft, Y, A, Line);
    Inc(Y);
  end;

  if Msg <> '' then UiStatus(Msg)
  else UiStatus('Up/Down: select   Enter: run   letter or digit: straight to it   Esc: quit');
  UiFlush;
end;

{ The plain path: no screen to paint on, so the menu is a list and the answer
  comes off a line. This is what a redirected or CGA session gets, and it is
  what this program printed before there was anything else. }
function MenuPlain(var M: TUiMenu): Char;
var I: Integer; S, Line: String;
begin
  WriteLn;
  WriteLn(HeadTitle);
  WriteLn(HeadMach);
  WriteLn;
  for I := 0 to M.N - 1 do
  begin
    Line := M.Items[I].Key + '  ' + M.Items[I].Text;
    if M.Items[I].Reason <> '' then
    begin
      while Length(Line) < MenuWhy - 1 do Line := Line + ' ';
      Line := Line + '[' + M.Items[I].Reason + ']';
    end;
    WriteLn(Line);
  end;
  WriteLn;
  Write('Choice: '); ReadLn(S);
  if S = '' then MenuPlain := #0 else MenuPlain := UiUpper(S[1]);
end;

function UiMenuRun(var M: TUiMenu): Char;
var
  K    : Word;
  C    : Char;
  I    : Integer;
  Msg  : String;
begin
  if M.N = 0 then
  begin
    UiMenuRun := #27;
    Exit;
  end;
  if not Drawable then
  begin
    UiMenuRun := MenuPlain(M);
    Exit;
  end;

  if (M.Cur < 0) or (M.Cur > M.N - 1) then M.Cur := 0;
  if not MenuOpen(M, M.Cur) then MenuStep(M, 1);
  Msg := '';
  repeat
    MenuPaint(M, Msg);
    Msg := '';
    K := UiKey;
    case K of
      UiKeyUp   : MenuStep(M, -1);
      UiKeyDown : MenuStep(M,  1);
      UiKeyHome : MenuFirst(M, 0, 1);
      UiKeyEnd  : MenuFirst(M, M.N - 1, -1);
      UiKeyEsc  : begin UiMenuRun := #27; Exit end;
      UiKeyEnter:
        if MenuOpen(M, M.Cur) then
        begin
          UiMenuRun := M.Items[M.Cur].Key;
          Exit;
        end;
    else
      { Hotkeys keep working alongside the arrows: on a machine of this era an
        arrow can be lost by a doubtful keyboard controller or a KVM, and a
        digit still arrives (DESIGN 13.4). Pressing the key of an unavailable
        item answers with its reason rather than with silence. }
      if Lo(K) <> 0 then
      begin
        C := UiUpper(Chr(Lo(K)));
        for I := 0 to M.N - 1 do
          if UiUpper(M.Items[I].Key) = C then
            if MenuOpen(M, I) then
            begin
              M.Cur := I;
              MenuPaint(M, '');
              UiMenuRun := M.Items[I].Key;
              Exit;
            end
            else Msg := 'Not available: ' + M.Items[I].Reason;
      end;
    end;
  until False;
end;

begin
  { Safe defaults for the window between program start and UiInit. }
  Drawable := False;
  Cols := 80;
  ProgLen := 0;
  ProgRow := 0;
  PageNo := 0;
  AutoPage := False;
  CurShape := $0607;
  CurHidden := False;
  HeadTitle := '';
  HeadMach := '';
  FillChar(Shadow, SizeOf(Shadow), 0);
  FillChar(Dirty, SizeOf(Dirty), 0);
  AtNormal := $07; AtBright := $0F; AtHead := $1F;
  AtSel := $70; AtWarn := $0E; AtErr := $0C;
  { Cyan for what a thing is called, white for what it measured, dark grey
    for the sentences in between, green for a bar. On a VGA driven by a mono
    monitor these are distinguishable greys, which is the most any of this is
    asked to be: nothing here is said in colour alone (DESIGN 13.3).

    The column titles are the same cyan one step down. They name the same
    things the identifiers under them do, so they belong to that hue - but a
    header row in the identifier colour makes the table's first row read as
    one more result, which is what the dimmer shade fixes.

    The bar is dark green, not bright: it is thirty columns wide and repeats
    on every row of a table, and at that size the brightest thing on the page
    should still be the figure the bar only illustrates. }
  AtName := $0B; AtHdr := $03; AtNum := $0F; AtNote := $08;
  AtBar := $02; AtBarOff := $08;
end.
