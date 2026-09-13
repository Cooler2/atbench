unit atscore;
{ ----------------------------------------------------------------------------
  ATBench - the indices: four parts of a machine, one workload, and
  deliberately no total over them.

  The database keeps physical metrics, never points (DESIGN 7). This unit is
  what turns them into points, at report time, so a change of formula
  re-scores every run ever recorded instead of obsoleting it.

  Three decisions shape everything below.

  1. A slot is a *task*, not an instruction. "Fill the frame" is one slot with
     seven candidates - REP STOS at three widths, an unrolled loop at two, an
     8-byte FPU store and MOVQ - and the machine is credited with whichever it
     managed fastest. That is how a 286 and a Pentium MMX end up being scored
     on the same list of slots rather than on two different lists, and it is
     why MMX earns points only where it actually moves more bytes. There is
     deliberately no "MMX bonus" slot: that is the failure mode DESIGN 7 warns
     about, one exotic result towing the whole category.

     The corollary is that a candidate list should hold every way the machine
     might do the job, not the way it is expected to. REP MOVS beats a plain
     loop on some processors of this era and loses on others, and an FPU copy
     beat both on more than one; leaving any of them out would score a machine
     on the second-best thing it can do.

  2. Every candidate carries its own baseline, and the slot takes the best
     *ratio*, not the best raw number. Candidates that do identical work share
     one baseline, so the comparison stays a comparison of speed; candidates
     that do different work - a 512 KB read standing in for a 128 KB one when
     the machine has no memory to spare - carry different baselines, so the
     substitution is still normalised against the same reference machine doing
     the same thing.

  3. Op-rate slots name exactly one test, always the 16-bit one. Mixing alu16
     and alu32 in a chain would compare rates for operations of different
     widths and quietly reward the wider one twice. The 32-bit tests stay in
     the report as diagnostics and out of the index.

  Composition. Category index = weighted geometric mean of its slots,
  normalised so the reference machine scores 100. There is no index above
  that: the four suites are four independent benchmarks that happen to share
  a program, and a machine fast at CPU and slow at disk has no single honest
  speed. Within a category the sub-tests are at least commensurable - they all
  answer "how fast does this part go" - and across categories they are not,
  so the weights of such a total would be pure taste with a number attached.

  Frame is the fifth row and is not a fifth suite. The other four ask how fast
  one part of the machine goes; that one runs a game frame and asks how fast
  the machine goes. It is allowed to combine what the others may not, because
  the proportions in it were not chosen here - they are the proportions the
  workload has. Which is also why it is a row and not a total: it does not
  average the four above it, it measures something they cannot.

  Geometric, per DESIGN 7, and with a useful side
  effect: geomean(x/b) = geomean(x)/geomean(b), so the whole baseline vector
  collapses into one constant per category. The reference machine decides
  where "100" sits and nothing else - it cannot change the ratio between two
  measured machines. What does change it is a *missing* slot, because then the
  two geometric means run over different sets and the constants stop
  cancelling. That is why a category with anything missing is marked partial
  and says so in the report.

  Arithmetic. No floating point anywhere, not even here where nothing is being
  timed: the machine may have no FPU, and pulling in the soft-float RTL to
  print a summary is not a trade worth making. Everything runs in Q16.16
  fixed-point logarithms - Log2Fix to get in, Pow2Fix to get out - which also
  removes every division and every overflow risk from the mean itself.
  ---------------------------------------------------------------------------- }

interface

uses attcpu, attmem, attvid, attdsk, attcmp;

{$I at.inc}

const
  { Bumped whenever a slot, a weight or a baseline changes. Written into the
    report and into the database header so an old record and a new one are
    never silently compared on different formulas. }
  ScoreFormula = 2;

  MaxSlots = 28;
  MaxCands = 8;

