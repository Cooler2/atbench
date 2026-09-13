program vbebank;
{ ----------------------------------------------------------------------------
  Spike: what the VBE BIOS says about mode 101h, and how far a bank switch
  gets before something stops.

  ATTVBE does all of this inside the harness, which means a machine that dies
  on one of these steps dies with nothing on the screen. This walks the same
  steps one at a time, unbuffered, and prints the ModeInfoBlock fields the
  unit decides on - so the answer to "why did it skip" or "where did it hang"
  is on the glass rather than inferred.
  ---------------------------------------------------------------------------- }

uses atdbg, attime;

{$I at.inc}

var
  Buf     : array[0..511] of Byte;
  MiBuf   : array[0..255] of Byte;
  WinSeg  : Word;
  WinNo   : Word;
  Step    : Word;
  Func    : record Ofs, Seg: Word end;
  OldMode : Byte;

function Hex4(V: Word): String;
const D: array[0..15] of Char = '0123456789ABCDEF';
var I: Integer; R: String;
begin
  R := '';
  for I := 3 downto 0 do R := R + D[(V shr (I * 4)) and 15];
  Hex4 := R;
end;

function MiWord(At: Word): Word;
begin
  MiWord := MiBuf[At] or (Word(MiBuf[At + 1]) shl 8);
end;

function GetInfo: Boolean;
var Ok: Byte;
begin
  FillChar(Buf, SizeOf(Buf), 0);
  Buf[0] := Byte('V'); Buf[1] := Byte('B');
  Buf[2] := Byte('E'); Buf[3] := Byte('2');
  Ok := 0;
  asm
    push si
    push di
    push es
    mov  ax, ds
    mov  es, ax
    lea  di, Buf
    mov  ax, 4F00h
    int  10h
    cmp  ax, 004Fh
    jne  @@no
    mov  Ok, 1
  @@no:
    pop  es
    pop  di
    pop  si
  end;
  GetInfo := Ok = 1;
end;

function GetModeInfo: Boolean;
var Ok: Byte;
begin
  FillChar(MiBuf, SizeOf(MiBuf), 0);
  Ok := 0;
  asm
    push si
    push di
    push es
    mov  ax, ds
    mov  es, ax
    lea  di, MiBuf
    mov  ax, 4F01h
    mov  cx, 0101h
    int  10h
    cmp  ax, 004Fh
    jne  @@no
    mov  Ok, 1
  @@no:
    pop  es
    pop  di
    pop  si
  end;
  GetModeInfo := Ok = 1;
end;

function CurrentMode: Byte; assembler;
asm
    mov ah, 0Fh
    int 10h
end;

procedure SetMode(Mode: Byte); assembler;
asm
    mov ah, 00h
    mov al, Mode
    int 10h
end;

function SetBankMode: Boolean;
var Ok: Byte;
begin
  Ok := 0;
  asm
    push si
    push di
    mov  ax, 4F02h
    mov  bx, 0101h
    int  10h
    cmp  ax, 004Fh
    jne  @@no
    mov  Ok, 1
  @@no:
    pop  di
    pop  si
  end;
  SetBankMode := Ok = 1;
end;

function SetWindow(Pos: Word): Boolean;
var Ok: Byte;
begin
  Ok := 0;
  asm
    push si
    push di
    mov  ax, 4F05h
    mov  bx, WinNo
    mov  dx, Pos
    int  10h
    cmp  ax, 004Fh
    jne  @@no
    mov  Ok, 1
  @@no:
    pop  di
    pop  si
  end;
  SetWindow := Ok = 1;
end;

{ One switch through the far pointer, on its own, so that a BIOS whose window
  function is not callable this way takes the machine down here - where the
  line before it says exactly that - and not inside a timing loop. }
procedure DirectWindow(Pos: Word); assembler;
asm
    push si
    push di
    push bp
    push ds
    push es
    mov  bx, WinNo
    mov  dx, Pos
    call far [Func]
    pop  es
    pop  ds
    pop  bp
    pop  di
    pop  si
end;

{ How long N pairs of switches take, in microseconds, timed the way the
  harness times them. The harness decides how much work fits in 25 ms from
  exactly this measurement, so a stamp that reads zero here is a harness that
  keeps doubling until it is doing 65536 switches in one uninterruptible
  call. }
function TimeInt(N: Word): LongWord;
var T0, T1: TStamp; I: Word;
begin
  T0 := Stamp;
  for I := 1 to N do
  begin
    SetWindow(0);
    SetWindow(Step);
  end;
  T1 := Stamp;
  TimeInt := StampUs(StampDiff(T0, T1));
end;

