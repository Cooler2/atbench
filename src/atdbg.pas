unit atdbg;
{ ----------------------------------------------------------------------------
  ATBench - tracing for a machine that dies mid-run.

  Its own unit, depending on nothing but DOS, so that the low-level detection
  units can call it. ATUI cannot serve this purpose: it uses ATSYS, and ATSYS
  is exactly the place a trace is most needed.

  Every line goes to two destinations. The BIOS TTY call puts it on the glass
  before the next instruction runs, which is the only thing that survives
  EMM386 halting the computer. TRACE.TXT, flushed line by line, survives a
  screen that has scrolled and a machine that reset itself - a buffered trace
  of a crash describes everything except the crash.
  ---------------------------------------------------------------------------- }

interface

{$I at.inc}

procedure DbgOn(B: Boolean);
function  DbgActive: Boolean;

{ Stops after every point and waits for a key. For when even an unbuffered
  line does not reach the screen before the machine goes down. }
procedure DbgStep(B: Boolean);

procedure Dbg(const S: String);

implementation

uses dos;

var
  Active   : Boolean;
  Stepping : Boolean;
  F        : Text;
  FileOk   : Boolean;

{ BP is saved because a few BIOSes are known to clobber it in the TTY call. }
procedure TtyChar(C: Char);
begin
  asm
    push bp
    push bx
    mov  al, C
    mov  ah, 0Eh
    mov  bx, 0007h
    int  10h
    pop  bx
    pop  bp
  end;
end;

procedure TtyLine(const S: String);
var I: Integer;
begin
  for I := 1 to Length(S) do TtyChar(S[I]);
  TtyChar(#13);
  TtyChar(#10);
end;

{ Created empty and closed at once. Every line after this one opens the file,
  appends and closes it again - see Dbg. }
procedure DbgOn(B: Boolean);
var E: Word;
begin
  Active := B;
  if B and (not FileOk) then
  begin
    Assign(F, 'TRACE.TXT');
    {$I-}
    Rewrite(F); E := IOResult;
    if E = 0 then begin Close(F); E := IOResult end;
    {$I+}
    FileOk := E = 0;
  end;
end;

function DbgActive: Boolean;
begin
  DbgActive := Active;
end;

procedure DbgStep(B: Boolean);
begin
  Stepping := B;
  if B then Active := True;
end;

procedure Dbg(const S: String);
var R: Registers; E: Word;
begin
  if not Active then Exit;
  TtyLine('~ ' + S);
  { Closed after every line, not merely flushed. Flush hands the bytes to DOS,
    but the length in the directory entry is only written when the file is
    closed - so a machine that hangs leaves behind a TRACE.TXT that reads as
    empty, which is precisely the case the trace exists for. Reopening costs a
    couple of milliseconds a line and buys a trace that survives the hang. }
  if FileOk then
  begin
    {$I-}
    Append(F); E := IOResult;
    if E = 0 then
    begin
      WriteLn(F, S); E := IOResult;
      Close(F);
      if E = 0 then E := IOResult;
    end;
    {$I+}
    if E <> 0 then FileOk := False;
  end;
  if Stepping then
  begin
    R.AH := $00;
    Intr($16, R);
  end;
end;

begin
  Active := False;
  Stepping := False;
  FileOk := False;
end.