type
  TScoreCat = (scCpu, scMem, scVid, scDsk, scFrm);

  TScoreSlot = record
    Cat      : TScoreCat;
    Name     : String[18];
    Weight   : Byte;
    NCand    : Byte;
    CandId   : array[0..MaxCands - 1] of String[10];
    CandBase : array[0..MaxCands - 1] of LongWord;  { reference value, millionths }
  end;

  TScoreSlotRes = record
    Ran    : Boolean;
    Won    : String[10];   { the candidate that supplied the number }
    Value  : LongWord;
    Base   : LongWord;
    Points : LongWord;     { hundredths of a point; 10000 = the reference }
  end;

  TScoreCatRes = record
    Have    : Boolean;     { at least one slot produced a number }
    Partial : Boolean;     { at least one slot did not }
    Slots   : Byte;
    Missing : Byte;
    MeanLog : LongInt;     { weighted mean log2 ratio, Q16.16 }
    Index   : LongWord;    { hundredths of a point }
  end;

var
  ScoreSlots   : array[0..MaxSlots - 1] of TScoreSlot;
  ScoreSlotRes : array[0..MaxSlots - 1] of TScoreSlotRes;
  ScoreSlotN   : Integer;

  ScoreCat : array[TScoreCat] of TScoreCatRes;

{ Builds the slot table. Idempotent; ScoreCompute calls it if needed. }
procedure ScoreInit;

{ Reads the four suites' result arrays and fills ScoreSlotRes and ScoreCat.
  Cheap - call it every time a report is produced rather than caching, so it
  can never disagree with the results on screen. }
procedure ScoreCompute;

function ScoreCatName(C: TScoreCat): String;

{ Hundredths of a point to '123.4'. }
function ScoreText(Hundredths: LongWord): String;

{ Empty when the fixed-point logarithms agree with known values. }
function ScoreSelfCheck: String;

implementation

{ ---------------------------------------------------------------------------
  Fixed-point logarithms.

  Log2Fix returns log2(V) as Q16.16 by the classic bit-by-bit method: strip
  the exponent, then square the mantissa sixteen times and read off a bit
  whenever the square leaves [1,2). The mantissa is held in Q15 rather than
  Q16 for one reason - 65535 squared is 4294836225, which is the largest
  square that still fits in a LongWord, so the whole thing runs in 32-bit
  integers with no 64-bit helper anywhere.
  --------------------------------------------------------------------------- }

const
  { log2(100) in Q16.16. Doubling it converts a log2 ratio straight into
    hundredths of a point: 100 * 2^L expressed in hundredths is 2^(L + 2*this). }
  Log2Hundred = 435411;
  ToPoints    = 2 * Log2Hundred;

  { 2^(2^-j) in Q15, j = 1..16. Past j = 14 the factor is below the resolution
    of Q15 and contributes nothing; the entries are kept so the loop stays a
    plain loop over all sixteen fraction bits. }
  Pow2Tab : array[1..16] of LongWord =
    (46341, 38968, 35734, 34219, 33487, 33125, 32946, 32857,
     32812, 32790, 32779, 32774, 32771, 32769, 32769, 32768);

function Log2Fix(V: LongWord): LongInt;
var
  N, I : Integer;
  M, F : LongWord;
begin
  if V = 0 then
  begin
    Log2Fix := -(LongInt(32) shl 16);   { far below anything real }
    Exit;
  end;

  N := 0; M := V;
  while M >= 2 do begin M := M shr 1; Inc(N) end;

  { mantissa in Q15, i.e. V / 2^N scaled by 32768 }
  if N >= 15 then M := V shr (N - 15) else M := V shl (15 - N);

  F := 0;
  for I := 1 to 16 do
  begin
    M := (M * M) shr 15;
    if M >= 65536 then
    begin
      F := F or (LongWord(1) shl (16 - I));
      M := M shr 1;
    end;
  end;

  Log2Fix := (LongInt(N) shl 16) + LongInt(F);
end;

{ 2^T rounded to an integer, T in Q16.16. Zero below 1, saturated above. }
function Pow2Fix(T: LongInt): LongWord;
var
  N, J : Integer;
  R, F : LongWord;
begin
  if T < 0 then begin Pow2Fix := 0; Exit end;
  if T > (LongInt(30) shl 16) then begin Pow2Fix := $FFFFFFFF; Exit end;

  N := T shr 16;
  F := LongWord(T) and $FFFF;

  R := 32768;                       { Q15 one }
  for J := 1 to 16 do
    if (F and (LongWord(1) shl (16 - J))) <> 0 then
    begin
      R := (R * Pow2Tab[J]) shr 15;
      { The product of every factor is under 2, so R stays inside Q15 and this
        never fires. It is here because "never" is a claim about the table. }
      if R >= 65536 then begin R := R shr 1; Inc(N) end;
    end;

  if N >= 15 then Pow2Fix := R shl (N - 15)
  else Pow2Fix := (R + (LongWord(1) shl (14 - N))) shr (15 - N);