function TimeDir(N: Word): LongWord;
var T0, T1: TStamp; I: Word;
begin
  T0 := Stamp;
  for I := 1 to N do
  begin
    DirectWindow(0);
    DirectWindow(Step);
  end;
  T1 := Stamp;
  TimeDir := StampUs(StampDiff(T0, T1));
end;

var
  I    : Integer;
  A, B : Byte;
  Attr : Word;
  Us, UsK, UsD : LongWord;

begin
  DbgOn(True);
  Dbg('vbebank: 4F00h');
  if not GetInfo then
  begin
    WriteLn('no VBE BIOS');
    Halt(1);
  end;
  WriteLn('VBE ', Hex4(Buf[4] or (Word(Buf[5]) shl 8)),
          '  memory ', (Buf[18] or (Word(Buf[19]) shl 8)) * 64, ' KB');

  Dbg('vbebank: 4F01h');
  if not GetModeInfo then
  begin
    WriteLn('mode 101h not described');
    Halt(1);
  end;

  Attr := MiWord(0);
  WriteLn('ModeAttributes  = ', Hex4(Attr), 'h');
  WriteLn('WinAAttributes  = ', Hex4(MiBuf[2]), 'h');
  WriteLn('WinBAttributes  = ', Hex4(MiBuf[3]), 'h');
  WriteLn('WinGranularity  = ', MiWord(4), ' KB');
  WriteLn('WinSize         = ', MiWord(6), ' KB');
  WriteLn('WinASegment     = ', Hex4(MiWord(8)), 'h');
  WriteLn('WinBSegment     = ', Hex4(MiWord(10)), 'h');
  WriteLn('WinFuncPtr      = ', Hex4(MiWord(14)), ':', Hex4(MiWord(12)));
  WriteLn('BytesPerScanLine= ', MiWord(16));

  Func.Ofs := MiWord(12);
  Func.Seg := MiWord(14);
  if (MiBuf[2] and 7) = 7 then WinNo := 0
  else if (MiBuf[3] and 7) = 7 then WinNo := 1
  else
  begin
    WriteLn('no window that both reads and writes; stopping here');
    Halt(1);
  end;
  if WinNo = 0 then WinSeg := MiWord(8) else WinSeg := MiWord(10);
  if MiWord(4) = 0 then begin WriteLn('granularity 0'); Halt(1) end;
  Step := MiWord(6) div MiWord(4);
  if Step = 0 then Step := 1;
  WriteLn('using window ', WinNo, ' at ', Hex4(WinSeg), 'h, step ', Step);

  Dbg('vbebank: 4F02h set 101h');
  OldMode := CurrentMode;
  if not SetBankMode then
  begin
    WriteLn('mode 101h would not set');
    Halt(1);
  end;

  Dbg('vbebank: 4F05h window 0');
  A := 0; B := 0;
  if SetWindow(0) then
  begin
    Mem[WinSeg:0] := $A5;
    Dbg('vbebank: 4F05h window 1');
    if SetWindow(Step) then
    begin
      Mem[WinSeg:0] := $5A;
      if SetWindow(0) then A := Mem[WinSeg:0];
      if SetWindow(Step) then B := Mem[WinSeg:0];
    end;
  end;

  Dbg('vbebank: 4F05h x 100');
  for I := 1 to 100 do
  begin
    SetWindow(0);
    SetWindow(Step);
  end;

  if (Func.Seg <> 0) or (Func.Ofs <> 0) then
  begin
    Dbg('vbebank: direct window function');
    DirectWindow(0);
    Dbg('vbebank: direct returned');
    DirectWindow(Step);
    Dbg('vbebank: direct x 100');
    for I := 1 to 100 do
    begin
      DirectWindow(0);
      DirectWindow(Step);
    end;
  end;

  { The same work again, timed - with the timer installed, which is the one
    thing the benchmark does here that this spike did not. }
  Dbg('vbebank: TimerInstall');
  TimerInstall;
  Dbg('vbebank: timed 100');
  Us := TimeInt(100);
  Dbg('vbebank: timed 1000');
  UsK := TimeInt(1000);
  Dbg('vbebank: timed direct 1000');
  UsD := TimeDir(1000);
  Dbg('vbebank: TimerRemove');
  TimerRemove;

  Dbg('vbebank: mode restore');
  SetMode(OldMode and $7F);

  WriteLn('bank 0 marker = ', Hex4(A), 'h (want 00A5h)');
  WriteLn('bank 1 marker = ', Hex4(B), 'h (want 005Ah)');
  if (Func.Seg = 0) and (Func.Ofs = 0) then
    WriteLn('no window function published')
  else
    WriteLn('window function survived 202 calls');
  WriteLn('INT 10h    200 switches: ', Us, ' us');
  WriteLn('INT 10h   2000 switches: ', UsK, ' us');
  WriteLn('direct    2000 switches: ', UsD, ' us');
  Dbg('vbebank: done');
end.
