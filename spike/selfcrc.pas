program selfcrc;
{ ----------------------------------------------------------------------------
  Does the program read itself correctly?

  SysExeCrc streams the file the program was loaded from through the same
  CRC32 the frame checksum uses, and the report prints it so that two reports
  can be told apart by the binary that wrote them. The way that goes wrong is
  quiet - a short read, a dropped final block, a checksum of nothing at all -
  and the report would carry a plausible number that means nothing.

  So this prints the number and the length, and whoever runs it holds them
  against what the host says about the same file. There is no way for the
  program to check this on its own: it is exactly the question of whether the
  file on the disk and the bytes we read are the same thing.
  ---------------------------------------------------------------------------- }

uses atsys;

{$I at.inc}

var C: LongInt;
begin
  C := SysExeCrc;
  WriteLn('exe crc ', C, ' size ', SysExeSize);
  WriteLn('done');
end.