end;

{ --------------------------------------------------------------------------
  The slot table.

  Baselines are one 486DX2-66 with 8 KB write-through L1, 256 KB write-back
  L2, 60 ns FPM memory, a VLB SVGA card and an early IDE drive. They are
  ESTIMATES until a run on that machine replaces them, and replacing them
  changes only where 100 sits - see the header. Values use the convention
  every suite uses: the metric in millionths, so 50000000 is 50.0 Mops/s and
  2500000 is 2.5 MB/s.
  -------------------------------------------------------------------------- }

procedure AddSlot(C: TScoreCat; const Nm: String; W: Byte);
begin
  if ScoreSlotN >= MaxSlots then Exit;
  ScoreSlots[ScoreSlotN].Cat    := C;
  ScoreSlots[ScoreSlotN].Name   := Nm;
  ScoreSlots[ScoreSlotN].Weight := W;
  ScoreSlots[ScoreSlotN].NCand  := 0;
  Inc(ScoreSlotN);
end;

{ Appends a candidate to the slot added last. Order is preference order only
  for readability - the winner is chosen by ratio, not by position. }
procedure AddCand(const Id: String; Base: LongWord);
var S, N: Integer;
begin
  if ScoreSlotN = 0 then Exit;
  S := ScoreSlotN - 1;
  N := ScoreSlots[S].NCand;
  if N >= MaxCands then Exit;
  ScoreSlots[S].CandId[N]   := Id;
  ScoreSlots[S].CandBase[N] := Base;
  ScoreSlots[S].NCand := N + 1;
end;

var TableBuilt: Boolean;

