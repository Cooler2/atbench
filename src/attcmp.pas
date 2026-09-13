unit attcmp;
{ ----------------------------------------------------------------------------
  ATBench - the composite suite: one game frame, and how many of them a
  second (DESIGN 5.5).

  Every other suite here measures one thing at a time, which is what makes the
  numbers diagnosable and what makes them impossible to add up: a machine fast
  at RAM and slow at VRAM has two figures and no answer to "how fast is it".
  This suite answers that by measuring a workload instead of an instruction -
  the frame a game of 1994 drew, in the proportions it drew it:

    background   a rotozoomed texture over the whole viewport. Fixed-point
                 16-bit walk with a per-pixel texture fetch, so the read
                 stream is almost random and the texture is exactly as big as
                 the tier says - which is what puts the working set on one
                 side or the other of the machine's cache.
    sprites      masked, transparent, scattered. A byte-at-a-time loop with a
                 branch per pixel that the machine cannot predict, which is
                 where a Pentium and a 486 separate by more than clock speed.
    text         an 8x8 font expanded bit by bit, the way a score line was
                 drawn over graphics. More unpredictable branches, and small
                 blits rather than long ones.
    present      the finished frame out to the card, in the widest form the
                 machine has. On ISA this is most of the frame time; on VLB it
                 nearly disappears.

  One number falls out - frames per second - and unlike an average of four
  category indices it means something, because it is a measurement rather than
  an opinion about weights. It is the closest thing this program has to a
  headline figure, and it is deliberately the only place where the four parts
  of the machine are allowed to be added together.

  Three tiers, because a 286 and a Pentium MMX are two orders of magnitude
  apart and one frame size cannot flatter both:

    low   256x200 in mode 13h, a 128x128 texture, 24 sprites of 16x16
    std   320x200 in mode 13h, a 256x256 texture, 50 sprites of 16x16
    high  512x480 in VBE 101h, a 256x256 texture, 100 sprites of 32x32

  The tier is chosen by hand, never guessed at: a machine that cannot finish
  the high tier in a sensible time should not spend five minutes discovering
  that, and a machine that can should not be talked out of it by a heuristic.
  Every tier scores into the same slot with its own baseline, so a run of the
  low tier is still comparable with a run of the high one (atscore).

  The texture never exceeds one 64K segment, and that is a hard rule rather
  than a size that happened to fit. The whole point of the background kernel
  is the fetch - `mov bx,dx / mov bl,ah / mov cl,[bx]`, three instructions and
  no segment arithmetic at all - and a texture of 512x512 would put a quadrant
  select and a segment load on every pixel. The loop would then be measuring
  its own addressing rather than the machine's memory, which is the one thing
  this kernel exists not to do.

  Two paths through the same frame, on the two mode 13h tiers:

    buffered   drawn into a back buffer in RAM, then presented in one block.
    direct     drawn straight into video memory, no buffer and no present.

  Which one wins is a property of the machine and not something to decide in
  advance (DESIGN 5.5): on a VLB 486 the second path saves a whole pass over
  the frame, and on an ISA 286 it spends the frame writing single bytes across
  the slowest bus in the machine. Both are scored, and the machine is credited
  with whichever it ran faster - so the report answers "how should a game be
  written on this machine" rather than assuming it.

  The back buffer is always the whole viewport, including at the high tier
  where it is 240K. A buffer smaller than the frame would mean presenting in
  pieces, and "render the frame, then show the frame" is the scheme being
  measured. What 240K does need is segment-safe addressing: it is allocated as
  four bands of 120 rows - 61440 bytes, 3840 paragraphs, so each band starts
  on a paragraph boundary and no row inside one ever crosses a segment. The
  kernels therefore address a band with a plain Word offset, exactly as they
  do in mode 13h, where there is one band and it is the whole frame.

  All three viewports are smaller than the mode they are drawn in, and the
  high tier is 512 of the 640 columns of 101h - the whole height of it,
  centred, with a margin of 64 columns down each side and none at all above
  or below. That was once 640x400 for the sake of the present: rows the full
  width of the mode make the frame one contiguous run of bytes in video
  memory, and a viewport narrower than the mode puts every row at its own
  offset, where 65536 is not a multiple of the row pitch and rows begin to
  straddle the card's window.

  What settles the shape is that a straddling row is rare rather than usual.
  At 640 bytes to the row a 64K window holds a hundred whole rows and clips
  one, so the present is a rectangle per window - one call of the copy kernel,
  however many rows are in it - plus one row cut in half. That is about
  fifteen calls for the frame, against the ten the contiguous form took, and
  it is nowhere near the four hundred and eighty a row-at-a-time present would
  have cost.

  The height is the whole mode and not four fifths of it because the eighty
  rows below a 640x400 frame are the card's own picture showing under the
  benchmark's, which reads as a fault in the frame rather than as a margin.
  240K rather than the 300K a full-width frame would take is what the width
  buys, and the tier says what it needs before it is chosen.

  Determinism is a first-class requirement, not a nicety. Frame content
  depends only on the slot number, slots cycle every eight frames, and every
  kernel is integer - so the CRC32 of a rendered frame is a property of the
  program and not of the machine. A 286 and a Pentium MMX must produce the
  same value, and the report prints it so that two runs can be compared by
  eye. What that catches is the failure mode that scores well: a kernel that
  is fast because it computed the wrong thing.

  The self-check goes further and does not trust the CRC to be its own
  witness. Each of the three drawing kernels is run over a small region and
  compared, byte for byte, against a reference written in plain Pascal in this
  file. That is the check that has an opinion about what the right answer is;
  the CRC only says that two machines agree.
  ---------------------------------------------------------------------------- }

interface

uses atharn, atmemx;

{$I at.inc}
{$asmcpu PENTIUM}

