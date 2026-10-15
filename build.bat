@echo off
rem ============================================================
rem build.bat —— 一键汇编 + 链接
rem 前提：MASM32 SDK 安装在 C:\masm32
rem 产物：项目根目录下的 tankwar.exe
rem ============================================================
setlocal

set MASM32=C:\masm32
if not exist "%MASM32%\bin\ml.exe" (
    echo [错误] 未找到 %MASM32%\bin\ml.exe，请先安装 MASM32 SDK
    exit /b 1
)

set PATH=%MASM32%\bin;%PATH%
set INCLUDE=%MASM32%\include
set LIB=%MASM32%\lib

cd /d "%~dp0"

echo [1/2] 汇编源文件...
ml /c /coff /I inc src\main.asm src\gfx.asm src\input.asm src\game.asm src\net.asm
if errorlevel 1 (
    echo [错误] 汇编失败
    exit /b 1
)

echo [2/2] 链接...
link /SUBSYSTEM:WINDOWS main.obj gfx.obj input.obj game.obj net.obj /OUT:tankwar.exe
if errorlevel 1 (
    echo [错误] 链接失败
    exit /b 1
)

del *.obj
echo 构建成功：tankwar.exe
endlocal
