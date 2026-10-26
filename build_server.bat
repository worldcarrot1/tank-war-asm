@echo off
rem ============================================================
rem build_server.bat -- compile relay_server.exe
rem Toolchain: Visual Studio bundled CL (locates via vswhere)
rem Output: relay_server.exe in the project root
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
set SDKINC=%ProgramFiles(x86)%\Windows Kits\10\Include\%SDKVER%

set PATH=%MSVC%\bin\Hostx64\x86;%PATH%
set LIB=%SDKLIB%\um\x86;%SDKLIB%\ucrt\x86;%MSVC%\lib\x86
set INCLUDE=%MSVC%\include;%SDKINC%\ucrt;%SDKINC%\um;%SDKINC%\shared

echo [1/1] Compiling relay_server...
cl /O2 /W3 /utf-8 /Fe:relay_server.exe server\relay_server.c ws2_32.lib
if errorlevel 1 (
    echo [ERROR] Compile failed.
    exit /b 1
)

del *.obj
echo Build OK: relay_server.exe
endlocal
