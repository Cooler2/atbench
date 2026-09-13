unit atdb;
{ The iteration-1 database slice: create DB, allocate NNNN.ATR names and save. }

interface

{$I at.inc}

function DbSave(const LabelText, NotesText: String; var FileName: String): Boolean;
function DbCount: Word;
function DbError: Word;

implementation

uses dos, atrep;

var LastError: Word;

function Four(N: Word): String;
var S: String;
begin
  Str(N, S);
  while Length(S) < 4 do S := '0' + S;
  Four := S;
end;

function Exists(const Name: String): Boolean;
var R: SearchRec;
begin
  FindFirst(Name, AnyFile, R);
  Exists := DosError = 0;
  if DosError = 0 then FindClose(R);
end;

function EnsureDir: Boolean;
var E: Word;
begin
  if Exists('DB') then begin EnsureDir := True; Exit end;
  MkDir('DB'); E := IOResult;
  LastError := E;
  EnsureDir := E = 0;
end;

function DbSave(const LabelText, NotesText: String; var FileName: String): Boolean;
var F: Text; I, E, CloseError: Word;
begin
  DbSave := False; FileName := ''; LastError := 0;
  if not EnsureDir then Exit;
  I := 1;
  while (I < 10000) and Exists('DB\' + Four(I) + '.ATR') do Inc(I);
  if I >= 10000 then begin LastError := 4; Exit end;
  FileName := 'DB\' + Four(I) + '.ATR';
  Assign(F, FileName); Rewrite(F); E := IOResult;
  if E = 0 then
  begin
    ReportWriteAtr(F, LabelText, NotesText); E := IOResult;
    Close(F); CloseError := IOResult;
    if E = 0 then E := CloseError;
  end;
  LastError := E;
  if E <> 0 then FileName := '';
  DbSave := E = 0;
end;

function DbCount: Word;
var R: SearchRec; C: Word;
begin
  C := 0;
  FindFirst('DB\*.ATR', Archive or ReadOnly, R);
  if DosError <> 0 then begin DbCount := 0; Exit end;
  while DosError = 0 do
  begin
    Inc(C); FindNext(R);
  end;
  FindClose(R);
  DbCount := C;
end;

function DbError: Word;
begin DbError := LastError end;

begin
  LastError := 0;
end.
