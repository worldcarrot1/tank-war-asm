@echo off
rem ============================================================
rem build.bat -- one-step assemble + link
rem Toolchain: Visual Studio bundled MASM (ml.exe) + link.exe
rem Locates VS and the latest MSVC/SDK via vswhere.
rem Output: tankwar.exe in the project root
rem (Keep this file pure ASCII: cmd.exe may not be UTF-8.)
rem ============================================================
setlocal
cd /d "%~dp0"

rem ---- 1) locate Visual Studio ----
set VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe
if not exist "%VSWHERE%" (
    echo [ERROR] vswhere.exe not found. Install Visual Studio with C++ tools.
    exit /b 1
)
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set VSROOT=%%i
if not defined VSROOT (
    echo [ERROR] No Visual Studio with C++ toolset found.
    exit /b 1
)

rem ---- 2) locate latest MSVC and Windows SDK ----
for /f "delims=" %%d in ('dir /b /ad "%VSROOT%\VC\Tools\MSVC"') do set MSVCVER=%%d
set MSVC=%VSROOT%\VC\Tools\MSVC\%MSVCVER%
for /f "delims=" %%d in ('dir /b /ad "%ProgramFiles(x86)%\Windows Kits\10\Lib"') do set SDKVER=%%d
set SDKLIB=%ProgramFiles(x86)%\Windows Kits\10\Lib\%SDKVER%

set PATH=%MSVC%\bin\Hostx64\x86;%PATH%
set LIB=%SDKLIB%\um\x86;%SDKLIB%\ucrt\x86;%MSVC%\lib\x86

echo Toolchain: MSVC %MSVCVER% / SDK %SDKVER%

echo [1/2] Assembling...
ml /c /coff /I inc src\main.asm src\gfx.asm src\input.asm src\game.asm src\net.asm
if errorlevel 1 (
    echo [ERROR] Assemble failed.
    exit /b 1
)

echo [2/2] Linking...
link /SUBSYSTEM:WINDOWS /ENTRY:start /OUT:tankwar.exe main.obj gfx.obj input.obj game.obj net.obj
if errorlevel 1 (
    echo [ERROR] Link failed.
    exit /b 1
)

del *.obj
echo Build OK: tankwar.exe
endlocal
