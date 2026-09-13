program EmmP0;
{ EMM386 probe 0: bare RTL, no units of ours at all.

  If this one halts the machine, nothing in ATBench is to blame - the fault
  is in FPC's msdos start-up code, and the answer is a different compiler or a
  different memory manager, not a fix in our sources.

  Output goes through the BIOS TTY call first and DOS second, so a failure
  between the two says which of them upset the memory manager. }

{$mode tp}

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
  Tty('P0: reached main, BIOS output works');
  WriteLn('P0: DOS output works');
  Tty('P0: done');
end.
