program EmmP1;
{ EMM386 probe 1: every ATBench unit linked in, not one of them called.

  Units run their initialisation sections before the program's first
  statement, which is precisely the window /trace cannot report on: if ATBENCH
  dies before printing its first trace line, the fault is in there. This probe
  narrows that down to yes or no in one run - reaching "P1: done" means every
  initialisation section survived and the trouble is in code we can trace. }

{$mode tp}

uses attime, atharn, atcpuid, atsys, atmemx, attcpu, attmem,
     attvid, attdsk, atscore, atui, atrep, atdb;

procedure Tty(const S: String);
var I: Integer; C: Char;
begin
  for I := 1 to Length(S) do
  begin
    C := S[I];
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
  C := #13;
  asm
    push bp
    push bx
    mov  al, C
    mov  ah, 0Eh
    mov  bx, 0007h
    int  10h
    mov  al, 10
    mov  ah, 0Eh
    mov  bx, 0007h
    int  10h
    pop  bx
    pop  bp
  end;
end;

begin
  Tty('P1: all units initialised, reached main');
  WriteLn('P1: DOS output works');
  Tty('P1: done');
end.
