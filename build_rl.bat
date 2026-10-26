@echo off
rem ============================================================
rem build_rl.bat -- assemble the RL training-environment DLL
rem Links ONLY logic modules (game/bot/achv/input) plus rl.asm
rem export layer and rl_stub.asm (net/sound/ui placeholders).
rem Output: tankwar_rl.dll (python ctypes driver: tools/rl_env.py)
rem (Keep this file pure ASCII: cmd.exe may not be UTF-8.)
rem ============================================================
setlocal
cd /d "%~dp0"

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
for /f "delims=" %%d in ('dir /b /ad "%VSROOT%\VC\Tools\MSVC"') do set MSVCVER=%%d
set MSVC=%VSROOT%\VC\Tools\MSVC\%MSVCVER%
for /f "delims=" %%d in ('dir /b /ad "%ProgramFiles(x86)%\Windows Kits\10\Lib"') do set SDKVER=%%d
set SDKLIB=%ProgramFiles(x86)%\Windows Kits\10\Lib\%SDKVER%

set PATH=%MSVC%\bin\Hostx64\x86;%PATH%
set LIB=%SDKLIB%\um\x86;%SDKLIB%\ucrt\x86;%MSVC%\lib\x86

echo Toolchain: MSVC %MSVCVER% / SDK %SDKVER%

echo [1/2] Assembling RL env objects...
ml /c /coff /I inc src\game.asm src\bot.asm src\achv.asm src\input.asm src\rl.asm src\rl_stub.asm
if errorlevel 1 (
    echo [ERROR] Assemble failed.
    exit /b 1
)

echo [2/2] Linking DLL...
link /DLL /NOENTRY /DEF:rl.def /OUT:tankwar_rl.dll game.obj bot.obj achv.obj input.obj rl.obj rl_stub.obj kernel32.lib user32.lib
if errorlevel 1 (
    echo [ERROR] Link failed.
    exit /b 1
)

del game.obj bot.obj achv.obj input.obj rl.obj rl_stub.obj
if exist rl.exp del rl.exp rl.lib
echo Build OK: tankwar_rl.dll
endlocal