type
  TCmpTier = (ctLow, ctStd, ctHigh);

  { What a tier is. Everything a kernel needs to know about the frame it is
    drawing comes from here, so a tier is a row of this table and not a branch
    anywhere in the code below. }
  TCmpTierCfg = record
    Id       : String[4];
    { Short enough that the headline row - tier, FPS, milliseconds, path and
      this - still fits the 78 columns the report is written for. }
    Title    : String[30];
    Vga      : Boolean;      { True: mode 13h.  False: VBE 101h }
    ModeW    : Word;         { what the card is showing }
    ModeH    : Word;
    W, H     : Word;         { the viewport drawn inside it, centred }
    BandRows : Word;         { rows per segment-safe band }
    Bands    : Word;
    TexPix   : Word;         { texture side: 128 or 256 }
    Sprites  : Word;
    SprW     : Word;         { sprite side: 16 or 32 }
    Lenses   : Word;
    LensW    : Word;         { lens side: a multiple of four, and even }
  end;

  TCmpTest = record
    Id     : String[10];
    { Both of these are cut to what the suite puts in them, and the reason is
      arithmetic rather than tidiness: the table is twenty-six of these, every
      byte of it is DGROUP, and what is left of DGROUP after the statics is
      the near heap. Two spare characters a field is two hundred bytes the
      heap does not get, and this program has run out of near heap before.

      Twenty-four holds 'Game frame, into VRAM' with room to spare; seven is
      the width of the unit column the metric is printed in, so a longer one
      would be a wrong column rather than a long one. }
    Title  : String[24];
    Metric : String[7];
    Tier   : TCmpTier;
    Frame  : Boolean;        { the result is FPS, not a rate of ops }
    OpsPer : LongWord;       { pixels or bytes in one unit of this test }
    Kern   : TKernel;
  end;

  TCmpTestRes = record
    Ran      : Boolean;
    Skipped  : Boolean;
    Why      : String[28];
    Value    : LongWord;     { the metric, in millionths }
    UsPer    : LongWord;     { microseconds for one unit - one frame's worth }
    SpreadPc : Word;
  end;

const
  { Eight distinct frames, cycled. Enough that the sprite positions and the
    rotation keep moving - a benchmark drawing the same frame twice would let
    a machine with a write-back cache look better than it is - and few enough
    that the placement tables for all of them fit in one segment. }
  CmpSlots = 8;

  { What the three tiers actually add up to. The middle tier has all nine -
    four stages, three present forms, the buffered frame and the direct one.
    The low tier has eight of them, having no lens stage, and the high tier
    has eight as well, having no direct path.

    It used to be twenty-four, which was two short of the suite as it then
    was, and two short meant the high tier's own frame test was never added
    to the table at all. Nothing said so: the tier ran its stages, produced
    no frame rate, and reported 'no result' with nothing to say about why.
    See CmpSelfCheck, which now refuses to let that happen quietly again.

    Sized to the suite and not rounded up, because every entry is DGROUP -
    the segment this program is genuinely short of - and three spare ones are
    three hundred bytes the near heap does not get. }
  MaxCmpTests = 25;

  CmpTierCfg : array[TCmpTier] of TCmpTierCfg = (
    { No lenses at the low tier, and that is the tier saying what it is for.
      A machine that needs a 256x200 frame is a machine on which the gather -
      four samples and three blends a pixel, none of them predictable - would
      be a good part of the frame time, and it would be that share of a frame
      drawn for exactly the machines that cannot afford it. The stages a slow
      machine is being asked about are the background, the sprites and the
      present; the glass is what the tiers above it add. }
    (Id: 'low';  Title: '256x200 13h, tex 128, 24 spr';
     Vga: True;  ModeW: 320; ModeH: 200;
     W: 256; H: 200; BandRows: 200; Bands: 1;
     TexPix: 128; Sprites: 24;  SprW: 16; Lenses: 0; LensW: 0),
    (Id: 'std';  Title: '320x200 13h, tex 256, 50 spr';
     Vga: True;  ModeW: 320; ModeH: 200;
     W: 320; H: 200; BandRows: 200; Bands: 1;
     TexPix: 256; Sprites: 50;  SprW: 16; Lenses: 3; LensW: 40),
    (Id: 'high'; Title: '512x480 101h, tex 256, 100 spr';
     Vga: False; ModeW: 640; ModeH: 480;
     W: 512; H: 480; BandRows: 120; Bands: 4;
     TexPix: 256; Sprites: 100; SprW: 32; Lenses: 4; LensW: 48));

var
  CmpTests   : array[0..MaxCmpTests - 1] of TCmpTest;
  CmpTestRes : array[0..MaxCmpTests - 1] of TCmpTestRes;
  CmpTestN   : Integer;

  { Which tiers have results, and the frame CRC each of them produced. }
  CmpTierRan : array[TCmpTier] of Boolean;
  CmpCrc     : array[TCmpTier] of LongInt;
  CmpCrcOk   : array[TCmpTier] of Boolean;
  CmpAnyRan  : Boolean;

  { The tier whose buffers are currently allocated, and whether they are. }
  CmpTier    : TCmpTier;
  CmpReady   : Boolean;

{ Empty when the tier can be run on this machine, otherwise the reason - in
  the words the menu shows beside the item it has greyed out. }
function  CmpTierWhy(T: TCmpTier): String;

{ Allocates the buffers for one tier and builds its content. Nothing else in
  the unit may be called until this has returned True. }
function  CmpInit(T: TCmpTier): Boolean;
procedure CmpDone;
function  CmpWhy: String;

{ The video mode the tier draws in, entered once around the whole tier rather
  than around each test: setting a mode is not free, and 101h in particular
  goes through the card's BIOS. }
function  CmpEnterMode: Boolean;
procedure CmpLeaveMode;

{ Byte-for-byte against a reference in Pascal. Empty when the kernels agree
  with it. Needs no video mode, so it runs before the screen is touched. }
function  CmpSelfCheck: String;

{ Presents one frame and reads it back off the card, comparing what arrived
  with what was sent. Empty when they agree, and empty as well when the card
  offers no window it can be read through - which is a limit of the check and
  not a fault in the frame, so it says so through CmpPresentWhy instead.

  Worth its own check rather than being folded into the self-check above: the
  window arithmetic is the only part of this unit that depends on the card,
  and getting it wrong shows up as a frame in the wrong place rather than as
  a wrong frame. It walks the picture by rows where the present walks it by
  bands, so a mistake would have to be made twice, in two shapes, to pass. }
function  CmpPresentCheck: String;

var
  CmpPresentWhy : String[38];   { why the readback could not be made }
  CmpTimerWhy   : String[38];   { why present and frame cannot be timed }

{ What the two lines of text over the frame say. Set before a test runs and
  never during one - it rebuilds a list, and a list is not something to build
  inside a measurement. Lower case is folded up and anything the font does not
  hold becomes a space, so a caller can pass whatever reads best.

  The frame used to carry two rows of glyphs chosen by arithmetic, which is a
  fair imitation of a score line as far as the machine is concerned and, to
  the person watching it, gibberish that changes eight times a second. It says
  which tier and which test now. }
procedure CmpStatus(const Top, Bot: String);

{ Renders two frames into the back buffer and returns the CRC32 of the whole
  of it. Machine-independent by construction; see the header. }
function  CmpFrameCrc: LongInt;

{ True when this tier produced at least one number. A tier that was attempted
  and produced none is still reported - with the reason on every row - which
  is why CmpTierRan means "attempted" and this means "worth scoring". }
function  CmpTierHasResults(T: TCmpTier): Boolean;

{ Index range of one tier's tests inside the table. }
function  CmpFirst(T: TCmpTier): Integer;
function  CmpLast(T: TCmpTier): Integer;

{ Every row of a tier skipped for one reason. What a failure before the first
  measurement leaves behind, so that the report says why the rows are empty
  rather than leaving the reader to work it out from a message that has long
  since scrolled away. }
procedure CmpMarkTier(T: TCmpTier; const Why: String);

procedure CmpRunTest(I: Integer);

{ The headline: microseconds and frames per second for the fastest path the
  tier managed. Ran is False when neither path produced a number. }
procedure CmpBestFrame(T: TCmpTier; var Ran: Boolean; var Fps: LongWord;
                       var UsFrame: LongWord; var Path: String);

implementation

uses attime, atcpuid, atsys, attvbe, atdbg;

const
  VgaSeg     = $A000;
  TexStride  = 256;        { rows of the texture are always 256 bytes apart,
                             so the fetch is one AND away whatever the size }
  FontFirst  = 32;         { the first glyph the font holds: space }
  FontChars  = 64;         { through to '_', which is all a status line needs }
  FontBytes  = FontChars * 8;
  SprPats    = 8;          { distinct sprite patterns }
  ScratchLen = 64;         { room for the self-check's hand-built list entries }
  TextRows   = 2;

  { The rotation cycle, in frames. Everything about the background - angle,
    zoom and drift - is a function of the frame number modulo this, and every
    one of the three closes exactly on it, so the animation is a loop with no
    seam rather than a sequence that jumps back to the start.

    Five hundred and twelve of them, which is half a step of the sine table a
    frame. It was two hundred and fifty-six - a whole step, a bit over a
    degree - and that is about right at twenty or thirty frames a second and
    much too fast above it: a machine drawing two hundred a second took the
    picture round almost twice a second, which reads as a spin and not as a
    drift. Before either it was eight slots, forty-five degrees a frame, and
    that read as eight unrelated pictures shown in a row.

    Halving the step rather than the table is what keeps it smooth. The odd
    frames are interpolated between two entries of the sine (SinH) instead of
    being the even frame shown a second time, so a fast machine gets twice as
    many different frames and not each frame twice - which is the difference
    between slower motion and a lower frame rate pretending to be one.

    The step is per frame and never per millisecond: the animation runs at
    the speed the machine draws it, which is the honest thing for a frame
    counter to show and the only thing a benchmark may do without measuring
    its own idle loop. The frame rate is the number this suite exists to
    produce, so the motion per frame is the only part of it that may be
    tuned. }
  Turns      = 512;
  RotBytes   = 12;         { one frame of it: start, pixel step, row step }
  SprStBytes = 10;         { one sprite's state: position, speed, pattern }
  LnsStBytes = 12;         { one lens's: position, speed, band segment, base }
  BandTBytes = 32;         { the band table: eight bands of segment and base }

  { The lens blend, and the two numbers that shape it.

    LnsMulW weights, and a page of 512 signed bytes for each: page w holds the
    difference d scaled by w sixteenths, for every d from -256 to 255, at index
    d + 256. That is the whole of a bilinear blend once the difference between
    two samples is in hand. A table and not a multiply because this runs four
    thousand times a frame on machines whose IMUL is twenty-one cycles, and
    because the same table is what makes the kernel branchless - a pixel with
    no fraction to interpolate reads weight zero and gets its own sample back
    exactly, with no test for the case anywhere.

    Five hundred and twelve entries and not two hundred and fifty-six, which
    is the difference between a filter and a filter with a fault in it. A byte
    difference is ambiguous - 219 and -37 are the same byte - and reading the
    wrong one of the two puts a dark rim on everything bright the glass passes
    over, since the strong differences in this palette are exactly the ones
    that overflow a byte: an orange sprite on a dark background. The sign is
    not lost, though, only unwritten: the SUB that took the difference set the
    borrow flag, and SBB of a register with itself turns that flag into the
    high byte the difference needed. One instruction a blend, and the filter
    is exact over the whole palette.

    The page is 512-byte aligned so that the entry in the LUT can hold the
    whole address of index zero and the kernel can simply add the signed
    difference to it.

    LnsDepth and LnsRim are the two numbers of the pull. The sample for the
    pixel at radius r is taken from (256 - LnsDepth - LnsRim*r2/R2)/256 of
    that radius: a hundred and six 256ths of it at the centre and ninety-five
    at the rim, so the whole disc shows what lies in the middle third of it
    and nothing the glass covers is left at its own size.

    The magnification that produces is not that ratio but its derivative,
    256/(256 - LnsDepth - 3*LnsRim*r2/R2) - about two and a third times in the
    middle and three and a fifth at the rim. It grows outwards, which is the
    way round a magnifier really is: the eye is the stop and it sits behind
    the glass, so the field is stretched more the further from the axis it is
    read, and a page under a lens bulges towards the rim rather than fading
    into the desk. Two earlier profiles had it the other way about and both
    looked wrong for the same reason - a map told to land back on the rim
    where it started has to compress the outside to make room for what the
    middle took, and the compression is not gentle: the dome, sqrt(1 - r2/R2),
    squeezed the outer third of the radius by five to one, which the eye reads
    as a hard ring halfway out rather than as glass.

    Three times LnsRim and not once because the derivative of r*(a - b*r2) is
    a - 3*b*r2, and that is also the whole of why LnsRim is small: a third of
    the way from LnsDepth to 256 the derivative reaches zero and the picture
    folds back on itself at the rim. Eleven leaves it at 73/256.

    What the pull costs is that it ends short - the rim shows what lies about
    a third of the way out, not what lies at the rim - so there is a step in
    the picture where the glass ends. That step is covered by the ring, and it
    is where a magnifier held over a page has its step too. }
  LnsMulW    = 16;
  LnsMulSize = LnsMulW * 512;
  LnsDepth   = 150;
  LnsRim     = 11;

  { The palette, in three ranges, and the reason the picture is worth looking
    at at all. Mode 13h comes up with the default DAC - sixteen EGA colours,
    sixteen greys and then blocks of HSV - and a texture indexed into that is
    not a texture, it is noise with a colour for every step. So the suite
    programmes the DAC itself, and once it does, the ranges have to be shared
    out between the things drawing into the frame:

      0..191    the background gradient. The texture is scaled into this and
                nothing else writes here.
      192..238  the body of a sprite, ember at its rim and white-gold at its
                centre. Warm against a cool background, which is what makes
                them visible over a texture rather than lost in it.
      239       the contour drawn round that body. One colour and one pixel
                wide, and deliberately not the end of the body's ramp: a
                shape whose edge fades out has no edge at 320x200, and the
                background it has to be told apart from runs from near black
                to white, so the contour is chosen for hue rather than for
                brightness. Saturated orange reads against both ends of it.
      240       the shadow under the text.
      254       the rim of a lens: the one neutral grey in the picture, so a
                ring drawn in it belongs to the glass rather than to the
                sprites it is the same size as.
      255       text.

    Index 0 stays the sprite kernel's transparent colour - it is the darkest
    background shade, which the sprites never write, so nothing is lost by
    the background using it. }
  BgLo       = 0;
  BgHi       = 191;
  SprLo      = 192;
  SprHi      = 238;
  SprEdge    = 239;
  ShaCol     = 240;
  LnsCol     = 254;
  TxtCol     = 255;

  { What the caption says while the checksum frame is drawn. The CRC is a
    property of the program and not of the machine, and it would stop being
    one the moment the picture it covers depended on which test had run last -
    so the frame that is checksummed always carries this, before the run and
    again after it. }
  CanonTop   = 'ATBENCH';
  CanonBot   = 'GAME FRAME';

  { A pass of the frame tests, against the 250 ms every other test uses. Three
    passes of this is about ten seconds of animation on the screen, which is
    the point: the frame is the one test with something to show, and it used
    to be over before the eye had found it. The abort budget is untouched, so
    a machine slow enough to spend eight seconds on a single frame is stopped
    exactly where it was stopped before. }
  FrameMs    = 3300;

  { Quarter of a sine wave in Q12, 65 entries so that both ends are exact.
    Written out rather than computed because the frame content has to be the
    same on every machine, and a table generated by a recurrence is a table
    that can drift. }
  SinQ : array[0..64] of Integer = (
        0,   101,   201,   301,   401,   501,   601,   700,
      799,   897,   995,  1092,  1189,  1285,  1380,  1474,
     1567,  1660,  1751,  1842,  1931,  2019,  2106,  2191,
     2276,  2359,  2440,  2520,  2598,  2675,  2751,  2824,
     2896,  2967,  3035,  3102,  3166,  3229,  3290,  3349,
     3406,  3461,  3513,  3564,  3612,  3659,  3703,  3745,
     3784,  3822,  3857,  3889,  3920,  3948,  3973,  3996,
     4017,  4036,  4052,  4065,  4076,  4085,  4091,  4095,
     4096);

type
  TCmpKind = (ckBack, ckSpr, ckTxt, ckPreW, ckPreD, ckPreQ, ckFrame, ckDirect);

var
  { --- the buffers ------------------------------------------------------- }
  Tex     : TFarBuf;       { texture, TexPix rows of TexStride }
  Back    : TFarBuf;       { the whole viewport, Bands bands }
  Aux     : TFarBuf;       { font, sprite patterns, placement lists }

  TexSeg  : Word;
  AuxSeg  : Word;
  BandBytes : LongInt;

  { --- where the current test draws -------------------------------------- }
  DstSeg     : array[0..7] of Word;
  DstBase    : array[0..7] of Word;
  DstBands   : Word;
  DstRows    : Word;       { rows in one band }
  DstStride  : Word;
  DstToVram  : Boolean;    { the direct path }

  { --- what the kernels read --------------------------------------------- }
  KTexSeg  : Word;
  KDstSeg  : Word;
  KDstOfs  : Word;
  KRows    : Word;
  KChunks  : Word;         { pixels per row, divided by eight }
  KRowAdd  : Word;
  KU, KV   : Word;         { 8.8 texture coordinates of the next pixel }
  KDu, KDv : Word;         { per pixel }
  KRdu     : Word;         { per row }
  KRdv     : Word;

  KSprSeg  : Word;         { the aux buffer: lists and pixels both live here }
  KSprPtr  : Word;
  KSprN    : Word;

  { What the placement kernel is told, and what it leaves behind. Positions
    are 12.4 fixed point: 8.8 cannot hold an X of 608, which is where a 32
    pixel sprite stops on a 640 wide viewport, and a sixteenth of a pixel a
    frame is finer than anything the eye follows. }
  KSpSt    : Word;         { the state table: one sprite every 10 bytes }
  KSpN     : Word;
  KSpList  : Word;         { where the entries it writes go }
  KSpOut   : Word;         { how many it wrote }
  KSpW     : Word;
  KSpChunks, KSpRowAdd : Word;
  KSpXMax, KSpYMax     : Word;   { 12.4, the far edge a sprite may touch }
  KSpRows, KSpStride   : Word;
  KSpBands, KSpBandT   : Word;   { the band table, in the aux segment }
  KpXi, KpBand, KpRow1 : Word;   { scratch, so the loop has registers to spare }

  { The lenses. Their state is the sprites' with the band folded in: a lens
    stays inside the band it was given, so its segment and the base of its
    band never change and no division is needed to find them. }
  KLnSt    : Word;
  KLnN     : Word;
  KLnList  : Word;
  KLnRing  : Word;
  KLnW, KLnChunks, KLnRowAdd : Word;
  KLnXMax, KLnYMax, KLnStride : Word;
  KLnSeg, KLnOfs : Word;   { the one lens being drawn }
  KLnLut, KLnScr : Word;
  KLnPix   : Word;         { pixels in a lens }
  KTxtPtr  : Word;
  KTxtN    : Word;
  KTxtCol  : Word;

  KCSrcSeg, KCSrcOfs : Word;
  KCDstSeg, KCDstOfs : Word;
  KCUnits            : Word;   { words, dwords or 32-byte groups per row }
  KCRows             : Word;
  KCSrcAdd, KCDstAdd : Word;

  { --- content ----------------------------------------------------------- }
  SinT   : array[0..255] of Integer;

  { The background is tabulated a frame at a time - see BuildTurns - and the
    table lives in the aux segment rather than here. Six words a frame is
    three kilobytes at this cycle length, and DGROUP is the one segment this
    program can run out of; the aux segment is where the per-frame tables
    already are, and the frame kernel reads it exactly as it reads them. }

  OfsFont, OfsPats, OfsScratch, OfsRot, OfsText : Word;
  OfsBands, OfsSprSt, OfsLists : Word;
  OfsLensSt, OfsLensLut, OfsLensRing, OfsLensScr, OfsLensList : Word;
  OfsLensMul : Word;       { 512-byte aligned, see LnsMulW }
  TxtN     : Word;         { glyphs in the status line, both rows together }
  StatTop  : String[40];
  StatBot  : String[40];
  PlaceFor : Integer;      { -1, or the DstToVram the lists were built for }

  Slot     : Word;         { placement list of the frame being drawn }
  Turn     : Word;         { where the background is in its rotation }
  Tex256   : Boolean;
  SprBytes : Word;         { one sprite pattern }
  GlyphsPerRow : Word;

  TableFull   : Boolean;   { the test table would not hold every test }
  PresentKind : TCmpKind;  { which of the three present forms the frame uses }
  OldMode  : Byte;
  ModeOn   : Boolean;
  InitWhy  : String;
  TimerOk  : Boolean;      { the clock can see this card's window call }

{ ------------------------------------------------------------------ pixels }

{ The background, and the reason the whole tier table exists.

  One row is a walk across the texture in 8.8 fixed point: u and v advance by
  du and dv per pixel, and the texel is read at (v_int * 256 + u_int) - which
  is exactly BX with v's high byte in BH and u's high byte in BL, so the
  address arithmetic is two register moves and nothing else. The texture is
  256 bytes to a row for that reason alone.

  DS points at the texture and is pushed and restored around each row, so the
  row bookkeeping - the coordinates, the counters - can still be read out of
  DGROUP. That costs two instructions a row against a segment override on
  every pixel, and it keeps the unit free of any assumption about SS.

  Eight pixels are unrolled per iteration so that the stores can carry their
  displacement and DI is advanced once instead of eight times. Every viewport
  width in the table is a multiple of eight. }

procedure BgBand256; assembler;
asm
    push si
    push di
    push bp
    push ds
    push es
    mov  cx, KRows
    or   cx, cx
    jz   @@done
    mov  es, KDstSeg
    mov  di, KDstOfs
  @@row:
    push cx
    mov  ax, KU
    mov  dx, KV
    mov  si, KDu
    mov  bp, KDv
    mov  ch, byte ptr KChunks
    push ds
    mov  ds, KTexSeg
  @@chunk:
    mov  bx, dx
    mov  bl, ah
    mov  cl, [bx]
    mov  es:[di], cl
    add  ax, si
    add  dx, bp

    mov  bx, dx
    mov  bl, ah
    mov  cl, [bx]
    mov  es:[di+1], cl
    add  ax, si
    add  dx, bp

    mov  bx, dx
    mov  bl, ah
    mov  cl, [bx]
    mov  es:[di+2], cl
    add  ax, si
    add  dx, bp

    mov  bx, dx
    mov  bl, ah
    mov  cl, [bx]
    mov  es:[di+3], cl
    add  ax, si
    add  dx, bp

    mov  bx, dx
    mov  bl, ah
    mov  cl, [bx]
    mov  es:[di+4], cl
    add  ax, si
    add  dx, bp

    mov  bx, dx
    mov  bl, ah
    mov  cl, [bx]
    mov  es:[di+5], cl
    add  ax, si
    add  dx, bp

    mov  bx, dx
    mov  bl, ah
    mov  cl, [bx]
    mov  es:[di+6], cl
    add  ax, si
    add  dx, bp

    mov  bx, dx
    mov  bl, ah
    mov  cl, [bx]
    mov  es:[di+7], cl
    add  ax, si
    add  dx, bp

    add  di, 8
    dec  ch
    jnz  @@chunk
    pop  ds

    mov  ax, KU
    add  ax, KRdu
    mov  KU, ax
    mov  ax, KV
    add  ax, KRdv
    mov  KV, ax
    add  di, KRowAdd
    pop  cx
    dec  cx
    jnz  @@row
  @@done:
    pop  es
    pop  ds
    pop  bp
    pop  di
    pop  si
end;

{ The same walk over a 128x128 texture. The rows are still 256 bytes apart, so
  the only difference is one AND per pixel that folds both halves of BX back
  into range - which is also why the low tier's background is not simply the
  standard one scaled down: it pays an extra instruction per pixel, and the
  report says so rather than pretending the two are the same kernel. }

procedure BgBand128; assembler;
asm
    push si
    push di
    push bp
    push ds
    push es
    mov  cx, KRows
    or   cx, cx
    jz   @@done
    mov  es, KDstSeg
    mov  di, KDstOfs
  @@row:
    push cx
    mov  ax, KU
    mov  dx, KV
    mov  si, KDu
    mov  bp, KDv
    mov  ch, byte ptr KChunks
    push ds
    mov  ds, KTexSeg
  @@chunk:
    mov  bx, dx
    mov  bl, ah
    and  bx, 7F7Fh
    mov  cl, [bx]
    mov  es:[di], cl
    add  ax, si
    add  dx, bp

    mov  bx, dx
    mov  bl, ah
    and  bx, 7F7Fh
    mov  cl, [bx]
    mov  es:[di+1], cl
    add  ax, si
    add  dx, bp

    mov  bx, dx
    mov  bl, ah
    and  bx, 7F7Fh
    mov  cl, [bx]
    mov  es:[di+2], cl
    add  ax, si
    add  dx, bp

    mov  bx, dx
    mov  bl, ah
    and  bx, 7F7Fh
    mov  cl, [bx]
    mov  es:[di+3], cl
    add  ax, si
    add  dx, bp

    mov  bx, dx
    mov  bl, ah
    and  bx, 7F7Fh
    mov  cl, [bx]
    mov  es:[di+4], cl
    add  ax, si
    add  dx, bp

    mov  bx, dx
    mov  bl, ah
    and  bx, 7F7Fh
    mov  cl, [bx]
    mov  es:[di+5], cl
    add  ax, si
    add  dx, bp

    mov  bx, dx
    mov  bl, ah
    and  bx, 7F7Fh
    mov  cl, [bx]
    mov  es:[di+6], cl
    add  ax, si
    add  dx, bp

    mov  bx, dx
    mov  bl, ah
    and  bx, 7F7Fh
    mov  cl, [bx]
    mov  es:[di+7], cl
    add  ax, si
    add  dx, bp

    add  di, 8
    dec  ch
    jnz  @@chunk
    pop  ds

    mov  ax, KU
    add  ax, KRdu
    mov  KU, ax
    mov  ax, KV
    add  ax, KRdv
    mov  KV, ax
    add  di, KRowAdd
    pop  cx
    dec  cx
    jnz  @@row
  @@done:
    pop  es
    pop  ds
    pop  bp
    pop  di
    pop  si
end;

{ Sprites, from a list built before the clock started.

  An entry carries everything: which segment and offset to draw at, where the
  pixels are, how many rows, how wide, and what to add to DI at the end of a
  row. It carries them because DS belongs to the sprite data for the whole
  loop, so a global in DGROUP would be unreadable - and because a sprite that
  straddles a band boundary is then simply two entries, split when the list
  was built rather than tested for on every row.

  Colour zero is transparent, and the branch that skips it is the point of the
  kernel: it is taken about a third of the time in a pattern the machine
  cannot learn, which is exactly the traffic a masked blitter of the period
  produced. }

procedure SprList; assembler;
asm
    push si
    push di
    push bp
    push ds
    push es
    cld
    mov  cx, KSprN
    or   cx, cx
    jz   @@done
    mov  bp, KSprPtr
    mov  ds, KSprSeg
  @@ent:
    push cx
    mov  ax, ds:[bp]
    mov  es, ax
    mov  di, ds:[bp+2]
    mov  si, ds:[bp+4]
    mov  cx, ds:[bp+6]
    or   cx, cx
    jz   @@next
  @@row:
    mov  dx, ds:[bp+8]
  @@px:
    lodsb
    or   al, al
    jz   @@s0
    mov  es:[di], al
  @@s0:
    lodsb
    or   al, al
    jz   @@s1
    mov  es:[di+1], al
  @@s1:
    lodsb
    or   al, al
    jz   @@s2
    mov  es:[di+2], al
  @@s2:
    lodsb
    or   al, al
    jz   @@s3
    mov  es:[di+3], al
  @@s3:
    add  di, 4
    dec  dx
    jnz  @@px
    add  di, ds:[bp+10]
    dec  cx
    jnz  @@row
  @@next:
    add  bp, 12
    pop  cx
    dec  cx
    jnz  @@ent
  @@done:
    pop  es
    pop  ds
    pop  bp
    pop  di
    pop  si
end;

{ Text: an 8x8 glyph expanded a bit at a time, which is how a score line got
  drawn over a picture when there was no such thing as a font blitter. Eight
  branches per byte, and the colour is written only where a bit is set, so the
  background shows through exactly as it did. }

{ Where every sprite is this frame.

  A game of the era moved its objects once a frame and this does the same, in
  the same place: inside the measured interval, because that is where a game
  paid for it. It is about forty instructions a sprite against two hundred and
  fifty-six masked pixels, so it is a per cent of the sprite stage and a
  fraction of a per cent of the frame - and in exchange the motion is
  continuous instead of being eight fixed arrangements shown in a row.

  What it produces is exactly what the list used to hold, so the sprite kernel
  below is untouched: a destination segment and offset, the pattern, the row
  count, and the two constants the blit walks with.

  Sprites bounce off the edges of the viewport rather than being clipped
  against them. That is one compare and a negate here, against a clipper in
  the blit or a second kind of list entry - and a sprite that never leaves the
  viewport also never asks what the blit should do about the part that has.

  A sprite may still cross a band boundary, which is a fact about the back
  buffer and not about the sprite, so it becomes two entries; the division
  that decides which band it starts in is the only expensive instruction here
  and there is one of it per sprite. }
procedure SprPlace; assembler;
asm
    push si
    push di
    push bp
    push es
    mov  es, KSprSeg
    mov  si, KSpSt
    mov  di, KSpList
    xor  bp, bp
    mov  cx, KSpN
    or   cx, cx
    jz   @@done
  @@one:
    push cx

    { X, and a bounce if the step took it past the edge. The compare is
      unsigned and that is deliberate: a step that would take X below zero
      wraps to something enormous, which fails the same test. }
    mov  ax, es:[si]
    add  ax, es:[si+4]
    cmp  ax, KSpXMax
    jbe  @@xok
    neg  word ptr es:[si+4]
    mov  ax, es:[si]
    add  ax, es:[si+4]
  @@xok:
    mov  es:[si], ax
    shr  ax, 4
    mov  KpXi, ax

    { Y, the same }
    mov  ax, es:[si+2]
    add  ax, es:[si+6]
    cmp  ax, KSpYMax
    jbe  @@yok
    neg  word ptr es:[si+6]
    mov  ax, es:[si+2]
    add  ax, es:[si+6]
  @@yok:
    mov  es:[si+2], ax
    shr  ax, 4

    { which band it starts in, and how far down that band }
    xor  dx, dx
    div  word ptr KSpRows
    mov  KpBand, ax
    mov  ax, KSpRows
    sub  ax, dx                  { rows left in this band }
    cmp  ax, KSpW
    jbe  @@rows1
    mov  ax, KSpW
  @@rows1:
    mov  KpRow1, ax              { rows the first entry covers }

    { the first entry: base + row*stride + x, inside the band it starts in }
    mov  ax, dx
    mul  word ptr KSpStride
    add  ax, KpXi
    mov  bx, KpBand
    shl  bx, 1
    shl  bx, 1
    add  bx, KSpBandT
    mov  dx, es:[bx]
    mov  es:[di], dx
    add  ax, es:[bx+2]
    mov  es:[di+2], ax
    mov  ax, es:[si+8]
    mov  es:[di+4], ax
    mov  ax, KpRow1
    mov  es:[di+6], ax
    mov  dx, KSpChunks
    mov  es:[di+8], dx
    mov  dx, KSpRowAdd
    mov  es:[di+10], dx
    add  di, 12
    inc  bp

    { and what is left of it, at the top of the next band }
    mov  dx, KSpW
    sub  dx, ax
    jz   @@next
    mov  bx, KpBand
    inc  bx
    cmp  bx, KSpBands
    jae  @@next
    shl  bx, 1
    shl  bx, 1
    add  bx, KSpBandT
    mov  cx, es:[bx]
    mov  es:[di], cx
    mov  cx, es:[bx+2]
    add  cx, KpXi
    mov  es:[di+2], cx
    { the pattern picks up where the first entry stopped. DX is the row
      count for this entry and MUL writes its high word there, so it goes on
      the stack for the two instructions that need it back. }
    push dx
    mul  word ptr KSpW
    add  ax, es:[si+8]
    mov  es:[di+4], ax
    pop  dx
    mov  es:[di+6], dx
    mov  cx, KSpChunks
    mov  es:[di+8], cx
    mov  cx, KSpRowAdd
    mov  es:[di+10], cx
    add  di, 12
    inc  bp

  @@next:
    add  si, 10
    pop  cx
    dec  cx
    jnz  @@one
  @@done:
    mov  KSpOut, bp
    pop  es
    pop  bp
    pop  di
    pop  si
end;

{ The lenses, where they are this frame. The sprites' step without the
  division: a lens is given a band when it is placed and never leaves it, so
  its segment and the base it counts from are in its state, and Y is measured
  from the top of its own band.

  That restriction is what makes a lens affordable at all. The effect reads
  the frame back, and reading across the boundary between two bands means
  reading across the boundary between two DOS allocations, which are not
  adjacent - so a lens that straddled two bands would need the gather split in
  two and a source rectangle in two segments. On the two mode 13h tiers there
  is one band and the restriction means nothing; at the high tier a lens
  drifts within its own strip. }
procedure LensStep; assembler;
asm
    push si
    push di
    push es
    mov  es, KSprSeg
    mov  si, KLnSt
    mov  di, KLnList
    mov  cx, KLnN
    or   cx, cx
    jz   @@done
  @@one:
    push cx
    mov  ax, es:[si]
    add  ax, es:[si+4]
    cmp  ax, KLnXMax
    jbe  @@xok
    neg  word ptr es:[si+4]
    mov  ax, es:[si]
    add  ax, es:[si+4]
  @@xok:
    mov  es:[si], ax
    shr  ax, 4
    mov  KpXi, ax

    mov  ax, es:[si+2]
    add  ax, es:[si+6]
    cmp  ax, KLnYMax
    jbe  @@yok
    neg  word ptr es:[si+6]
    mov  ax, es:[si+2]
    add  ax, es:[si+6]
  @@yok:
    mov  es:[si+2], ax
    shr  ax, 4
    mul  word ptr KLnStride
    add  ax, KpXi
    add  ax, es:[si+10]        { the base of its band }
    mov  dx, es:[si+8]         { and the segment }
    mov  es:[di], dx
    mov  es:[di+2], ax
    mov  ax, KLnRing
    mov  es:[di+4], ax
    mov  ax, KLnW
    mov  es:[di+6], ax
    mov  ax, KLnChunks
    mov  es:[di+8], ax
    mov  ax, KLnRowAdd
    mov  es:[di+10], ax
    add  si, 12
    add  di, 12
    pop  cx
    dec  cx
    jnz  @@one
  @@done:
    pop  es
    pop  di
    pop  si
end;

{ One lens, gathered.

  Every pixel of the lens rectangle is fetched from somewhere else in the same
  rectangle, at the place a table worked out once at startup, and put in a
  scratch buffer - which is then blitted back over the rectangle. Two passes
  and not one, because the effect reads the picture it is drawing into: doing
  it in place would feed each distorted pixel back into the pixels after it
  and smear the lens across the frame.

  Bilinear, and that is most of what is here. A lens magnifies, and magnifying
  a paletted picture by picking the nearest source pixel gives back squares
  four and five pixels across - which reads as a fault in the program rather
  than as glass. So each output pixel is four source pixels blended by the
  fraction its sample fell at: two blends across, one down.

  What a blend costs is the whole design of the table. SUB takes the byte
  difference and sets the borrow; SBB of a register with itself turns that
  borrow into the difference's high byte, so what is in hand is the true
  signed difference and not a byte that could mean two things; the entry
  carries the address the weight's table page starts at, so the fraction of
  the difference is one add and one indexed read. Five instructions, three
  times, over four samples read as two words - and no multiply, no branch and
  no clamp anywhere in the loop. The last row and column of the rectangle
  sample one pixel outside it; their weight is zero, the table returns zero
  for every difference at that weight, and the pixel comes back exactly as it
  was read.

  The entry is eight bytes: the offset of the top-left sample, the offset of
  the one below it, and the two table pages. The row below is stored rather
  than added because it buys the register that counts the loop - there are
  seven of them and this needs every one.

  This is also the reason the stage is worth measuring rather than only worth
  looking at: a dependent load per blend, over a working set the size of the
  frame, is exactly the access pattern a texture fetch is - and it is the one
  thing in the frame that a cache cannot predict. }
procedure LensGather; assembler;
asm
    push si
    push di
    push bp
    push ds
    push es
    mov  dx, KLnPix
    or   dx, dx
    jz   @@done
    mov  bp, KLnOfs
    mov  di, KLnScr
    mov  si, KLnLut
    mov  es, KLnSeg
    mov  ax, KSprSeg
    mov  ds, ax
  @@px:
    mov  bx, [si]
    add  bx, bp
    mov  ax, es:[bx]           { al = top left, ah = top right }
    mov  bx, [si+2]
    add  bx, bp
    mov  cx, es:[bx]           { cl = bottom left, ch = bottom right }
    sub  ah, al                { across the top row, and the borrow with it }
    mov  bl, ah
    sbb  bh, bh                { the borrow, made into the sign }
    add  bx, [si+4]            { the page for this pixel's x fraction }
    add  al, [bx]              { the top row, blended }
    sub  ch, cl                { and the bottom row }
    mov  bl, ch
    sbb  bh, bh
    add  bx, [si+4]
    add  cl, [bx]
    sub  cl, al                { the difference down }
    mov  bl, cl
    sbb  bh, bh
    add  bx, [si+6]            { the page for the y fraction }
    add  al, [bx]
    mov  [di], al
    inc  di
    add  si, 8
    dec  dx
    jnz  @@px
  @@done:
    pop  es
    pop  ds
    pop  bp
    pop  di
    pop  si
end;

procedure TxtList; assembler;
asm
    push si
    push di
    push bp
    push ds
    push es
    cld
    mov  bx, KTxtCol
    mov  cx, KTxtN
    or   cx, cx
    jz   @@done
    mov  bp, KTxtPtr
    mov  ds, KSprSeg
  @@ent:
    push cx
    mov  ax, ds:[bp]
    mov  es, ax
    mov  di, ds:[bp+2]
    mov  si, ds:[bp+4]
    mov  dx, 8
  @@row:
    lodsb
    mov  cl, 8
  @@bit:
    shl  al, 1
    jnc  @@skip
    mov  es:[di], bl
  @@skip:
    inc  di
    dec  cl
    jnz  @@bit
    add  di, ds:[bp+6]
    dec  dx
    jnz  @@row
    add  bp, 8
    pop  cx
    dec  cx
    jnz  @@ent
  @@done:
    pop  es
    pop  ds
    pop  bp
    pop  di
    pop  si
end;

{ Present, three ways.

  A rectangle rather than a block, because the low tier's viewport is 256 wide
  inside a 320-wide screen and the high tier's bands land wherever the window
  leaves them. Rows of one, which is what every other case is, costs one extra
  register load per frame.

  Everything the loop needs is in registers before DS moves to the source:
  BX the units in a row, DX the rows, AX and BP what to add at the end of one.
  Which of the three forms is fastest is measured, not assumed - the same
  question DESIGN 5.3 asks about fills, and the answer differs by machine. }

procedure CopyW; assembler;
asm
    push si
    push di
    push bp
    push ds
    push es
    cld
    mov  bx, KCUnits
    mov  dx, KCRows
    mov  ax, KCSrcAdd
    mov  bp, KCDstAdd
    mov  si, KCSrcOfs
    mov  di, KCDstOfs
    mov  es, KCDstSeg
    mov  ds, KCSrcSeg
    or   dx, dx
    jz   @@done
  @@row:
    mov  cx, bx
    rep  movsw
    add  si, ax
    add  di, bp
    dec  dx
    jnz  @@row
  @@done:
    pop  es
    pop  ds
    pop  bp
    pop  di
    pop  si
end;

procedure CopyD; assembler;
asm
    push si
    push di
    push bp
    push ds
    push es
    cld
    mov  bx, KCUnits
    mov  dx, KCRows
    mov  ax, KCSrcAdd
    mov  bp, KCDstAdd
    mov  si, KCSrcOfs
    mov  di, KCDstOfs
    mov  es, KCDstSeg
    mov  ds, KCSrcSeg
    or   dx, dx
    jz   @@done
  @@row:
    mov  cx, bx
    rep  movsd
    add  si, ax
    add  di, bp
    dec  dx
    jnz  @@row
  @@done:
    pop  es
    pop  ds
    pop  bp
    pop  di
    pop  si
end;

procedure CopyQ; assembler;
asm
    push si
    push di
    push bp
    push ds
    push es
    cld
    mov  bx, KCUnits
    mov  dx, KCRows
    mov  ax, KCSrcAdd
    mov  bp, KCDstAdd
    mov  si, KCSrcOfs
    mov  di, KCDstOfs
    mov  es, KCDstSeg
    mov  ds, KCSrcSeg
    or   dx, dx
    jz   @@done
  @@row:
    mov  cx, bx
  @@q:
    movq mm0, [si]
    movq mm1, [si+8]
    movq mm2, [si+16]
    movq mm3, [si+24]
    movq es:[di], mm0
    movq es:[di+8], mm1
    movq es:[di+16], mm2
    movq es:[di+24], mm3
    add  si, 32
    add  di, 32
    dec  cx
    jnz  @@q
    add  si, ax
    add  di, bp
    dec  dx
    jnz  @@row
    emms
  @@done:
    pop  es
    pop  ds
    pop  bp
    pop  di
    pop  si
end;

{ ----------------------------------------------------------------- content }

function Cfg: TCmpTierCfg;
begin
  Cfg := CmpTierCfg[CmpTier];
end;

{ Where the viewport sits in the mode. The low tier is narrower than the
  screen it runs in, so it is centred - and both paths have to agree about
  where, or the direct path and the presented path would draw two different
  pictures and the checksum would be the least of it. }
{ Where the viewport's first pixel goes in the card's own picture, as a byte
  offset from the start of it. Every tier but the standard one draws into a
  window narrower than the mode it is in, and the window is centred, so this
  is the one place that arithmetic is written down.

  Centring is not decoration. A viewport pinned to the top left leaves the
  card showing a band of whatever was in video memory down two sides of the
  screen, and the eye reads that as the frame being broken rather than as the
  frame being smaller than the mode. }
function VramBase: Word;
begin
  VramBase := ((Cfg.ModeH - Cfg.H) div 2) * Cfg.ModeW +
              ((Cfg.ModeW - Cfg.W) div 2);
end;

procedure BuildSin;
var I: Integer;
begin
  for I := 0 to 63 do
  begin
    SinT[I]       :=  SinQ[I];
    SinT[64 + I]  :=  SinQ[64 - I];
    SinT[128 + I] := -SinQ[I];
    SinT[192 + I] := -SinQ[64 - I];
  end;
end;

function CosT(I: Word): Integer;
begin
  CosT := SinT[(I + 64) and 255];
end;

{ The sine at half a step of the table, for the frames that fall between two
  of its entries - see Turns. The chord and not the arc, which is a tenth of
  a per cent short at this size and short by exactly the same tenth on every
  machine that runs it, which is the only property the frame checksum asks of
  anything here.

  Divided and not shifted: the sum of two entries is signed, a shift is not,
  and half the circle would come back as sixty-five thousand. Div truncates
  towards zero, so the two halves of the circle round the same way as each
  other and the picture stays centred. }
function SinH(H: Word): Integer;
var A: Word;
begin
  A := (H shr 1) and 255;
  if (H and 1) = 0 then SinH := SinT[A]
  else SinH := (SinT[A] + SinT[(A + 1) and 255]) div 2;
end;

function CosH(H: Word): Integer;
begin
  CosH := SinH(H + 128);
end;

{ Where one row of the texture starts. Rows are 256 bytes apart and 256 is a
  whole number of paragraphs, so every row has a segment of its own and is
  addressed by a plain byte index inside it. }
function TexRow(Y: Word): Word;
begin
  TexRow := FarSegAt(Tex, LongInt(Y) * TexStride);
end;

{ The texture, and what the whole picture is made of.

  Recursive value noise: a lattice of random bytes, doubled again and again
  with linear interpolation, and at every doubling a new layer of random half
  the amplitude of the last. That is cloud - detail at every scale, which is
  what the background kernel wants, because a fetch pattern over a smooth
  gradient would be regular enough for the machine to predict, and the whole
  point of the rotozoom is that it cannot be.

  Doubling wraps at the edges, so the texture tiles: the coordinate walk has
  no bounds check in it at all - it wraps because the arithmetic is a byte -
  and a texture that did not join up would show that as a seam through the
  middle of the frame.

  Then two finishing passes that cost nothing at run time and decide how it
  looks. The first stretches whatever range the noise happened to land in
  over the whole background ramp, through a 256-entry map, so the picture
  uses every colour it has rather than a grey third of them. The second lays
  an XOR plaid on top at a twentieth of the range - the oldest texture in the
  demoscene, and at that amplitude it reads as facets inside the clouds
  rather than as a chequerboard.

  All of it is integer and seeded by a constant, so two machines build the
  same texture down to the byte - which is what the frame CRC is there to
  prove. The whole thing is under a second even on a 286: the doublings cost
  about twice the final area between them, and there are two passes over it
  at the end. }
procedure BuildTexture;
var
  N, X, Y, Xn  : Word;
  Sg, Sg2      : Word;
  D0, D1       : Word;
  A, B, C, E   : Word;
  Amp          : Word;
  Rnd          : LongWord;
  V            : Integer;
  Lo, Hi       : Word;
  Mid, Dev     : Word;
  Sum, Cnt     : LongInt;
  P            : Byte;
  Step         : Word;
  { Three quarters of a kilobyte of locals, and the stack they sit on is in
    DGROUP with everything else. They are worth it - the map turns two passes
    over the texture into one lookup a pixel, and the two rows are what lets
    the doubling happen in place instead of in a second buffer - but they are
    the reason this procedure is the one place in the unit that thinks about
    the stack at all. }
  Map          : array[0..255] of Byte;
  RowY, RowN   : array[0..255] of Byte;
begin
  Rnd := 20260821;

  { The coarsest lattice: eight by eight, so one feature of it is a good
    third of the texture and the clouds have something large in them. }
  N := 8;
  for Y := 0 to N - 1 do
  begin
    Sg := TexRow(Y);
    for X := 0 to N - 1 do
    begin
      Rnd := Rnd * 1103515245 + 12345;
      Mem[Sg:X] := Byte((Rnd shr 16) and $FF);
    end;
  end;

  Amp := 128;
  while N < Cfg.TexPix do
  begin
    { Doubled in place, from the bottom up. Row Y produces rows 2Y and 2Y+1,
      which lie above every row still to be read - except at Y=0, and the two
      source rows are copied out before anything is written anyway. }
    for Y := N - 1 downto 0 do
    begin
      Sg  := TexRow(Y);
      Sg2 := TexRow((Y + 1) and (N - 1));
      for X := 0 to N - 1 do
      begin
        RowY[X] := Mem[Sg:X];
        RowN[X] := Mem[Sg2:X];
      end;
      D0 := TexRow(Y * 2);
      D1 := TexRow(Y * 2 + 1);
      for X := 0 to N - 1 do
      begin
        Xn := (X + 1) and (N - 1);
        A := RowY[X]; B := RowY[Xn];
        C := RowN[X]; E := RowN[Xn];
        Mem[D0:X * 2]     := Byte(A);
        Mem[D0:X * 2 + 1] := Byte((A + B + 1) shr 1);
        Mem[D1:X * 2]     := Byte((A + C + 1) shr 1);
        Mem[D1:X * 2 + 1] := Byte((A + B + C + E + 2) shr 2);
      end;
    end;
    N := N * 2;
    Amp := (Amp * 5) div 8;

    { The new layer, five eighths the amplitude of the one before rather than
      a half. A half is the textbook figure and it puts almost everything into
      the two coarsest layers, which through a rotozoom at this zoom is a
      smooth wash with nothing to see; five eighths leaves the fine layers
      still visible at the size the frame magnifies them to. }
    for Y := 0 to N - 1 do
    begin
      Sg := TexRow(Y);
      for X := 0 to N - 1 do
      begin
        Rnd := Rnd * 1103515245 + 12345;
        V := Integer(Mem[Sg:X]) +
             ((Integer((Rnd shr 16) and $FF) - 128) * Integer(Amp)) div 256;
        if V < 0 then V := 0;
        if V > 255 then V := 255;
        Mem[Sg:X] := Byte(V);
      end;
    end;
  end;

  { What range the noise actually used - not its extremes, but the range it
    spends its time in. The lowest and highest pixels of a field like this are
    outliers by construction, and stretching those onto the ends of the ramp
    leaves the whole picture crowded into the middle of it, which is the flat
    wash the first attempt produced. Mean and mean deviation instead, two and
    a quarter deviations either way, and the tails clamp: no histogram, so no
    half-kilobyte of stack for one. }
  Sum := 0;
  Cnt := LongInt(Cfg.TexPix) * Cfg.TexPix;
  for Y := 0 to Cfg.TexPix - 1 do
  begin
    Sg := TexRow(Y);
    for X := 0 to Cfg.TexPix - 1 do
      Sum := Sum + Mem[Sg:X];
  end;
  Mid := Word(Sum div Cnt);
  Sum := 0;
  for Y := 0 to Cfg.TexPix - 1 do
  begin
    Sg := TexRow(Y);
    for X := 0 to Cfg.TexPix - 1 do
    begin
      P := Mem[Sg:X];
      if P > Mid then Sum := Sum + (P - Mid) else Sum := Sum + (Mid - P);
    end;
  end;
  Dev := Word(Sum div Cnt);
  if Dev < 1 then Dev := 1;
  V := Integer(Mid) - Integer((Dev * 9) div 4);
  if V < 0 then V := 0;
  Lo := Word(V);
  V := Integer(Mid) + Integer((Dev * 9) div 4);
  if V > 255 then V := 255;
  Hi := Word(V);
  if Hi <= Lo then Hi := Lo + 1;
  for X := 0 to 255 do
  begin
    V := Integer(((LongInt(X) - Lo) * (BgHi - BgLo)) div (LongInt(Hi) - Lo)) +
         BgLo;
    if V < BgLo then V := BgLo;
    if V > BgHi then V := BgHi;
    Map[X] := Byte(V);
  end;

  { Stretched onto the ramp, with the plaid over it. The 128-pixel texture
    doubles the XOR's step so that both sizes get squares of the same size:
    the plaid is a property of the picture, not of how much of it there is. }
  Step := 256 div Cfg.TexPix;
  for Y := 0 to Cfg.TexPix - 1 do
  begin
    Sg := TexRow(Y);
    for X := 0 to Cfg.TexPix - 1 do
    begin
      V := Integer(Map[Mem[Sg:X]]) +
           (Integer(((X xor Y) * Step) and 255) - 128) div 12;
      if V < BgLo then V := BgLo;
      if V > BgHi then V := BgHi;
      Mem[Sg:X] := Byte(V);
    end;
  end;
end;

{ The lens: where each of its pixels comes from, and the ring round it.

  A magnifier, done the way the era did it - not by tracing rays but by a
  table built once. The sample point is pulled towards the middle of the lens
  by a factor strongest at the centre and weakest at the rim, so the picture
  under the glass is stretched outwards. Every sample lands inside the lens
  rectangle, which is what lets the whole effect work out of one scratch
  buffer.

  Two profiles came before this one and both were wrong in the same way. The
  pull was one minus a parabola first, which is the shape that is easiest to
  write down and the wrong one to look at: a parabola in r squared is nearly
  flat over the outer half of the disc, so most of the glass did nothing at
  all and the effect read as a slight smudge somebody had left on the screen.
  Then it was the height of a ball of glass, the dome sqrt(1 - (r/R)^2), which
  is strong right out to where it drops off a cliff at the rim - and that made
  the glass easy to see and put a hard ring across the middle of it.

  What both had in common was the rim, and the arithmetic there is forced.
  Magnification is the derivative of the map from a pixel's radius to its
  sample's, so a map asked to magnify the middle and to land back on the rim
  where it started has to compress the outside to make room for what the
  middle took - and it does not do it gently: under the dome the outer third
  of the radius came out squeezed five to one, and a fifth of a pixel to the
  step is not glass, it is a seam halfway out.

  So this map does not come back to the rim at all, and once that is given up
  the profile can be what a magnifier actually does: magnify more towards the
  edge and not less. The eye is the stop and it sits behind the glass, so the
  field is stretched further the further out it is read - about two and a
  third times in the middle here and three and a fifth at the rim. What is
  inside the glass is then the middle third of what it covers, blown up, and
  it meets the frame at a step which the ring covers. That is what a lens over
  a page looks like: a circle of magnified page, an edge, and the page.

  The sample position is kept in sixteenths of a pixel: the whole part is the
  offset the gather reads from, and the fraction is the table page it blends
  through (LensGather). Interpolating is not a nicety at two and a half times
  magnification - without it the middle of the lens is four-pixel squares, and
  squares are what everything else in this frame is trying not to be.

  Both tables are laid out in doubled coordinates, dx = 2x - (w-1), because
  the lens is an even number of pixels across, its centre falls between two of
  them, and a radius counted from a pixel centre comes out a pixel longer on
  one side than the other. That is what made the old ring look like an egg
  with a flat side. The pull is divided symmetrically about zero for the same
  reason: Pascal's div truncates towards zero, so the plain form would shorten
  every negative offset by one sixteenth and put the lens half a pixel off
  centre in both axes.

  The ring is a masked sprite like any other, drawn by the sprite kernel from
  the same list the step kernel writes: two pixels of one neutral grey, and
  nothing else. It used to be a four-pixel gradient with a dark pixel outside
  it, which at this size is not a rim but a smear - and a gradient says the
  surface is curved, which is the sprites' job in this picture and not the
  glass's. What the glass needs is an edge, so that is all it has. }

{ D scaled by F/256, in sixteenths of a pixel, and symmetric about zero. }
function LensPull(D, F: Integer): Integer;
begin
  if D < 0 then LensPull := -((-D * F) div 32)
  else LensPull := (D * F) div 32;
end;

procedure BuildLens;
var
  X, Y, W     : Integer;
  Dx, Dy, R2  : Integer;
  Rd, Rr, F   : Integer;
  Sx, Sy      : Integer;
  Wt, Df      : Integer;
  At, Mb      : Word;
  V           : Integer;
begin
  if Cfg.Lenses = 0 then Exit;
  W  := Cfg.LensW;
  { The rim, in doubled units. One pixel short of the bitmap's edge, so the
    ring is drawn complete rather than with its outermost row cut away. }
  Rd := W - 3;
  Rr := Rd * Rd;

  { The blend table: sixteen pages, each holding every difference from -256
    to 255 scaled by that page's weight, at index difference plus 256. Page
    zero is all zeroes, which is what makes an uninterpolated pixel free
    rather than special. }
  At := OfsLensMul;
  for Wt := 0 to LnsMulW - 1 do
    for Df := -256 to 255 do
    begin
      Mem[AuxSeg:At] := Byte((Df * Wt) div 16);
      Inc(At);
    end;

  Mb := OfsLensMul;
  At := OfsLensLut;
  for Y := 0 to W - 1 do
    for X := 0 to W - 1 do
    begin
      Dx := 2 * X - (W - 1); Dy := 2 * Y - (W - 1);
      R2 := Dx * Dx + Dy * Dy;
      { Outside the rim the factor is exactly 256, which is exactly identity:
        offset x, fraction nothing. No branch is needed in the gather, and the
        corners of the patch are the frame itself, passed through untouched.
        Inside it the factor is the quadratic the constants describe, falling
        from 256-LnsDepth at the centre to LnsRim less than that at the rim -
        a pull that shortens the radius by a little more the further out it
        is taken, which is a magnification that grows with it. }
      if R2 >= Rr then F := 256
      else
        F := (256 - LnsDepth) -
             Integer((LongInt(LnsRim) * R2) div LongInt(Rr));
      Sx := 8 * (W - 1) + LensPull(Dx, F);
      Sy := 8 * (W - 1) + LensPull(Dy, F);
      MemW[AuxSeg:At]     := Word((Sy shr 4) * Integer(Cfg.W) + (Sx shr 4));
      MemW[AuxSeg:At + 2] := Word((Sy shr 4) * Integer(Cfg.W) + (Sx shr 4) +
                                  Integer(Cfg.W));
      { The address of difference zero on that fraction's page, so the
        kernel adds a signed difference straight onto it. }
      MemW[AuxSeg:At + 4] := Mb + Word(Sx and 15) * 512 + 256;
      MemW[AuxSeg:At + 6] := Mb + Word(Sy and 15) * 512 + 256;
      Inc(At, 8);
    end;

  { The ring, as the band of pixels whose centres lie within one pixel of the
    rim - a distance test rather than a run of integer radii, because the
    radii are what left the old ring flat where the lattice happened to be
    kind to it. Squared throughout: a square root that has to give the same
    answer on a 286 and a Pentium is not worth writing. }
  At := OfsLensRing;
  for Y := 0 to W - 1 do
    for X := 0 to W - 1 do
    begin
      Dx := 2 * X - (W - 1); Dy := 2 * Y - (W - 1);
      R2 := Dx * Dx + Dy * Dy;
      { Half open, and that is the two pixels: centres sit two units apart,
        so a band closed at both ends would be three of them wide on the
        axes and two everywhere else. }
      if (R2 >= (Rd - 2) * (Rd - 2)) and (R2 < (Rd + 2) * (Rd + 2)) then
        V := LnsCol
      else V := 0;
      Mem[AuxSeg:At] := Byte(V);
      Inc(At);
    end;
end;

{ ----------------------------------------------------------------- palette }

{ The palette this suite draws in, and the difference between a texture and a
  field of noise. Mode 13h comes up with the default DAC - sixteen EGA
  colours, sixteen greys, then blocks of HSV - where neighbouring indices are
  unrelated colours, so a smooth field of bytes drawn through it is confetti
  however good the generator was. Programming the DAC is the single change
  that makes the frame worth looking at, and it costs nothing at run time.

  Cool for the background and warm for what is drawn over it: complementary
  hues are what make a sprite read as an object on top of a texture rather
  than as a hole in it, and no amount of brightness does the same job.

  Corner points only, interpolated on the way out to the card. Two hundred and
  fifty-six colours held here would be three quarters of a kilobyte of DGROUP,
  and DGROUP is the segment this program is genuinely short of - what is left
  of it after the statics is the near heap, so a table here is not paid for in
  memory that was going spare. Corners are forty bytes.

  Five segments across the background rather than one, because a straight line
  from black to white through blue spends most of itself in shades a monitor
  of the era cannot tell apart. }
const
  PalStopN = 13;
  PalStops : array[0..PalStopN - 1, 0..3] of Byte = (
    { the background ramp: night, deep blue, sea, turquoise, mint, white }
    (BgLo,        0,  2, 10),
    (BgLo +  48,  6, 12, 34),
    (BgLo +  96, 10, 34, 52),
    (BgLo + 136, 26, 56, 60),
    (BgLo + 168, 52, 62, 58),
    (BgHi,       63, 63, 63),
    { the body of a sprite: ember at its rim, white-gold at its centre. It
      starts well clear of black, because the ramp is what shades the shape
      and the contour is what ends it - a body that faded out would put two
      of those jobs on the same pixels and do neither. }
    (SprLo,      46, 16,  2),
    (SprLo + 24, 60, 38,  8),
    (SprHi,      63, 62, 44),
    { and the contour round it, which is a step sideways out of that ramp
      rather than the far end of it }
    (SprEdge,    63, 26,  0),
    { the shadow, the lens rim, and then the letter over them }
    (ShaCol,      0,  0,  0),
    (LnsCol,     44, 44, 44),
    (TxtCol,     63, 63, 63));

procedure OutB(P: Word; V: Byte); assembler;
asm
    mov dx, P
    mov al, V
    out dx, al
end;

{ Into the card, one straight line between corners at a time. Six-bit
  components, which is what the DAC takes unless somebody has asked it for
  eight - and nothing here does, because a card that has not been asked is
  entitled to be in either state and the six-bit form works in both.

  Both modes this suite uses are 256-colour and both take the palette through
  the same three ports: a VBE mode is still a VGA DAC. }
procedure PalApply;
var
  I, K, C : Word;
  D, L, R : Integer;
begin
  OutB($3C8, 0);
  K := 0;
  for I := 0 to 255 do
  begin
    while (K < PalStopN - 2) and (I > PalStops[K + 1][0]) do Inc(K);
    L := Integer(I) - Integer(PalStops[K][0]);
    D := Integer(PalStops[K + 1][0]) - Integer(PalStops[K][0]);
    if D <= 0 then D := 1;
    R := D - L;
    for C := 1 to 3 do
      OutB($3C9, Byte((Integer(PalStops[K][C]) * R +
                       Integer(PalStops[K + 1][C]) * L) div D));
  end;
end;

{ The star's shape, as a distance in which the axes count for less than the
  diagonals: |dx| + |dy| + k|min|, so the arms run out along the axes and the
  corners are empty. k is what separates a fat diamond from a thin spike.

  Coordinates are doubled - dx = 2x - (w-1) - and that is the whole reason
  this is a function rather than four lines inside the loop. A sprite is an
  even number of pixels across, so its centre falls between two of them; a
  distance measured from a pixel centre is a pixel further from one side than
  from the other, and at sixteen pixels wide that lopsidedness is visible.
  Doubling puts the centre on a coordinate that exists. }
function StarD(Dx, Dy, K: Integer): Integer;
var Ax, Ay, Mn: Integer;
begin
  if Dx < 0 then Ax := -Dx else Ax := Dx;
  if Dy < 0 then Ay := -Dy else Ay := Dy;
  if Ax < Ay then Mn := Ax else Mn := Ay;
  StarD := Ax + Ay + K * Mn;
end;

{ Eight stars: a contour, a shaded body inside it, and transparency outside.

  A star rather than the disc that used to be here, and not only because it
  looks like something: the mask is the whole point of this stage, and a
  shape with thin arms puts the branch the kernel cannot predict in the middle
  of the sprite instead of only round its rim.

  The contour is what was learned from looking at the thing on a screen. The
  body used to fade to the bottom of its ramp at the edge, which is the way a
  glow is drawn at a resolution that has pixels to spare - and at 320x200 it
  reads as a smudge with no edge, over a background that is itself every
  brightness from night to white. So the outermost pixel of the shape is one
  saturated colour instead, one pixel wide, and the gradient is kept for the
  inside where it does what a gradient is for: saying which way the surface
  turns.

  Outermost is decided by asking, not by arithmetic on the distance: a pixel
  is on the contour when it is inside the shape and one of its four
  neighbours is not. That is the same test whatever k does to the shape, and
  it cannot leave a gap in an arm the way a band of distances can.

  The radius stops one pixel short of the pattern's edge, so the arms end
  inside the box and the tips are contour like everything else. A shape cut
  off by the edge of its own bitmap looks exactly like a sprite clipped by
  something, which is the one thing these are not.

  Index 0 is the transparent one and no sprite writes it. }
procedure BuildSprites;
var
  P, X, Y    : Word;
  Dx, Dy     : Integer;
  D, R, K    : Integer;
  W          : Integer;
  V          : Integer;
  At         : Word;
begin
  W  := Cfg.SprW;
  At := OfsPats;
  for P := 0 to SprPats - 1 do
  begin
    K := 1 + (P and 3);
    R := (W - 1) - Integer(P shr 2) * 2;
    for Y := 0 to Cfg.SprW - 1 do
      for X := 0 to Cfg.SprW - 1 do
      begin
        Dx := 2 * Integer(X) - (W - 1);
        Dy := 2 * Integer(Y) - (W - 1);
        D  := StarD(Dx, Dy, K);
        if D >= R then V := 0
        else if (StarD(Dx - 2, Dy, K) >= R) or (StarD(Dx + 2, Dy, K) >= R) or
                (StarD(Dx, Dy - 2, K) >= R) or (StarD(Dx, Dy + 2, K) >= R) then
          V := SprEdge
        else V := SprLo + ((Integer(SprHi - SprLo) * (R - D)) div R);
        Mem[AuxSeg:At] := Byte(V);
        Inc(At);
      end;
  end;
end;

{ A font of our own, and deliberately not the one in the video ROM. The frame
  CRC has to mean the same thing on every machine, and ROM fonts differ - an
  EGA card and a late VGA do not agree on every glyph, which would turn a
  correctness witness into a report of which card was fitted.

  Sixty-four glyphs, space through underscore, five columns by seven rows in
  an eight by eight cell. Upper case only, which is what a status line drawn
  eight pixels high wants anyway.

  The bitmaps sit in the code segment rather than in a Pascal array, and that
  is not a flourish. Every global in this program shares one 64K segment with
  the stack and the near heap, and what is left of it is measured in hundreds
  of bytes - a 512-byte table here would be 512 bytes the heap does not get,
  which is how the palette killed the program at startup once already. Code
  segments are the one thing this model has plenty of.

  So the glyphs are laid down with db behind a jump, and the copy out of them
  is the same routine: CS is the segment the assembler resolved the label in,
  which makes this the shortest correct way to read one's own code. }
procedure CopyFont(Seg_, Ofs_: Word); assembler;
asm
    push ds
    push si
    push di
    mov  es, Seg_
    mov  di, Ofs_
    mov  ax, cs
    mov  ds, ax
    mov  si, offset @@bits
    mov  cx, FontBytes
    cld
    rep  movsb
    pop  di
    pop  si
    pop  ds
    jmp  @@out
  @@bits:
    db $00,$00,$00,$00,$00,$00,$00,$00    { space }
    db $20,$20,$20,$20,$20,$00,$20,$00    { ! }
    db $50,$50,$00,$00,$00,$00,$00,$00    { " }
    db $50,$50,$F8,$50,$F8,$50,$50,$00    { # }
    db $20,$78,$A0,$70,$28,$F0,$20,$00    { $ }
    db $C8,$C8,$10,$20,$40,$98,$98,$00    { % }
    db $60,$90,$A0,$40,$A8,$90,$68,$00    { & }
    db $20,$20,$00,$00,$00,$00,$00,$00    { apostrophe }
    db $10,$20,$40,$40,$40,$20,$10,$00    { ( }
    db $40,$20,$10,$10,$10,$20,$40,$00    { ) }
    db $00,$A8,$70,$F8,$70,$A8,$00,$00    { * }
    db $00,$20,$20,$F8,$20,$20,$00,$00    { + }
    db $00,$00,$00,$00,$30,$20,$40,$00    { , }
    db $00,$00,$00,$F8,$00,$00,$00,$00    { - }
    db $00,$00,$00,$00,$00,$60,$60,$00    { . }
    db $08,$10,$10,$20,$40,$40,$80,$00    { / }
    db $70,$88,$98,$A8,$C8,$88,$70,$00    { 0 }
    db $20,$60,$20,$20,$20,$20,$70,$00    { 1 }
    db $70,$88,$08,$10,$20,$40,$F8,$00    { 2 }
    db $F8,$10,$20,$10,$08,$88,$70,$00    { 3 }
    db $10,$30,$50,$90,$F8,$10,$10,$00    { 4 }
    db $F8,$80,$F0,$08,$08,$88,$70,$00    { 5 }
    db $30,$40,$80,$F0,$88,$88,$70,$00    { 6 }
    db $F8,$08,$10,$20,$40,$40,$40,$00    { 7 }
    db $70,$88,$88,$70,$88,$88,$70,$00    { 8 }
    db $70,$88,$88,$78,$08,$10,$60,$00    { 9 }
    db $00,$60,$60,$00,$60,$60,$00,$00    { : }
    db $00,$60,$60,$00,$60,$20,$40,$00    { ; }
    db $10,$20,$40,$80,$40,$20,$10,$00    { < }
    db $00,$00,$F8,$00,$F8,$00,$00,$00    { = }
    db $40,$20,$10,$08,$10,$20,$40,$00    { > }
    db $70,$88,$08,$10,$20,$00,$20,$00    { ? }
    db $70,$88,$B8,$A8,$B8,$80,$70,$00    { @ }
    db $20,$50,$88,$88,$F8,$88,$88,$00    { A }
    db $F0,$88,$88,$F0,$88,$88,$F0,$00    { B }
    db $70,$88,$80,$80,$80,$88,$70,$00    { C }
    db $E0,$90,$88,$88,$88,$90,$E0,$00    { D }
    db $F8,$80,$80,$F0,$80,$80,$F8,$00    { E }
    db $F8,$80,$80,$F0,$80,$80,$80,$00    { F }
    db $70,$88,$80,$B8,$88,$88,$70,$00    { G }
    db $88,$88,$88,$F8,$88,$88,$88,$00    { H }
    db $70,$20,$20,$20,$20,$20,$70,$00    { I }
    db $38,$10,$10,$10,$10,$90,$60,$00    { J }
    db $88,$90,$A0,$C0,$A0,$90,$88,$00    { K }
    db $80,$80,$80,$80,$80,$80,$F8,$00    { L }
    db $88,$D8,$A8,$A8,$88,$88,$88,$00    { M }
    db $88,$C8,$A8,$98,$88,$88,$88,$00    { N }
    db $70,$88,$88,$88,$88,$88,$70,$00    { O }
    db $F0,$88,$88,$F0,$80,$80,$80,$00    { P }
    db $70,$88,$88,$88,$A8,$90,$68,$00    { Q }
    db $F0,$88,$88,$F0,$A0,$90,$88,$00    { R }
    db $70,$88,$80,$70,$08,$88,$70,$00    { S }
    db $F8,$20,$20,$20,$20,$20,$20,$00    { T }
    db $88,$88,$88,$88,$88,$88,$70,$00    { U }
    db $88,$88,$88,$88,$88,$50,$20,$00    { V }
    db $88,$88,$88,$A8,$A8,$D8,$88,$00    { W }
    db $88,$88,$50,$20,$50,$88,$88,$00    { X }
    db $88,$88,$50,$20,$20,$20,$20,$00    { Y }
    db $F8,$08,$10,$20,$40,$80,$F8,$00    { Z }
    db $70,$40,$40,$40,$40,$40,$70,$00    { [ }
    db $80,$40,$40,$20,$10,$10,$08,$00    { \ }
    db $70,$10,$10,$10,$10,$10,$70,$00    { ] }
    db $20,$50,$88,$00,$00,$00,$00,$00    { ^ }
    db $00,$00,$00,$00,$00,$00,$F8,$00    { _ }
  @@out:
end;

{ The rotation, one entry per frame of the cycle. The row step is the pixel
  step turned ninety degrees, which is what makes it a rotation rather than a
  shear; the scale breathes on a sine three times round the cycle, and the
  centre drifts on another, so the picture never quite repeats until the whole
  cycle does.

  Every one of the three closes exactly on Turns frames - the angle by making
  a whole turn, the other two by being sines of a whole number of periods - so
  the last frame of the cycle leads into the first with nothing to see at the
  join.

  The coordinates are for the top-left pixel of the viewport, and they are
  worked back from the centre rather than being the centre. That is the whole
  difference between a picture that spins and one that swings: rotating about
  the corner sends the middle of the frame round an orbit of half the diagonal,
  which is what the eight-slot version did, and at forty-five degrees a frame
  it read as a slideshow. }
procedure BuildTurns;
var
  S     : Word;
  At    : Word;
  Sc    : LongInt;
  Du, Dv, Rdu, Rdv : Integer;
  Cu, Cv : LongInt;
begin
  At := OfsRot;
  for S := 0 to Turns - 1 do
  begin
    { Half-steps throughout, so the whole cycle is one turn of the angle and
      three of the zoom however many frames it is spread over. }
    Sc := 176 + (LongInt(SinH((S * 3) and (Turns - 1))) div 80);
    Du  := Integer((LongInt(CosH(S)) * Sc) div 4096);
    Dv  := Integer((LongInt(SinH(S)) * Sc) div 4096);
    Rdu := -Dv;
    Rdv := Du;
    { Where the middle of the viewport sits in the texture, and then the
      corner the walk actually starts from. Four 8.8 units of drift per unit
      of sine is a sweep of sixty-four texels either way. }
    Cu := LongInt(SinH(S)) * 4;
    Cv := LongInt(CosH(S)) * 4;
    MemW[AuxSeg:At]     := Word((Cu - LongInt(Cfg.W div 2) * Du
                                    - LongInt(Cfg.H div 2) * Rdu) and $FFFF);
    MemW[AuxSeg:At + 2] := Word((Cv - LongInt(Cfg.W div 2) * Dv
                                    - LongInt(Cfg.H div 2) * Rdv) and $FFFF);
    MemW[AuxSeg:At + 4] := Word(Du);
    MemW[AuxSeg:At + 6] := Word(Dv);
    MemW[AuxSeg:At + 8] := Word(Rdu);
    MemW[AuxSeg:At + 10] := Word(Rdv);
    Inc(At, RotBytes);
  end;
end;

{ The status line, as list entries for the text kernel.

  One list rather than one per frame. Every glyph cell is filled whether or
  not there is a letter in it, so the work the text stage measures depends on
  the tier and not on which test happens to be running - a line that drew only
  its non-blank cells would make the frame cheaper whenever the caption was
  short, which is measuring the caption.

  Both rows sit inside the last band, clear of its top edge, so a glyph is
  never split across a band; CmpInit checks the twenty-four rows of slack that
  relies on. The shadow is a row lower and a column further right, and the
  slack covers that too.

  Two lists, one after the other and the same length: the shadow first, then
  the letters. White on a texture that runs all the way to white is not
  readable anywhere the two meet, and an outline the same shape as the glyph,
  a pixel down and across, is what a game of the era did about it. Two passes
  of the kernel rather than a colour per entry, because the kernel holds the
  colour in a register for the whole list - and the entry is eight bytes,
  which a shift can index. }
procedure TextBuild;
var
  Row, G, B  : Word;
  Ty, At, Ch : Word;
  Pass       : Word;
  Ox, Oy     : Word;
  S          : String[40];
begin
  At   := OfsText;
  TxtN := GlyphsPerRow * TextRows;
  for Pass := 0 to 1 do
  begin
    if Pass = 0 then begin Ox := 1; Oy := 1 end
                else begin Ox := 0; Oy := 0 end;
    for Row := 0 to TextRows - 1 do
    begin
      if Row = 0 then S := StatTop else S := StatBot;
      Ty := Cfg.H - 24 + Row * 10 + Oy;
      B  := Ty div DstRows;
      if B >= DstBands then B := DstBands - 1;
      for G := 0 to GlyphsPerRow - 1 do
      begin
        if G < Length(S) then Ch := Ord(S[G + 1]) else Ch := 32;
        MemW[AuxSeg:At]     := DstSeg[B];
        MemW[AuxSeg:At + 2] := DstBase[B] + (Ty - B * DstRows) * DstStride +
                               16 + G * 8 + Ox;
        MemW[AuxSeg:At + 4] := OfsFont + (Ch - FontFirst) * 8;
        MemW[AuxSeg:At + 6] := DstStride - 8;
        Inc(At, 8);
      end;
    end;
  end;
end;

procedure CmpStatus(const Top, Bot: String);

  function Cook(const S: String): String;
  var I: Word; C: Char; R: String[40];
  begin
    R := '';
    for I := 1 to Length(S) do
    begin
      if Length(R) >= 40 then Break;
      C := S[I];
      if (C >= 'a') and (C <= 'z') then C := Chr(Ord(C) - 32);
      if (C < ' ') or (C > '_') then C := ' ';
      R := R + C;
    end;
    Cook := R;
  end;

begin
  StatTop := Cook(Top);
  StatBot := Cook(Bot);
  if CmpReady and (PlaceFor >= 0) then TextBuild;
end;

{ ------------------------------------------------------------- destination }

{ Where the next frame is drawn: the back buffer, or video memory itself.
  Everything downstream reads these, so the direct path is a different
  destination and not a different set of kernels. }
procedure SetDest(ToVram: Boolean);
var B: Word;
begin
  DstToVram := ToVram;
  if ToVram then
  begin
    DstSeg[0]  := VgaSeg;
    DstBase[0] := VramBase;
    DstBands   := 1;
    DstRows    := Cfg.H;
    DstStride  := Cfg.ModeW;
  end
  else
  begin
    for B := 0 to Cfg.Bands - 1 do
    begin
      DstSeg[B]  := FarSegAt(Back, LongInt(B) * BandBytes);
      DstBase[B] := 0;
    end;
    DstBands  := Cfg.Bands;
    DstRows   := Cfg.BandRows;
    DstStride := Cfg.W;
  end;
end;

{ ----------------------------------------------------- placement, built once }

{ Where the sprites start, and how fast they drift. Built once per
  destination, and again before every test, so that two runs of the same test
  on the same machine draw the same frames - the state is what the motion
  integrates from, and a benchmark whose picture depended on how many frames
  the last test happened to fit would have no checksum worth printing.

  Positions come from a small linear congruential generator, so they are
  scattered, they are the same on every machine, and they cost nothing to
  reproduce. Speeds are a quarter to a pixel and a quarter a frame: slow
  enough to look like drift, fast enough that a machine drawing five frames a
  second still shows movement.

  Per frame and never per second, like everything else here. A fast machine
  runs the same animation faster, which is the honest thing for a frame
  counter to show. }

function Lcg(var S: LongWord): Word;
begin
  S := S * 1103515245 + 12345;
  Lcg := Word((S shr 16) and $7FFF);
end;

{ One list entry, written out. The kernels take six words in a fixed order,
  and the self-check builds one by hand - which is the only reason this is a
  procedure rather than six stores inside the one place that fills lists. }
procedure PutEnt(At: Word; DSeg, DOfs, SOfs, Rows, Chunks, RowAdd: Word);
begin
  MemW[AuxSeg:At]      := DSeg;
  MemW[AuxSeg:At + 2]  := DOfs;
  MemW[AuxSeg:At + 4]  := SOfs;
  MemW[AuxSeg:At + 6]  := Rows;
  MemW[AuxSeg:At + 8]  := Chunks;
  MemW[AuxSeg:At + 10] := RowAdd;
end;

procedure ResetObjects;
var
  I, At : Word;
  Rnd   : LongWord;
  Sp    : Integer;
begin
  Rnd := LongWord(20260821);
  At  := OfsSprSt;
  for I := 0 to Cfg.Sprites - 1 do
  begin
    MemW[AuxSeg:At]     := Lcg(Rnd) mod (Word(Cfg.W - Cfg.SprW) * 16);
    MemW[AuxSeg:At + 2] := Lcg(Rnd) mod (Word(Cfg.H - Cfg.SprW) * 16);
    Sp := 4 + (Lcg(Rnd) mod 17);
    if (Lcg(Rnd) and 1) <> 0 then Sp := -Sp;
    MemW[AuxSeg:At + 4] := Word(Sp);
    Sp := 4 + (Lcg(Rnd) mod 17);
    if (Lcg(Rnd) and 1) <> 0 then Sp := -Sp;
    MemW[AuxSeg:At + 6] := Word(Sp);
    MemW[AuxSeg:At + 8] := OfsPats + (Lcg(Rnd) and (SprPats - 1)) * SprBytes;
    Inc(At, 10);
  end;

  { The lenses, half the speed of a sprite and one to a band. A band is the
    whole viewport on both mode 13h tiers, so there they simply drift. }
  { Guarded, because a tier can have none of them and the counter here is a
    Word: 'to Cfg.Lenses - 1' with no lenses is 'to 65535', which is a loop
    that writes twelve bytes sixty-five thousand times over everything the
    aux segment holds. It hangs, and it hangs before the first line of output
    has been flushed - which is a good deal harder to find than to prevent. }
  if Cfg.Lenses = 0 then Exit;
  At := OfsLensSt;
  for I := 0 to Cfg.Lenses - 1 do
  begin
    MemW[AuxSeg:At]     := Lcg(Rnd) mod (Word(Cfg.W - Cfg.LensW) * 16);
    MemW[AuxSeg:At + 2] := Lcg(Rnd) mod (Word(DstRows - Cfg.LensW) * 16);
    Sp := 2 + (Lcg(Rnd) mod 7);
    if (Lcg(Rnd) and 1) <> 0 then Sp := -Sp;
    MemW[AuxSeg:At + 4] := Word(Sp);
    Sp := 2 + (Lcg(Rnd) mod 7);
    if (Lcg(Rnd) and 1) <> 0 then Sp := -Sp;
    MemW[AuxSeg:At + 6] := Word(Sp);
    MemW[AuxSeg:At + 8]  := DstSeg[I mod DstBands];
    MemW[AuxSeg:At + 10] := DstBase[I mod DstBands];
    Inc(At, 12);
  end;
end;

{ The bands of the destination, in the aux segment where the placement kernel
  can reach them with the same DS it walks everything else with. Four bytes a
  band, and there are never more than eight. }
procedure BuildPlacement;
var B, At: Word;
begin
  At := OfsBands;
  for B := 0 to DstBands - 1 do
  begin
    MemW[AuxSeg:At]     := DstSeg[B];
    MemW[AuxSeg:At + 2] := DstBase[B];
    Inc(At, 4);
  end;

  KSpSt     := OfsSprSt;
  KSpN      := Cfg.Sprites;
  KSpList   := OfsLists;
  KSpW      := Cfg.SprW;
  KSpChunks := Cfg.SprW div 4;
  KSpRowAdd := DstStride - Cfg.SprW;
  KSpXMax   := Word(Cfg.W - Cfg.SprW) * 16;
  KSpYMax   := Word(Cfg.H - Cfg.SprW) * 16;
  KSpRows   := DstRows;
  KSpStride := DstStride;
  KSpBands  := DstBands;
  KSpBandT  := OfsBands;

  KLnSt     := OfsLensSt;
  KLnN      := Cfg.Lenses;
  KLnList   := OfsLensList;
  KLnRing   := OfsLensRing;
  KLnW      := Cfg.LensW;
  KLnChunks := Cfg.LensW div 4;
  KLnRowAdd := DstStride - Cfg.LensW;
  KLnXMax   := Word(Cfg.W - Cfg.LensW) * 16;
  KLnYMax   := Word(DstRows - Cfg.LensW) * 16;
  KLnStride := DstStride;
  KLnLut    := OfsLensLut;
  KLnScr    := OfsLensScr;
  KLnPix    := Cfg.LensW * Cfg.LensW;

  ResetObjects;
  if DstToVram then PlaceFor := 1 else PlaceFor := 0;
  TextBuild;
end;

procedure NeedPlacement(ToVram: Boolean);
begin
  if (PlaceFor = Ord(ToVram)) and (DstToVram = ToVram) then Exit;
  SetDest(ToVram);
  BuildPlacement;
end;

{ --------------------------------------------------------------- the stages }

procedure StageBack;
var B: Word; U, V: Word; R: Word;
begin
  R := OfsRot + Turn * RotBytes;
  U := MemW[AuxSeg:R];        V := MemW[AuxSeg:R + 2];
  KDu := MemW[AuxSeg:R + 4];  KDv := MemW[AuxSeg:R + 6];
  KRdu := MemW[AuxSeg:R + 8]; KRdv := MemW[AuxSeg:R + 10];
  KTexSeg := TexSeg;
  KChunks := Cfg.W div 8;
  KRowAdd := DstStride - Cfg.W;
  for B := 0 to DstBands - 1 do
  begin
    KDstSeg := DstSeg[B];
    KDstOfs := DstBase[B];
    KRows   := DstRows;
    KU := U; KV := V;
    if Tex256 then BgBand256 else BgBand128;
    { The kernel leaves the coordinates advanced past its last row, which is
      exactly where the next band starts. }
    U := KU; V := KV;
  end;
end;

procedure StageSprites;
begin
  KSprSeg := AuxSeg;
  SprPlace;
  KSprPtr := OfsLists;
  KSprN   := KSpOut;
  SprList;
end;

procedure StageText;
begin
  KSprSeg := AuxSeg;
  KTxtN   := TxtN;
  KTxtPtr := OfsText;             { the shadow, a pixel down and across }
  KTxtCol := ShaCol;
  TxtList;
  KTxtPtr := OfsText + TxtN * 8;  { and the letter over it }
  KTxtCol := TxtCol;
  TxtList;
end;

procedure CopyRun(Kind: TCmpKind; SrcSeg, SrcOfs, DSeg, DOfs: Word;
                  RowBytes, Rows, SrcStride, DstStride_: Word); forward;

{ The lenses over the frame. Two kernels and a copy each: gather the
  distorted rectangle into the scratch, blit it back, and then all the rings
  in one pass of the sprite kernel.

  Not on the direct path. A lens reads the frame it is drawing into, and on
  that path the frame is in video memory - where a read costs several times
  what a write does on the bus of the era, and the effect would be measuring
  the card's read port rather than the machine. The buffered frame draws them
  and the direct frame does not, which is a real answer to the question the
  two paths are there to ask: an effect that reads the picture back needs a
  back buffer.

  Not at the low tier either, where the tier table asks for none of them - see
  the note beside it. A tier with no lenses has no lens test in the table, so
  this is not a stage timed at zero, it is a stage that is not there. }
procedure StageLens;
var L, E: Word;
begin
  if DstToVram or (Cfg.Lenses = 0) then Exit;
  KSprSeg := AuxSeg;
  LensStep;
  E := OfsLensList;
  for L := 0 to Cfg.Lenses - 1 do
  begin
    KLnSeg := MemW[AuxSeg:E];
    KLnOfs := MemW[AuxSeg:E + 2];
    LensGather;
    CopyRun(ckPreW, AuxSeg, OfsLensScr, KLnSeg, KLnOfs,
            Cfg.LensW, Cfg.LensW, Cfg.LensW, DstStride);
    Inc(E, 12);
  end;
  KSprPtr := OfsLensList;
  KSprN   := Cfg.Lenses;
  SprList;
end;

{ One rectangle, in one of the three forms.

  RowBytes has to divide by 4 for the MOVSD form and by 32 for the MOVQ one,
  and every size that reaches here does: the viewports are 256, 320 and 512
  wide, the whole-frame copies are 51200 and 64000 bytes, and the pieces the
  banked path cuts are all multiples of 64 - the high tier's rows start at
  byte 64 of a 640 byte row, are 512 bytes long, and are cut where a window
  ends, which is a whole number of kilobytes in. It is a property of the tier table
  rather than a check here, and it is written down because a fourth tier could
  quietly break it. }
procedure CopyRun(Kind: TCmpKind; SrcSeg, SrcOfs, DSeg, DOfs: Word;
                  RowBytes, Rows, SrcStride, DstStride_: Word);
begin
  KCSrcSeg := SrcSeg; KCSrcOfs := SrcOfs;
  KCDstSeg := DSeg;   KCDstOfs := DOfs;
  KCRows   := Rows;
  KCSrcAdd := SrcStride - RowBytes;
  KCDstAdd := DstStride_ - RowBytes;
  case Kind of
    ckPreD : begin KCUnits := RowBytes div 4;  CopyD end;
    ckPreQ : begin KCUnits := RowBytes div 32; CopyQ end;
  else
    KCUnits := RowBytes div 2; CopyW;
  end;
end;

{ The frame out to the card.

  Mode 13h at 320x200 is the whole mode, so the frame is one contiguous run of
  64000 bytes and the present is one call - which is what a game of the era
  did, and what makes it the cheapest present in the table. Every other tier
  draws a viewport narrower than the mode it is in, and there a row of the
  frame and a row of the card are different lengths: the copy carries a stride
  and walks rows.

  In 101h the card also shows only 64K at a time, and that is the whole of the
  difficulty. A row is 512 bytes at a stride of 640, so the rows of one window
  are a rectangle - one call of the copy kernel, whatever their number - and
  exactly one row in each window has its far end in the next one. That row is
  cut in two with the window moved between the halves, and the rectangle
  starts again after it.

  A row at a time would have been simpler and it is not what this does: 480
  calls of a kernel that copies 512 bytes is 480 lots of set-up inside the one
  measurement that is supposed to be about the machine's memory bus. Grouping
  them puts the count back to about fifteen calls, which is where it was when
  the viewport was the full width of the mode.

  Every piece is a multiple of 64 bytes, which is what lets the same three
  copy kernels serve here, including the one that moves 32 bytes at a time:
  the viewport is 512 wide, it starts 64 bytes into a row of 640, and a window
  is a whole number of kilobytes - so no offset in the arithmetic below is
  ever anything but a multiple of 64. }
procedure StagePresent(Kind: TCmpKind);
var
  B, Sg     : Word;
  Y, Left   : Word;       { rows of this band still to send }
  N, Piece  : Word;
  InBand    : Word;
  Lin, Win  : LongWord;   { byte offset into the card's picture }
  Rest      : LongWord;
  Whole     : Word;
begin
  if Cfg.Vga then
  begin
    if (Cfg.W = Cfg.ModeW) and (Cfg.H = Cfg.ModeH) then
    begin
      Whole := Word(LongInt(Cfg.W) * Cfg.H);
      CopyRun(Kind, DstSeg[0], 0, VgaSeg, 0, Whole, 1, Whole, Whole);
    end
    else
      CopyRun(Kind, DstSeg[0], 0, VgaSeg, VramBase,
              Cfg.W, Cfg.H, Cfg.W, Cfg.ModeW);
    Exit;
  end;

  Win := LongWord(BankWinKb) * 1024;
  for B := 0 to Cfg.Bands - 1 do
  begin
    Sg     := DstSeg[B];
    InBand := 0;
    Y      := B * Cfg.BandRows;
    Left   := Cfg.BandRows;
    while Left > 0 do
    begin
      Lin  := LongWord(VramBase) + LongWord(Y) * Cfg.ModeW;
      { What is left of the window this row starts in. Never narrowed to a
        Word before it has been compared: a whole window is 65536 and
        Word(65536) is zero, which would be a piece that copies nothing, a
        loop that never advances, and a machine that appears to have hung on
        its first SVGA frame. }
      Rest := Win - (Lin mod Win);
      BankGoto(BankPosOf(Lin));
      if Rest >= Cfg.W then
      begin
        { How many whole rows still end inside this window. One at least,
          since the row we are at does. }
        N := Word((Rest - Cfg.W) div LongWord(Cfg.ModeW)) + 1;
        if N > Left then N := Left;
        CopyRun(Kind, Sg, InBand, BankWinSeg, Word(Lin mod Win),
                Cfg.W, N, Cfg.W, Cfg.ModeW);
        Inc(InBand, N * Cfg.W);
        Inc(Y, N);
        Dec(Left, N);
      end
      else
      begin
        { The row the window ends inside: what fits, the window moved, and
          the rest of it at the start of the next one. }
        Piece := Word(Rest);
        CopyRun(Kind, Sg, InBand, BankWinSeg, Word(Lin mod Win),
                Piece, 1, Piece, Piece);
        BankGoto(BankPosOf(Lin + Piece));
        CopyRun(Kind, Sg, InBand + Piece, BankWinSeg,
                Word((Lin + Piece) mod Win),
                Cfg.W - Piece, 1, Cfg.W - Piece, Cfg.W - Piece);
        Inc(InBand, Cfg.W);
        Inc(Y);
        Dec(Left);
      end;
    end;
  end;
end;

{ ---------------------------------------------------------------- kernels }

{ One frame on. Two counters rather than one: the background rotates on a
  cycle of Turns frames and the placement lists repeat every CmpSlots, and
  they are different lengths because they cost different things. A frame of
  rotation is six words in a table, so there can be as many as the motion
  needs; a frame of placement is every sprite and every glyph in it, and eight
  of those already fill a good part of the list segment. }
procedure NextFrame;
begin
  Turn := (Turn + 1) and (Turns - 1);
  Slot := (Slot + 1) and (CmpSlots - 1);
end;

{ One unit is one frame's worth of the stage, for every test here. That is
  what makes the stage times add up to the frame time, and the report says so:
  a sum that misses the frame by more than a few per cent means something is
  being measured twice or not at all. }

procedure KBack(Units: Word);
var I: Word;
begin
  for I := 1 to Units do
  begin
    StageBack;
    NextFrame;
  end;
end;

procedure KSpr(Units: Word);
var I: Word;
begin
  for I := 1 to Units do
  begin
    StageSprites;
    NextFrame;
  end;
end;

procedure KLens(Units: Word);
var I: Word;
begin
  for I := 1 to Units do
  begin
    StageLens;
    NextFrame;
  end;
end;

procedure KTxt(Units: Word);
var I: Word;
begin
  for I := 1 to Units do
  begin
    StageText;
    NextFrame;
  end;
end;

procedure KPreW(Units: Word);
var I: Word;
begin
  for I := 1 to Units do StagePresent(ckPreW);
end;

procedure KPreD(Units: Word);
var I: Word;
begin
  for I := 1 to Units do StagePresent(ckPreD);
end;

procedure KPreQ(Units: Word);
var I: Word;
begin
  for I := 1 to Units do StagePresent(ckPreQ);
end;

procedure KFrame(Units: Word);
var I: Word;
begin
  for I := 1 to Units do
  begin
    StageBack;
    StageSprites;
    StageLens;
    StageText;
    StagePresent(PresentKind);
    NextFrame;
  end;
end;

procedure KDirect(Units: Word);
var I: Word;
begin
  for I := 1 to Units do
  begin
    StageBack;
    StageSprites;
    StageText;
    NextFrame;
  end;
end;

{ One whole frame, drawn and put on the card, outside any measurement.

  The stage tests draw into the back buffer and never present, which is the
  right thing to measure and the wrong thing to look at: the sprite stage run
  on its own for a quarter of a second leaves several thousand sprites smeared
  over one background, the text stage leaves a caption written a thousand times
  over that, and the present tests then put exactly that on the card and hold
  it there for their own three passes. What the machine was doing for those
  first seconds was honest work; what it looked like was a crash.

  So each test starts by drawing one frame properly and showing it. The screen
  is still still - a stage test has nothing to animate - but it is a frame of
  the game, with the caption underneath saying which test is running. }
procedure ShowFrame;
begin
  StageBack;
  StageSprites;
  StageLens;
  StageText;
  if not DstToVram then StagePresent(PresentKind);
end;

{ ------------------------------------------------------------- the table }

procedure AddTest(T: TCmpTier; const Id, Title, Metric: String;
                  Frame: Boolean; OpsPer: LongWord; K: TKernel);
begin
  if CmpTestN >= MaxCmpTests then
  begin
    TableFull := True;
    Exit;
  end;
  CmpTests[CmpTestN].Id     := Id;
  CmpTests[CmpTestN].Title  := Title;
  CmpTests[CmpTestN].Metric := Metric;
  CmpTests[CmpTestN].Tier   := T;
  CmpTests[CmpTestN].Frame  := Frame;
  CmpTests[CmpTestN].OpsPer := OpsPer;
  CmpTests[CmpTestN].Kern   := K;
  CmpTestRes[CmpTestN].Ran      := False;
  CmpTestRes[CmpTestN].Skipped  := False;
  CmpTestRes[CmpTestN].Why      := '';
  CmpTestRes[CmpTestN].Value    := 0;
  CmpTestRes[CmpTestN].UsPer    := 0;
  CmpTestRes[CmpTestN].SpreadPc := 0;
  Inc(CmpTestN);
end;

procedure BuildTable;
var
  T    : TCmpTier;
  C    : TCmpTierCfg;
  Px   : LongWord;
  Gl   : Word;
begin
  CmpTestN := 0;
  TableFull := False;
  for T := ctLow to ctHigh do
  begin
    C  := CmpTierCfg[T];
    Px := LongWord(C.W) * C.H;
    Gl := (C.W div 8) - 4;
    AddTest(T, 'bg.'  + C.Id, 'Rotozoom background',  'Mpix/s', False,
            Px, @KBack);
    AddTest(T, 'spr.' + C.Id, 'Masked sprites',       'Mpix/s', False,
            LongWord(C.Sprites) * C.SprW * C.SprW, @KSpr);
    { A tier with no lenses has no lens test either, rather than one that
      measures a stage which returns immediately: a rate over nothing is not
      a small number, it is a wrong one. The stage row prints 0% for it,
      which is what happened. }
    if C.Lenses > 0 then
      AddTest(T, 'lns.' + C.Id, 'Lenses over the frame', 'Mpix/s', False,
              LongWord(C.Lenses) * C.LensW * C.LensW, @KLens);
    { Twice the cells, because the stage draws the line twice: see
      TextBuild. }
    AddTest(T, 'txt.' + C.Id, 'Text, 8x8 glyphs',     'Mpix/s', False,
            LongWord(Gl) * TextRows * 128, @KTxt);
    AddTest(T, 'preW.'+ C.Id, 'Present, REP MOVSW',   'MB/s',   False,
            Px, @KPreW);
    AddTest(T, 'preD.'+ C.Id, 'Present, REP MOVSD',   'MB/s',   False,
            Px, @KPreD);
    AddTest(T, 'preQ.'+ C.Id, 'Present, MOVQ',        'MB/s',   False,
            Px, @KPreQ);
    AddTest(T, 'frm.' + C.Id, 'Game frame, buffered', 'FPS',    True,
            Px, @KFrame);
    { No direct path in 101h: drawing straight into a banked window means a
      window move inside every stage, which is a different benchmark rather
      than the same one without a buffer. }
    if C.Vga then
      AddTest(T, 'dir.' + C.Id, 'Game frame, into VRAM', 'FPS', True,
              Px, @KDirect);
  end;
end;

function CmpTierHasResults(T: TCmpTier): Boolean;
var I: Integer;
begin
  CmpTierHasResults := False;
  for I := 0 to CmpTestN - 1 do
    if (CmpTests[I].Tier = T) and CmpTestRes[I].Ran then
    begin
      CmpTierHasResults := True;
      Exit;
    end;
end;

function CmpFirst(T: TCmpTier): Integer;
var I: Integer;
begin
  CmpFirst := -1;
  for I := 0 to CmpTestN - 1 do
    if CmpTests[I].Tier = T then begin CmpFirst := I; Exit end;
end;

function CmpLast(T: TCmpTier): Integer;
var I: Integer;
begin
  CmpLast := -1;
  for I := 0 to CmpTestN - 1 do
    if CmpTests[I].Tier = T then CmpLast := I;
end;

{ ----------------------------------------------------------- setting up }

{ The aux segment: the font, the sprite patterns, the scratch the self-check
  builds its list entries in, the rotation table, the status line, the sprite
  state and the list built from it every frame - with every sprite counted
  twice there, because in the worst case every one of them straddles a band
  boundary and becomes two entries.

  One function, used both to ask DOS for the memory and to decide whether a
  tier can run at all. Two of them would eventually disagree, and the way that
  shows up is a machine being refused a tier it had the memory for. }
function AuxBytesOf(const C: TCmpTierCfg): LongInt;
var Gl, Lp, Mul: Word;
begin
  Gl := (C.W div 8) - 4;
  Lp := C.LensW * C.LensW;
  { A tier with no lenses pays for no blend table either - and it is the tier
    with the least memory to spare. }
  if C.Lenses > 0 then Mul := LnsMulSize + 511 else Mul := 0;
  AuxBytesOf := LongInt(FontBytes) +
                LongInt(SprPats) * C.SprW * C.SprW + ScratchLen +
                LongInt(Turns) * RotBytes +
                LongInt(Gl) * TextRows * 8 * 2 +
                BandTBytes +
                LongInt(C.Sprites) * SprStBytes +
                LongInt(C.Sprites) * 2 * 12 +
                LongInt(C.Lenses) * LnsStBytes +
                LongInt(Lp) * 10 +
                LongInt(C.Lenses) * 12 + Mul;
end;

function KbNeeded(T: TCmpTier): LongInt;
var C: TCmpTierCfg; N: LongInt;
begin
  C := CmpTierCfg[T];
  N := LongInt(C.TexPix) * TexStride;
  N := N + LongInt(C.W) * C.H;
  N := N + AuxBytesOf(C);
  KbNeeded := (N div 1024) + 1;
end;

{ The reason carries both numbers, because one of them alone is not an answer.
  A tier that says only what it needs leaves the person in front of it working
  out what they have from somewhere else - and the number they have is the one
  they can do something about, by unloading a driver or by booting without the
  disk cache. Both fit inside the twenty-eight columns the menu greys out. }
function CmpTierWhy(T: TCmpTier): String;
var S, H: String; Kb: LongInt;
begin
  CmpTierWhy := '';
  Kb := FarMaxAvail div 1024;
  if Kb < KbNeeded(T) then
  begin
    Str(KbNeeded(T), S);
    Str(Kb, H);
    CmpTierWhy := 'needs ' + S + 'K, has ' + H + 'K';
    Exit;
  end;
  if not CmpTierCfg[T].Vga then
  begin
    if not VbeOk then CmpTierWhy := 'no VBE BIOS'
    else if SafeProbe then CmpTierWhy := '/safe skipped the VBE probe';
  end;
end;

function CmpWhy: String;
begin
  CmpWhy := InitWhy;
end;

function CmpInit(T: TCmpTier): Boolean;
var
  C      : TCmpTierCfg;
  AuxEnd : LongInt;
  I      : Integer;
begin
  CmpInit := False;
  InitWhy := '';
  { Both of these say why something could not be measured in *this* tier, and
    a tier that never asks the question leaves the last tier's answer standing
    unless it is cleared here. }
  CmpTimerWhy := '';
  CmpPresentWhy := '';
  CmpDone;
  CmpTier := T;
  C := CmpTierCfg[T];
  Tex256   := C.TexPix = 256;
  SprBytes := C.SprW * C.SprW;
  GlyphsPerRow := (C.W div 8) - 4;
  BandBytes := LongInt(C.BandRows) * C.W;

  { The one arrangement the placement builder takes on trust. }
  if C.H - 24 < (C.Bands - 1) * C.BandRows then
  begin
    InitWhy := 'text rows would cross a band';
    Exit;
  end;

  { The aux segment, laid out: the font, the sprite patterns, the scratch the
    self-check builds a list entry in, the rotation, the status line, the
    bands of the destination, the sprite state and the list the placement
    kernel fills from it. All of it in one segment, because the kernels walk
    the lists with DS pointed at it and reach the pixels through the same DS
    with a Word offset. }
  OfsFont    := 0;
  OfsPats    := FontBytes;
  OfsScratch := OfsPats + SprPats * SprBytes;
  OfsRot     := OfsScratch + ScratchLen;
  OfsText    := OfsRot + Turns * RotBytes;
  OfsBands   := OfsText + GlyphsPerRow * TextRows * 8 * 2;
  OfsSprSt    := OfsBands + BandTBytes;
  OfsLists    := OfsSprSt + C.Sprites * SprStBytes;
  OfsLensSt   := OfsLists + C.Sprites * 2 * 12;
  OfsLensLut  := OfsLensSt + C.Lenses * LnsStBytes;
  OfsLensRing := OfsLensLut + LongInt(C.LensW) * C.LensW * 8;
  OfsLensScr  := OfsLensRing + C.LensW * C.LensW;
  OfsLensList := OfsLensScr + C.LensW * C.LensW;
  { Last, and rounded up: a page of the blend table is 512 bytes and the LUT
    holds the address of its middle, so the pages have to start on whole
    multiples of 512. The slack that rounding costs is counted into
    AuxBytesOf, which is what asks DOS for the memory. }
  OfsLensMul  := (OfsLensList + C.Lenses * 12 + 511) and $FE00;
  AuxEnd     := AuxBytesOf(C);
  if AuxEnd > 65536 then
  begin
    InitWhy := 'placement lists exceed one segment';
    Exit;
  end;

  if not FarAlloc(LongInt(C.TexPix) * TexStride, Tex) then
  begin
    InitWhy := 'no room for the texture';
    Exit;
  end;
  if not FarAlloc(LongInt(C.Bands) * BandBytes, Back) then
  begin
    InitWhy := 'no room for the back buffer';
    CmpDone;
    Exit;
  end;
  if not FarAlloc(AuxEnd, Aux) then
  begin
    InitWhy := 'no room for sprites and lists';
    CmpDone;
    Exit;
  end;
  TexSeg := Tex.Base;
  AuxSeg := Aux.Base;

  Dbg('cmp: content');
  BuildSin;
  BuildTurns;
  BuildTexture;
  BuildSprites;
  BuildLens;
  CopyFont(AuxSeg, OfsFont);
  FarFill(Back, 0);

  Slot     := 0;
  Turn     := 0;
  PlaceFor := -1;
  PresentKind := ckPreW;
  CmpStatus(CanonTop, CanonBot);
  NeedPlacement(False);

  { A tier can be run twice - the menu makes that one keystroke - so its rows
    start empty rather than carrying the previous attempt's numbers under this
    attempt's heading. }
  for I := 0 to CmpTestN - 1 do
    if CmpTests[I].Tier = T then
    begin
      CmpTestRes[I].Ran := False;
      CmpTestRes[I].Skipped := False;
      CmpTestRes[I].Why := '';
      CmpTestRes[I].Value := 0;
      CmpTestRes[I].UsPer := 0;
      CmpTestRes[I].SpreadPc := 0;
    end;
  CmpCrcOk[T] := False;
  CmpCrc[T] := 0;

  { From here the tier is on the record whether or not anything measures: a
    tier that ran and came back empty has a reason on every row, and hiding it
    would leave the reader with nothing to read the silence from. }
  CmpTierRan[T] := True;
  CmpAnyRan := True;
  CmpReady := True;
  CmpInit  := True;
end;

procedure CmpDone;
begin
  CmpLeaveMode;
  if Aux.Base <> 0 then FarFree(Aux);
  if Back.Base <> 0 then FarFree(Back);
  if Tex.Base <> 0 then FarFree(Tex);
  CmpReady := False;
end;

{ ---------------------------------------------------------------- the mode }

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

function CmpEnterMode: Boolean;
begin
  CmpEnterMode := False;
  if ModeOn then begin CmpEnterMode := True; Exit end;
  OldMode := CurrentMode;
  if Cfg.Vga then
  begin
    SetMode($13);
    { The video BIOS has just had the machine, and may have handed it back
      with interrupts disabled - which stops the clock and turns every
      measurement below into "too fast to time". }
    TimerReassert;
    PalApply;
    ModeOn := True;
    CmpEnterMode := True;
  end
  else
  begin
    if not BankOpen then
    begin
      InitWhy := BankOpenWhy;
      Exit;
    end;
    PalApply;
    ModeOn := True;
    { Asked once, here, and not by the harness the hard way. A window call the
      clock cannot see makes every present look instantaneous, and the harness
      answers that by doubling its workload until it is presenting 32768
      frames in one call - which is not a wrong number, it is no number at all
      and an afternoon spent not getting it. The stages that never touch the
      window are timed either way; present and frame say why they are not. }
    Dbg('cmp: bank timer witness');
    TimerOk := BankTimerOk(CmpTimerWhy);
    { The witness itself has just made thousands of BIOS calls, and the last
      of them is under no more obligation than the first to give the interrupt
      flag back. }
    TimerReassert;
    CmpEnterMode := True;
  end;
end;

procedure CmpLeaveMode;
begin
  if not ModeOn then Exit;
  ModeOn := False;
  if Cfg.Vga then
  begin
    SetMode(OldMode and $7F);
    TimerReassert;
  end
  else BankClose;
end;

{ ------------------------------------------------------------- self-check }

{ The reference. Sixty-four pixels by eight, the same arithmetic written the
  slow and readable way, and then a comparison byte for byte. What it catches
  is the class of mistake that the CRC cannot: both machines running the same
  wrong kernel and agreeing perfectly. }

{ Sixty-four by eight, which is what CheckBack compares - and no larger,
  because every byte of it is DGROUP and DGROUP is the one segment this
  program can run out of. }
var
  Ref : array[0..511] of Byte;

function CheckBack: String;
var
  X, Y   : Word;
  U, V   : Word;
  Uu, Vv : Word;
  Idx    : Word;
  Got, Want : Byte;
  S      : String;
begin
  CheckBack := '';
  KTexSeg := TexSeg;
  KDu := MemW[AuxSeg:OfsRot + 4];  KDv := MemW[AuxSeg:OfsRot + 6];
  KRdu := MemW[AuxSeg:OfsRot + 8]; KRdv := MemW[AuxSeg:OfsRot + 10];
  KChunks := 8;
  KRowAdd := DstStride - 64;
  KDstSeg := DstSeg[0];
  KDstOfs := DstBase[0];
  KRows   := 8;
  { Kept before the call, not read back after it: the kernel leaves KU and KV
    advanced past its last row, which is the whole point of them. }
  U := MemW[AuxSeg:OfsRot]; V := MemW[AuxSeg:OfsRot + 2];
  KU := U; KV := V;
  if Tex256 then BgBand256 else BgBand128;
  for Y := 0 to 7 do
  begin
    Uu := U; Vv := V;
    for X := 0 to 63 do
    begin
      Idx := (Vv and $FF00) or (Uu shr 8);
      if not Tex256 then Idx := Idx and $7F7F;
      Ref[Y * 64 + X] := Mem[TexSeg:Idx];
      Uu := Uu + KDu;
      Vv := Vv + KDv;
    end;
    U := U + KRdu;
    V := V + KRdv;
  end;

  for Y := 0 to 7 do
    for X := 0 to 63 do
    begin
      Got  := Mem[DstSeg[0]:DstBase[0] + Y * DstStride + X];
      Want := Ref[Y * 64 + X];
      if Got <> Want then
      begin
        Str(Y * 64 + X, S);
        CheckBack := 'background differs at pixel ' + S;
        Exit;
      end;
    end;
end;

function CheckSpr: String;
var
  X, Y  : Word;
  W, At : Word;
  Src   : Word;
  Got, Want : Byte;
  S     : String;
begin
  CheckSpr := '';
  W  := Cfg.SprW;
  At := DstBase[0] + 4 * DstStride + 8;
  { A ground the sprite is drawn over, so transparency has something to leave
    alone: a check on a cleared buffer would pass for a kernel that wrote the
    mask colour as well. }
  for Y := 0 to W - 1 do
    for X := 0 to W - 1 do
      Mem[DstSeg[0]:At + Y * DstStride + X] := $37;

  PutEnt(OfsScratch, DstSeg[0], At, OfsPats, W, W div 4, DstStride - W);
  KSprSeg := AuxSeg;
  KSprPtr := OfsScratch;
  KSprN   := 1;
  SprList;

  for Y := 0 to W - 1 do
    for X := 0 to W - 1 do
    begin
      Src  := Mem[AuxSeg:OfsPats + Y * W + X];
      if Src = 0 then Want := $37 else Want := Src;
      Got := Mem[DstSeg[0]:At + Y * DstStride + X];
      if Got <> Want then
      begin
        Str(Y * W + X, S);
        CheckSpr := 'sprite differs at pixel ' + S;
        Exit;
      end;
    end;
end;

function CheckTxt: String;
var
  R, B  : Word;
  At    : Word;
  Fb    : Byte;
  Got, Want : Byte;
  S     : String;
begin
  CheckTxt := '';
  At := DstBase[0] + 32 * DstStride + 8;
  for R := 0 to 7 do
    for B := 0 to 7 do
      Mem[DstSeg[0]:At + R * DstStride + B] := $21;

  MemW[AuxSeg:OfsScratch]     := DstSeg[0];
  MemW[AuxSeg:OfsScratch + 2] := At;
  MemW[AuxSeg:OfsScratch + 4] := OfsFont + (Ord('A') - FontFirst) * 8;
  MemW[AuxSeg:OfsScratch + 6] := DstStride - 8;
  KSprSeg := AuxSeg;
  KTxtPtr := OfsScratch;
  KTxtN   := 1;
  KTxtCol := TxtCol;
  TxtList;

  for R := 0 to 7 do
  begin
    Fb := Mem[AuxSeg:OfsFont + (Ord('A') - FontFirst) * 8 + R];
    for B := 0 to 7 do
    begin
      if (Fb and (1 shl (7 - B))) <> 0 then Want := TxtCol else Want := $21;
      Got := Mem[DstSeg[0]:At + R * DstStride + B];
      if Got <> Want then
      begin
        Str(R * 8 + B, S);
        CheckTxt := 'glyph differs at pixel ' + S;
        Exit;
      end;
    end;
  end;
end;

{ The placement kernel, against the same arithmetic in Pascal.

  It checks the split across bands as well, and to do that it makes up a
  destination: four bands of eight rows, with a band table of its own. The
  real split only ever happens on the high tier, which needs a VBE BIOS and a
  quarter of a megabyte - so on any machine that cannot run that tier the
  code would otherwise go untested until the day somebody has one. The state
  and the band table are put back afterwards by rebuilding the placement.

  Three sprites, placed by hand where the interesting cases are: one inside a
  band, one straddling a boundary, one in the last band with nothing below
  it. }
{ The lens gather, against the table it walks.

  Fetch what the table says, blend it the way the kernel blends it, and
  compare - which is not the tautology it looks like, because the kernel does
  all of that in twenty instructions with three registers and a segment
  override on every read. That is where this kind of loop goes wrong: a lens
  reading one segment too far does not crash, it draws something plausible.

  The ground is one row and one column bigger than the lens, because bilinear
  reads one past the last sample it uses. Their weight is zero and the value
  cannot reach the answer, but a check that left them undefined would be
  checking one thing and proving another. }
function CheckLens: String;
var
  X, Y, I, N  : Word;
  E, Mx, My   : Word;
  Pa, Pb      : Word;
  A, B, C, D  : Integer;
  T, U        : Integer;
  Got, Want   : Byte;
  S           : String;
begin
  CheckLens := '';
  if Cfg.Lenses = 0 then Exit;
  N := Cfg.LensW * Cfg.LensW;

  { A ground that differs in both directions, so a lens that swapped them
    would be caught, and by more than one step a pixel, so a fraction dropped
    on the floor would show up as well. }
  for Y := 0 to Cfg.LensW do
    for X := 0 to Cfg.LensW do
      Mem[DstSeg[0]:DstBase[0] + Y * DstStride + X] :=
        Byte((X * 7 + Y * 13) and $FF);

  KSprSeg := AuxSeg;
  KLnSeg  := DstSeg[0];
  KLnOfs  := DstBase[0];
  LensGather;

  for I := 0 to N - 1 do
  begin
    E  := OfsLensLut + I * 8;
    Pa := DstBase[0] + MemW[AuxSeg:E];
    Pb := DstBase[0] + MemW[AuxSeg:E + 2];
    Mx := MemW[AuxSeg:E + 4];
    My := MemW[AuxSeg:E + 6];
    A  := Mem[DstSeg[0]:Pa];
    B  := Mem[DstSeg[0]:Pa + 1];
    C  := Mem[DstSeg[0]:Pb];
    D  := Mem[DstSeg[0]:Pb + 1];
    { The difference signed and whole - which is what the kernel's SBB
      reconstructs - and the sum taken as a byte, where its ADD wraps. }
    T := (A + ShortInt(Mem[AuxSeg:Word(LongInt(Mx) + (B - A))])) and $FF;
    U := (C + ShortInt(Mem[AuxSeg:Word(LongInt(Mx) + (D - C))])) and $FF;
    Want := Byte((T + ShortInt(Mem[AuxSeg:Word(LongInt(My) + (U - T))]))
                 and $FF);
    Got  := Mem[AuxSeg:OfsLensScr + I];
    if Got <> Want then
    begin
      Str(I, S);
      CheckLens := 'lens differs at pixel ' + S;
      Exit;
    end;
  end;
end;

function CheckPlace: String;
const
  NSpr  = 3;
  Rows_ = 8;
  Bands = 4;
  Strd  = 64;
var
  I, At, E   : Word;
  Xs, Ys     : array[0..NSpr - 1] of Word;
  Dx, Dy     : array[0..NSpr - 1] of Integer;
  Xi, Yi     : Word;
  Bd, Rw, R1 : Word;
  Want, Got  : Word;
  Ent        : Word;
  S          : String;

  function Bad(const What: String; N: Word): String;
  var T, U: String;
  begin
    Str(N, T); Str(Ent, U);
    Bad := 'placement ' + What + ' wrong in entry ' + U + ': ' + T;
  end;

begin
  CheckPlace := '';

  { A band table for the imaginary destination. }
  At := OfsScratch;
  for I := 0 to Bands - 1 do
  begin
    MemW[AuxSeg:At]     := $2000 + I;      { a segment number, never read }
    MemW[AuxSeg:At + 2] := I * 4;          { and a base with a value in it }
    Inc(At, 4);
  end;

  { One sprite inside a band, one across a boundary, one at the very bottom. }
  Xs[0] := 3 * 16; Ys[0] := 1 * 16;  Dx[0] := 16;  Dy[0] := 0;
  Xs[1] := 5 * 16; Ys[1] := 13 * 16; Dx[1] := 0;   Dy[1] := 16;
  Xs[2] := 0;      Ys[2] := 24 * 16; Dx[2] := -16; Dy[2] := 0;
  At := OfsSprSt;
  for I := 0 to NSpr - 1 do
  begin
    MemW[AuxSeg:At]     := Xs[I];
    MemW[AuxSeg:At + 2] := Ys[I];
    MemW[AuxSeg:At + 4] := Word(Dx[I]);
    MemW[AuxSeg:At + 6] := Word(Dy[I]);
    MemW[AuxSeg:At + 8] := OfsPats + I * SprBytes;
    Inc(At, 10);
  end;

  KSprSeg   := AuxSeg;
  KSpSt     := OfsSprSt;
  KSpN      := NSpr;
  KSpList   := OfsLists;
  KSpW      := 8;
  KSpChunks := 2;
  KSpRowAdd := Strd - 8;
  KSpXMax   := Word(Strd - 8) * 16;
  KSpYMax   := Word(Bands * Rows_ - 8) * 16;
  KSpRows   := Rows_;
  KSpStride := Strd;
  KSpBands  := Bands;
  KSpBandT  := OfsScratch;
  SprPlace;

  Ent := 0;
  E   := OfsLists;
  for I := 0 to NSpr - 1 do
  begin
    { the same step the kernel takes, including the bounce }
    Xi := Xs[I] + Word(Dx[I]);
    if Xi > KSpXMax then Xi := Xs[I] - Word(Dx[I]);
    Yi := Ys[I] + Word(Dy[I]);
    if Yi > KSpYMax then Yi := Ys[I] - Word(Dy[I]);
    Xi := Xi shr 4;
    Yi := Yi shr 4;
    Bd := Yi div Rows_;
    Rw := Yi mod Rows_;
    R1 := Rows_ - Rw;
    if R1 > 8 then R1 := 8;

    Got  := MemW[AuxSeg:E + 2];
    Want := Bd * 4 + Rw * Strd + Xi;
    if Got <> Want then begin CheckPlace := Bad('offset', Got); Exit end;
    Got  := MemW[AuxSeg:E + 6];
    if Got <> R1 then begin CheckPlace := Bad('row count', Got); Exit end;
    Got  := MemW[AuxSeg:E + 4];
    if Got <> OfsPats + I * SprBytes then
    begin CheckPlace := Bad('pattern', Got); Exit end;
    Inc(E, 12); Inc(Ent);

    if (R1 < 8) and (Bd + 1 < Bands) then
    begin
      Got  := MemW[AuxSeg:E + 2];
      Want := (Bd + 1) * 4 + Xi;
      if Got <> Want then begin CheckPlace := Bad('offset', Got); Exit end;
      Got  := MemW[AuxSeg:E + 6];
      if Got <> 8 - R1 then
      begin CheckPlace := Bad('row count', Got); Exit end;
      Got  := MemW[AuxSeg:E + 4];
      if Got <> OfsPats + I * SprBytes + R1 * 8 then
      begin CheckPlace := Bad('pattern', Got); Exit end;
      Inc(E, 12); Inc(Ent);
    end;
  end;

  if KSpOut <> Ent then
  begin
    Str(KSpOut, S);
    CheckPlace := 'placement wrote ' + S + ' entries, not what it should';
  end;

  { Whatever the check left behind, undone. }
  SetDest(DstToVram);
  BuildPlacement;
end;

function CmpSelfCheck: String;
var S: String;
begin
  CmpSelfCheck := '';
  { Before anything is drawn, because it is not about the drawing: a table
    that could not hold every test loses the ones at the end of it, and the
    end of it is where the frame tests are. That is a suite quietly measuring
    less than it says it does, which is worse than one that fails. }
  if TableFull then
  begin
    CmpSelfCheck := 'test table too small for the suite';
    Exit;
  end;
  if not CmpReady then
  begin
    CmpSelfCheck := 'composite setup failed';
    Exit;
  end;
  NeedPlacement(False);
  S := CheckBack;  if S <> '' then begin CmpSelfCheck := S; Exit end;
  S := CheckSpr;   if S <> '' then begin CmpSelfCheck := S; Exit end;
  S := CheckTxt;   if S <> '' then begin CmpSelfCheck := S; Exit end;
  S := CheckLens;  if S <> '' then begin CmpSelfCheck := S; Exit end;
  S := CheckPlace; if S <> '' then begin CmpSelfCheck := S; Exit end;
  { Whatever the checks drew is still in the buffer; the witness below starts
    from a known state, so leave one. }
  FarFill(Back, 0);
  Slot := 0; Turn := 0;
  ResetObjects;
end;

{ One frame, presented and read back. Rows, not bands - see the header note
  on the interface side. }
function CmpPresentCheck: String;
var
  Y, X, N, I     : Word;
  SrcSeg, SrcOfs : Word;
  WinOfs         : Word;
  Lin, Win, Rest : LongWord;
  DstSg, DstOf   : Word;
  S              : String;
begin
  CmpPresentCheck := '';
  CmpPresentWhy := '';
  if (not CmpReady) or (not ModeOn) then
  begin
    CmpPresentCheck := 'no video mode to present into';
    Exit;
  end;
  if (not Cfg.Vga) and (not BankWinReadable) then
  begin
    CmpPresentWhy := 'window is write-only; present unchecked';
    Exit;
  end;

  { The whole frame and not three quarters of it: the lenses cost the check
    nothing to draw, they are the one stage that reads the buffer back before
    it is sent, and this is the only place at the high tier that puts a
    complete frame on the card without needing the clock to follow the card's
    window - which is to say it is the only place it can be looked at. }
  NeedPlacement(False);
  Slot := 0;
  StageBack;
  StageSprites;
  StageLens;
  StageText;
  StagePresent(ckPreW);

  Win := LongWord(BankWinKb) * 1024;
  for Y := 0 to Cfg.H - 1 do
  begin
    SrcSeg := DstSeg[Y div Cfg.BandRows];
    SrcOfs := (Y mod Cfg.BandRows) * Cfg.W;
    X := 0;
    while X < Cfg.W do
    begin
      { Where this pixel of the viewport landed in the card's picture: the
        same arithmetic the present does, written the other way round - by
        rows where the present goes by rectangles, so a mistake would have to
        be made twice, in two shapes, to pass. }
      if Cfg.Vga then
      begin
        N     := Cfg.W - X;
        DstSg := VgaSeg;
        DstOf := VramBase + Y * Cfg.ModeW + X;
      end
      else
      begin
        Lin  := LongWord(VramBase) + LongWord(Y) * Cfg.ModeW + X;
        Rest := Win - (Lin mod Win);
        if Rest > LongWord(Cfg.W - X) then N := Cfg.W - X else N := Word(Rest);
        BankGoto(BankPosOf(Lin));
        DstSg := BankWinSeg;
        DstOf := Word(Lin mod Win);
      end;
      for I := 0 to N - 1 do
        if Mem[SrcSeg:SrcOfs + X + I] <> Mem[DstSg:DstOf + I] then
        begin
          Str(LongInt(Y) * Cfg.W + X + I, S);
          CmpPresentCheck := 'presented frame differs at byte ' + S;
          Exit;
        end;
      X := X + N;
    end;
  end;
end;

function CmpFrameCrc: LongInt;
var I: Word;
begin
  CmpFrameCrc := 0;
  if not CmpReady then Exit;
  NeedPlacement(False);
  CmpStatus(CanonTop, CanonBot);
  FarFill(Back, 0);
  Slot := 0; Turn := 0;
  ResetObjects;
  for I := 1 to 2 do
  begin
    StageBack;
    StageSprites;
    StageLens;
    StageText;
    NextFrame;
  end;
  Slot := 0; Turn := 0;
  CmpFrameCrc := FarCrc32(Back);
end;

{ ----------------------------------------------------------------- running }

{ Frames per second, in the millionths the whole suite states its metrics in.
  Taken from the duration and the frame count rather than from the harness's
  integer rate, which rounds to nothing at all on a machine drawing less than
  one frame a second - and a 286 at 320x200 is exactly that machine. }
function FpsMil(Units: LongWord; Us: LongWord): LongWord;
var U: LongWord;
begin
  FpsMil := 0;
  if (Units = 0) or (Us = 0) then Exit;
  U := Us div Units;                    { microseconds per frame }
  if U < 250 then U := 250;             { 4000 FPS, far past anything real }
  FpsMil := (1000000000 div U) * 1000;
end;

{ Operations per second, from a count of units and the ticks they took. The
  multiply is in Int64 because the count and the operations per unit are each
  modest and their product need not be: a machine presenting 4 GB a second
  would overflow a LongWord halfway through the arithmetic and report a
  respectable fraction of its real speed. }
function OpsMil(Units, PerUnit: LongWord; Ticks: TStamp): LongWord;
begin
  if Ticks = 0 then OpsMil := 0
  else OpsMil := LongWord((Int64(Units) * Int64(PerUnit) * PitInHz) div
                          Int64(Ticks));
end;

function Supported(I: Integer; var Why: String): Boolean;
begin
  Supported := True;
  Why := '';
  if CmpTests[I].Tier <> CmpTier then
  begin
    Supported := False;
    Why := 'tier not loaded';
    Exit;
  end;
  if Pos('preD', CmpTests[I].Id) = 1 then
    if CpuClass < cc80386 then
    begin
      Supported := False;
      Why := 'needs 386 or up';
    end;
  if Pos('preQ', CmpTests[I].Id) = 1 then
    if not HasMmx then
    begin
      Supported := False;
      Why := 'no MMX';
    end;
  { Everything that moves the window, on a card whose window call the clock
    cannot follow. }
  if (not Cfg.Vga) and (not TimerOk) then
    if (Pos('pre', CmpTests[I].Id) = 1) or (Pos('frm', CmpTests[I].Id) = 1) then
    begin
      Supported := False;
      Why := CmpTimerWhy;
      if Why = '' then Why := 'window call is untimeable';
    end;
end;

{ The present form the frame will use: whichever of the three measured
  fastest, which is a question about the machine and not about its badge - a
  486 whose card posts writes can lose to its own 16-bit path. }
procedure PickPresent;
var I, B: Integer; Best: LongWord;
begin
  PresentKind := ckPreW;
  Best := 0; B := -1;
  for I := CmpFirst(CmpTier) to CmpLast(CmpTier) do
    if CmpTestRes[I].Ran and (CmpTestRes[I].Value > Best) then
      if (Pos('pre', CmpTests[I].Id) = 1) then
      begin
        Best := CmpTestRes[I].Value;
        B := I;
      end;
  if B < 0 then Exit;
  if Pos('preD', CmpTests[B].Id) = 1 then PresentKind := ckPreD
  else if Pos('preQ', CmpTests[B].Id) = 1 then PresentKind := ckPreQ;
end;

procedure CmpMarkTier(T: TCmpTier; const Why: String);
var I: Integer;
begin
  for I := 0 to CmpTestN - 1 do
    if (CmpTests[I].Tier = T) and (not CmpTestRes[I].Ran) then
    begin
      CmpTestRes[I].Skipped := True;
      CmpTestRes[I].Why := Why;
    end;
end;

procedure CmpRunTest(I: Integer);
var
  R      : TBenchResult;
  Why    : String;
  N1, N2 : String[6];
begin
  if (I < 0) or (I >= CmpTestN) or (not CmpReady) then Exit;

  CmpTestRes[I].Ran := False;
  CmpTestRes[I].Skipped := False;
  CmpTestRes[I].Value := 0;
  CmpTestRes[I].UsPer := 0;

  if not Supported(I, Why) then
  begin
    CmpTestRes[I].Skipped := True;
    CmpTestRes[I].Why := Why;
    Exit;
  end;

  { The destination the test draws into, and the placement lists that go with
    it. Never inside the measurement: see BuildPlacement. }
  NeedPlacement(Pos('dir.', CmpTests[I].Id) = 1);
  if Pos('frm.', CmpTests[I].Id) = 1 then PickPresent;

  { What the frame says while this test runs. Only the two whole-frame tests
    draw text themselves, but the present tests put the last drawn frame on
    the card, so the caption is right there too. }
  Str(I - CmpFirst(CmpTier) + 1, N1);
  Str(CmpLast(CmpTier) - CmpFirst(CmpTier) + 1, N2);
  CmpStatus('ATBENCH - FRAME ' + Cfg.Id,
            N1 + '/' + N2 + ' ' + CmpTests[I].Title);

  { Every test starts from the same frame, so two runs of the same test on the
    same machine draw the same pictures. The sprites are state rather than a
    table now, so starting over means putting them back. }
  Slot := 0; Turn := 0;
  ResetObjects;

  { A frame of the game on the card before the measurement starts, and the
    state put back after it: see ShowFrame for what the screen shows without
    it. Drawn from the frame the test is about to start from, so what is on
    the screen during a stage test is the first frame of that test. }
  ShowFrame;
  Slot := 0; Turn := 0;
  ResetObjects;

  { The frame tests get a pass long enough to watch - see FrameMs. The
    stages do not: they draw into the back buffer, where there is nothing to
    watch, and three quarters of a second each is what keeps a tier of eight
    tests from becoming a coffee break. }
  if CmpTests[I].Frame then
    R := RunBenchFor(CmpTests[I].Kern, FrameMs)
  else
    R := RunBench(CmpTests[I].Kern);
  if not R.Ok then
  begin
    CmpTestRes[I].Skipped := True;
    if R.Aborted then CmpTestRes[I].Why := 'cancelled'
    else if R.TooFast then CmpTestRes[I].Why := 'too fast to time'
    else if R.Overrun then CmpTestRes[I].Why := 'took too long'
    else CmpTestRes[I].Why := 'no result';
    Exit;
  end;

  { The mean over every pass, and not the fastest of them - which is the one
    place in the suite that reads the harness this way round. Everywhere else
    a pass is the same work each time and the differences between passes are
    interference, so the fastest pass is the cleanest measurement of a fixed
    quantity of work. Here every pass is a different stretch of the animation:
    the background walks the texture along the angle it is drawn at, which is
    one cache line for many pixels at some angles and one per pixel at others,
    and the frame time follows. The fastest pass is then the easiest few
    seconds of the cycle, which is not a frame rate anybody will ever see.

    So the whole of it counts - all the frames drawn, over all the time they
    took - and what comes out is the mean weighted by time. That is the number
    a game on this machine would live at, and the spread beside it says how
    far the cycle swings either way. }
  CmpTestRes[I].Ran := True;
  CmpTestRes[I].SpreadPc := R.SpreadPc;
  CmpTestRes[I].UsPer := R.AllUs div R.AllUnits;
  if CmpTests[I].Frame then
    CmpTestRes[I].Value := FpsMil(R.AllUnits, R.AllUs)
  else
    CmpTestRes[I].Value := OpsMil(R.AllUnits, CmpTests[I].OpsPer, R.AllTicks);

end;

procedure CmpBestFrame(T: TCmpTier; var Ran: Boolean; var Fps: LongWord;
                       var UsFrame: LongWord; var Path: String);
var I: Integer;
begin
  Ran := False; Fps := 0; UsFrame := 0; Path := '';
  for I := 0 to CmpTestN - 1 do
    if (CmpTests[I].Tier = T) and CmpTests[I].Frame and CmpTestRes[I].Ran then
      if CmpTestRes[I].Value > Fps then
      begin
        Ran := True;
        Fps := CmpTestRes[I].Value;
        UsFrame := CmpTestRes[I].UsPer;
        if Pos('dir.', CmpTests[I].Id) = 1 then Path := 'into VRAM'
        else Path := 'buffered';
      end;
end;

var T: TCmpTier;

begin
  CmpTestN := 0;
  CmpReady := False;
  CmpAnyRan := False;
  ModeOn := False;
  TimerOk := True;
  PlaceFor := -1;
  InitWhy := '';
  CmpPresentWhy := '';
  CmpTimerWhy := '';
  Tex.Base := 0; Back.Base := 0; Aux.Base := 0;
  for T := ctLow to ctHigh do
  begin
    CmpTierRan[T] := False;
    CmpCrc[T] := 0;
    CmpCrcOk[T] := False;
  end;
  BuildTable;
end.