procedure ScoreInit;
begin
  if TableBuilt then Exit;
  ScoreSlotN := 0;

  { --- CPU ------------------------------------------------------------- }
  AddSlot(scCpu, 'integer ALU',    2); AddCand('alu16',   50000000);
  AddSlot(scCpu, 'integer multiply',1); AddCand('mul16',   4000000);
  AddSlot(scCpu, 'integer divide', 1); AddCand('div16',    2600000);
  AddSlot(scCpu, 'load and store', 2); AddCand('ldst16',  38000000);
  AddSlot(scCpu, 'branch, random', 1); AddCand('brrand',  12000000);

  { One task - move a block - and three instructions that do it. All three
    are measured in bytes per second, so they share the baseline. }
  AddSlot(scCpu, 'block copy',     2);
  AddCand('movsd', 70000000); AddCand('movsw', 70000000); AddCand('movsb', 70000000);

  { The composite: rotate a vector. Same six operations per point whether it
    is done in x87 doubles or in fixed point, which makes this the one slot
    where a machine with no FPU still has something to show. }
  AddSlot(scCpu, 'rotation',       3);
  AddCand('frot', 5000000); AddCand('fix16', 5000000); AddCand('fix8', 5000000);

  AddSlot(scCpu, 'x87 add',        1); AddCand('fadd',    6000000);
  AddSlot(scCpu, 'x87 divide',     1); AddCand('fdiv',     900000);

  { --- RAM ------------------------------------------------------------- }
  AddSlot(scMem, 'L1 read',        2);
  AddCand('rdqS', 90000000); AddCand('rddS', 90000000); AddCand('rdwS', 90000000);
  AddCand('ldsS', 90000000);

  { Write-through L1 on the reference machine, so this is really an L2 figure
    there. That is the point: a write-back Cyrix should score above 100 here
    and the report should show why. }
  AddSlot(scMem, 'L1 write',       2);
  AddCand('wrqS', 40000000); AddCand('wrdS', 40000000); AddCand('wrwS', 40000000);
  AddCand('stdS', 40000000); AddCand('stoS', 40000000); AddCand('wrfS', 40000000);

  AddSlot(scMem, 'L1 copy',        2);
  AddCand('mvdS', 35000000); AddCand('mvwS', 35000000);
  AddCand('cpdS', 35000000); AddCand('cpwS', 35000000); AddCand('cpfS', 35000000);

  { Different working sets, so different baselines - 128 KB is inside the
    reference machine's L2 and 512 KB is not. A machine too short of memory
    for the 512 KB sweep is still compared against the same machine doing the
    same size rather than being dropped. }
  AddSlot(scMem, 'main memory read', 3);
  AddCand('rd512K', 22000000); AddCand('rd256K', 30000000); AddCand('rd128K', 45000000);

  AddSlot(scMem, 'latency',        3);
  AddCand('lat64K', 5000000); AddCand('lat32K', 5500000);

  { --- Video ----------------------------------------------------------- }
  { Every candidate here moves the same 64000-byte frame, so the baseline is
    shared and the fastest instruction set simply wins. }
  AddSlot(scVid, 'frame fill',     2);
  AddCand('fillq', 28000000);  AddCand('fill32', 28000000);
  AddCand('fill16', 28000000); AddCand('fill8', 28000000);
  AddCand('fillL32', 28000000); AddCand('fillL16', 28000000);
  AddCand('fillF', 28000000);

  { Weighted highest of the video slots: copying a prepared frame out of RAM
    is what a game of this era spends its video time doing. }
  AddSlot(scVid, 'blit from RAM',  3);
  AddCand('blitq', 20000000); AddCand('blit32', 20000000); AddCand('blit16', 20000000);
  AddCand('blitL32', 20000000); AddCand('blitL16', 20000000); AddCand('blitF', 20000000);

  AddSlot(scVid, 'VRAM read',      1);
  AddCand('readq', 8000000); AddCand('read32', 8000000); AddCand('read16', 8000000);
  AddCand('readR', 8000000);

  AddSlot(scVid, 'read-modify-write', 1); AddCand('rmw',   9000000);
  AddSlot(scVid, 'scattered plot', 2); AddCand('scatw',    3500000);

  { --- Frame ----------------------------------------------------------- }
  { One slot, and every tier and both paths are candidates in it, because they
    are all the same task: draw a game frame. They do different amounts of
    work, so each carries its own baseline - the mechanism the RAM sweep
    already uses when a 512 KB read stands in for a 128 KB one. That is what
    lets a 286 that only managed the low tier be compared with a Pentium that
    ran the high one, instead of the two of them being scored on different
    lists and quietly averaged.

    With one slot the category index is the frame ratio itself, and there is
    no weighting to argue about. That is the point of measuring a workload
    rather than instructions: the balance between CPU, memory and video card
    is the one the frame actually has, not one chosen here.

    Values are frames per second in the millionths convention, so 70000000 is
    70.0 FPS on the reference machine. }
  AddSlot(scFrm, 'game frame',     1);
  AddCand('frm.low',  85000000); AddCand('frm.std',  70000000);
  AddCand('frm.high', 17000000);
  AddCand('dir.low',  90000000); AddCand('dir.std',  71000000);

  { --- Disk ------------------------------------------------------------ }
  { The cached re-read is deliberately absent: it measures whatever cache is
    loaded, not the drive, and it would reward a machine for having SMARTDRV
    in CONFIG.SYS. Access time is absent too - lower is better there, and
    every slot in this table assumes higher is better. }
  AddSlot(scDsk, 'sequential read', 3); AddCand('seqr',    2500000);
  AddSlot(scDsk, 'sequential write',2); AddCand('seqw',    2000000);
  AddSlot(scDsk, 'random 4K read',  3); AddCand('rnd4k',  55000000);
  AddSlot(scDsk, 'small blocks',    1); AddCand('rd2k',    1200000);

  TableBuilt := True;
end;

{ --------------------------------------------------------------------------
  Reading the suites.
  -------------------------------------------------------------------------- }

function LookCpu(const Id: String; var V: LongWord): Boolean;
var I: Integer;
begin
  LookCpu := False;
  for I := 0 to CpuTestN - 1 do
    if CpuTests[I].Id = Id then
    begin
      if CpuTestRes[I].Ran and (CpuTestRes[I].Value > 0) then
      begin
        V := CpuTestRes[I].Value;
        LookCpu := True;
      end;
      Exit;
    end;
end;

