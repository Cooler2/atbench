@echo off
rem ---------------------------------------------------------------
rem ATBench build script (host: Win32, target: i8086 MS-DOS)
rem   usage:  build <unitname-without-extension>  [extra fpc opts]
rem   output: bin\<name>.exe
rem
rem Memory model: LARGE.  This is not a preference, it is a
rem requirement.  In the medium model everything - globals, string
rem constants, typed constants, the RTL's own tables and the stack -
rem shares one 64K DGROUP, and the suite had grown to within fifty
rem bytes of it.  The failure mode there is not a compiler error:
rem when DGROUP lands on exactly 64K the stack top wraps to offset
rem zero and the linker produces an executable that dies on its
rem first push.  Large gives data its own far segments and the stack
rem a segment of its own, so adding a paragraph of text to a report
rem can no longer kill the program.
rem
rem The one thing that changes with it is where big buffers come
rem from.  The far-data start-up code deliberately keeps the whole
rem DOS block and gives everything above the stack to the RTL heap,
rem so in this model the heap - not INT 21h AH=48h - is what a
rem benchmark buffer is allocated from.  atmemx does that and says
rem why.
rem ---------------------------------------------------------------
setlocal

rem ---------------------------------------------------------------
rem Finding the cross compiler.  Two layouts exist in the wild and
rem neither stays on one drive letter, so both are looked for on
rem every root we know about rather than hard-coded to one path:
rem
rem   A  <root>\bin\i386-win32\ppcross8086.exe
rem      <root>\units\i8086-msdos-large\rtl
rem   B  <root>\bin\i386-win32\ppcross8086.exe
rem      <root>\units\msdos\80286-large\rtl        (OSDev toolchain)
rem
rem A stock FPC 3.2.2 installs the medium RTL and not the large one,
rem so the large directory usually has to be built once by hand -
rem see the message below for how.
rem
rem Set ATFPC to a root of either shape to override the search, and
rem note that a ppcross8086.exe already on PATH is picked up last -
rem its unit directories have to match one of the two layouts too,
rem because the compiler alone is no use without an RTL built for
rem the same memory model.
rem ---------------------------------------------------------------

set PPC=
set UNITPATHS=

if defined ATFPC call :layoutA "%ATFPC%"
if defined ATFPC call :layoutB "%ATFPC%"

for %%R in ("I:\FPC\fpc" "G:\FPC\fpc" "C:\FPC\fpc") do call :layoutA %%R
for %%R in ("I:\OSDev\.toolchain\fpc\3.2.2" "G:\OSDev\.toolchain\fpc\3.2.2") do call :layoutB %%R

rem Last resort: whatever is on PATH, with its own root derived from
rem where the executable sits (bin\i386-win32\ -> two levels up).
if not defined PPC for %%P in (ppcross8086.exe) do if not "%%~$PATH:P"=="" call :fromPath "%%~$PATH:P"

if not defined PPC (
  echo build: ppcross8086.exe with an i8086-msdos LARGE RTL not found.
  echo build: looked for both layouts under I:\FPC\fpc, G:\FPC\fpc,
  echo build: C:\FPC\fpc, I:\OSDev\.toolchain\fpc\3.2.2 and on PATH.
  echo build: set ATFPC to the FPC root to point the build at one.
  echo build:
  echo build: FPC ships the medium RTL only.  To build the large one
  echo build: once, from the FPC source tree:
  echo build:
  echo build:   make clean all OS_TARGET=msdos CPU_TARGET=i8086 SUB_TARGET=large OPT="-WmLarge -Cp80286"
  echo build:
  echo build: then copy the resulting rtl\units\i8086-msdos\*.ppu and
  echo build: *.a into ^<root^>\units\i8086-msdos-large\rtl.
  exit /b 1
)

if "%~1"=="" (
  echo usage: build ^<name^> [extra fpc options]
  exit /b 1
)

if not exist bin  mkdir bin
if not exist work mkdir work

set NAME=%~1
shift

set SRC=src\%NAME%.pas
if not exist "%SRC%" set SRC=spike\%NAME%.pas
if not exist "%SRC%" (
  echo build: cannot find %NAME%.pas in src\ or spike\
  exit /b 1
)

echo using: %PPC%

rem -n            ignore fpc.cfg  (it points at a stale H:\ install)
rem -Tmsdos       16-bit real mode DOS
rem -WmLarge      large memory model: far code, far data, own stack segment
rem -Cp80286      never emit anything newer than a 286
rem               (no -Cf: i8086 defaults to software floating point, so the
rem                FPU is never touched implicitly - verified, see spike\fpuchk)
rem -Sg           allow goto/label (used by a few asm-adjacent constructs)
rem -XX -CX       smart linking (the RTL exceeds 64K without it)
rem -Xm           write bin\<name>.map; the segment table there is the only
rem               place the near-data and stack sizes can be read off
"%PPC%" -n -Tmsdos -WmLarge -Cp80286 -Sg -XX -CX -O2 -Xm ^
  %UNITPATHS% ^
  -Fusrc -Fisrc -FUwork -FEbin ^
  %1 %2 %3 %4 %5 %6 %7 %8 %9 "%SRC%"

if errorlevel 1 (
  echo.
  echo BUILD FAILED
  exit /b 1
)

echo.
echo built: bin\%NAME%.exe
if exist bin\%NAME%.exe dir /b bin\%NAME%.exe
endlocal
exit /b 0

:layoutA
if defined PPC exit /b 0
set R=%~1
if not exist "%R%\bin\i386-win32\ppcross8086.exe" exit /b 0
if not exist "%R%\units\i8086-msdos-large\rtl" exit /b 0
set PPC=%R%\bin\i386-win32\ppcross8086.exe
set UNITPATHS=-Fu"%R%\units\i8086-msdos-large\rtl"
exit /b 0

:layoutB
if defined PPC exit /b 0
set R=%~1
if not exist "%R%\bin\i386-win32\ppcross8086.exe" exit /b 0
if not exist "%R%\units\msdos\80286-large\rtl" exit /b 0
set PPC=%R%\bin\i386-win32\ppcross8086.exe
set UNITPATHS=-Fu"%R%\units\msdos\80286-large\rtl"
exit /b 0

:fromPath
set R=%~dp1
set R=%R:~0,-1%
for %%D in ("%R%") do set R=%%~dpD
set R=%R:~0,-1%
for %%D in ("%R%") do set R=%%~dpD
set R=%R:~0,-1%
call :layoutA "%R%"
call :layoutB "%R%"
exit /b 0