function LookMem(const Id: String; var V: LongWord): Boolean;
var I: Integer;
begin
  LookMem := False;
  for I := 0 to MemTestN - 1 do
    if MemTests[I].Id = Id then
    begin
      if MemTestRes[I].Ran and (MemTestRes[I].Value > 0) then
      begin
        V := MemTestRes[I].Value;
        LookMem := True;
      end;
      Exit;
    end;
end;

function LookVid(const Id: String; var V: LongWord): Boolean;
var I: Integer;
begin
  LookVid := False;
  for I := 0 to VidTestN - 1 do
    if VidTests[I].Id = Id then
    begin
      if VidTestRes[I].Ran and (VidTestRes[I].Value > 0) then
      begin
        V := VidTestRes[I].Value;
        LookVid := True;
      end;
      Exit;
    end;
end;

function LookDsk(const Id: String; var V: LongWord): Boolean;
var I: Integer;
begin
  LookDsk := False;
  if not DskRun then Exit;
  for I := 0 to DskTestN - 1 do
    if DskTests[I].Id = Id then
    begin
      if DskTestRes[I].Ran and (DskTestRes[I].Value > 0) then
      begin
        V := DskTestRes[I].Value;
        LookDsk := True;
      end;
      Exit;
    end;
end;

function LookCmp(const Id: String; var V: LongWord): Boolean;
var I: Integer;
begin
  LookCmp := False;
  for I := 0 to CmpTestN - 1 do
    if CmpTests[I].Id = Id then
    begin
      if CmpTestRes[I].Ran and (CmpTestRes[I].Value > 0) then
      begin
        V := CmpTestRes[I].Value;
        LookCmp := True;
      end;
      Exit;
    end;
end;

function Look(C: TScoreCat; const Id: String; var V: LongWord): Boolean;
begin
  case C of
    scCpu: Look := LookCpu(Id, V);
    scMem: Look := LookMem(Id, V);
    scVid: Look := LookVid(Id, V);
    scDsk: Look := LookDsk(Id, V);
  else
    Look := LookCmp(Id, V);
  end;
end;

{ --------------------------------------------------------------------------
  The computation.
  -------------------------------------------------------------------------- }

const
  MaxPoints = 9999999;   { 99999.9 - a ceiling, not an expectation }

function PointsOf(L: LongInt): LongWord;
var P: LongWord;
begin
  P := Pow2Fix(L + ToPoints);
  if P > MaxPoints then P := MaxPoints;
  PointsOf := P;
end;

procedure ScoreOneSlot(I: Integer);
var
  J        : Integer;
  V        : LongWord;
  L, Best  : LongInt;
  Found    : Boolean;
begin
  ScoreSlotRes[I].Ran    := False;
  ScoreSlotRes[I].Won    := '';
  ScoreSlotRes[I].Value  := 0;
  ScoreSlotRes[I].Base   := 0;
  ScoreSlotRes[I].Points := 0;

  Found := False;
  Best  := 0;
  for J := 0 to ScoreSlots[I].NCand - 1 do
    if Look(ScoreSlots[I].Cat, ScoreSlots[I].CandId[J], V) then
    begin
      L := Log2Fix(V) - Log2Fix(ScoreSlots[I].CandBase[J]);
      if (not Found) or (L > Best) then
      begin
        Best  := L;
        Found := True;
        ScoreSlotRes[I].Won   := ScoreSlots[I].CandId[J];
        ScoreSlotRes[I].Value := V;
        ScoreSlotRes[I].Base  := ScoreSlots[I].CandBase[J];
      end;
    end;

  if Found then
  begin
    ScoreSlotRes[I].Ran    := True;
    ScoreSlotRes[I].Points := PointsOf(Best);
  end;
end;

procedure ScoreCompute;
var
  I    : Integer;
  C    : TScoreCat;
  Sum  : LongInt;
  W    : Word;
  L    : LongInt;
begin
  ScoreInit;

  for I := 0 to ScoreSlotN - 1 do ScoreOneSlot(I);

  for C := scCpu to scFrm do
  begin
    ScoreCat[C].Have    := False;
    ScoreCat[C].Partial := False;
    ScoreCat[C].Slots   := 0;
    ScoreCat[C].Missing := 0;
    ScoreCat[C].MeanLog := 0;
    ScoreCat[C].Index   := 0;

    Sum := 0; W := 0;
    for I := 0 to ScoreSlotN - 1 do
      if ScoreSlots[I].Cat = C then
      begin
        Inc(ScoreCat[C].Slots);
        if ScoreSlotRes[I].Ran then
        begin
          { Log space throughout: the weighted product becomes a weighted sum
            and nothing can overflow on the way. }
          L := Log2Fix(ScoreSlotRes[I].Value) - Log2Fix(ScoreSlotRes[I].Base);
          Sum := Sum + LongInt(ScoreSlots[I].Weight) * L;
          W   := W + ScoreSlots[I].Weight;
        end
        else
          Inc(ScoreCat[C].Missing);
      end;

    if W > 0 then
    begin
      ScoreCat[C].Have    := True;
      ScoreCat[C].MeanLog := Sum div LongInt(W);
      ScoreCat[C].Index   := PointsOf(ScoreCat[C].MeanLog);
    end;
    ScoreCat[C].Partial := ScoreCat[C].Missing > 0;
  end;
end;

{ --------------------------------------------------------------------------
  Names, weights, formatting.
  -------------------------------------------------------------------------- }

function ScoreCatName(C: TScoreCat): String;
begin
  case C of
    scCpu: ScoreCatName := 'CPU';
    scMem: ScoreCatName := 'RAM';
    scVid: ScoreCatName := 'Video';
    scDsk: ScoreCatName := 'Disk';
  else
    ScoreCatName := 'Frame';
  end;
end;

function ScoreText(Hundredths: LongWord): String;
var A, B: LongWord; S, T: String;
begin
  A := Hundredths div 100;
  B := (Hundredths mod 100) div 10;
  Str(A, S); Str(B, T);
  ScoreText := S + '.' + T;
end;

{ --------------------------------------------------------------------------
  Self-check.

  The fixed-point logarithms are the one part of this unit that can be wrong
  in a way nobody would notice - a score is plausible whatever it says. So
  they are checked against values known in advance, including the round trip
  a real slot takes: a machine three times the reference should read 300.
  -------------------------------------------------------------------------- }

function Near(Got, Want, Tol: LongInt): Boolean;
begin
  Near := (Got - Want <= Tol) and (Want - Got <= Tol);
end;

function ScoreSelfCheck: String;
var L: LongInt;
begin
  ScoreSelfCheck := '';

  if Log2Fix(1) <> 0 then
  begin ScoreSelfCheck := 'log2(1) is not zero'; Exit end;

  if Log2Fix(65536) <> (LongInt(16) shl 16) then
  begin ScoreSelfCheck := 'log2 of a power of two is off'; Exit end;

  { log2(3) = 1.5849625, which is 103872 in Q16.16 }
  if not Near(Log2Fix(3), 103872, 4) then
  begin ScoreSelfCheck := 'log2(3) is off'; Exit end;

  { Ratio of one: the reference machine scores exactly 100. }
  if not Near(LongInt(PointsOf(0)), 10000, 6) then
  begin ScoreSelfCheck := 'unit ratio does not score 100'; Exit end;

  { Twice and half the reference. }
  if not Near(LongInt(PointsOf(LongInt(1) shl 16)), 20000, 12) then
  begin ScoreSelfCheck := 'double does not score 200'; Exit end;
  if not Near(LongInt(PointsOf(-(LongInt(1) shl 16))), 5000, 4) then
  begin ScoreSelfCheck := 'half does not score 50'; Exit end;

  { The whole path a slot takes, with values in the units the suites use. }
  L := Log2Fix(7500000) - Log2Fix(2500000);
  if not Near(LongInt(PointsOf(L)), 30000, 30) then
  begin ScoreSelfCheck := 'ratio round trip is off'; Exit end;

  { And far off the reference in both directions, where the exponent handling
    rather than the mantissa is what is being exercised. }
  L := Log2Fix(50000) - Log2Fix(2500000);        { one fiftieth }
  if not Near(LongInt(PointsOf(L)), 200, 3) then
  begin ScoreSelfCheck := 'low ratio round trip is off'; Exit end;
  L := Log2Fix(2000000000) - Log2Fix(2500000);   { eight hundred times }
  if not Near(LongInt(PointsOf(L)), 8000000, 8000) then
    ScoreSelfCheck := 'high ratio round trip is off';
end;

begin
  ScoreSlotN := 0;
  TableBuilt := False;
end.
