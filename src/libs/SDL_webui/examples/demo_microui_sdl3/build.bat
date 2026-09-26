@echo off
:: Phase 1 build script — microui demo on SDL3
:: Compiles:  main.c  renderer_sdl3.c  ../../microui/src/microui.c
:: Links against pre-built SDL3 import library from ../../../../bin/
:: Output: demo_microui_sdl3.exe (this directory)

setlocal

set SCRIPT_DIR=%~dp0
:: Strip trailing backslash
set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%

:: Paths relative to this script
set BIN_DIR=%SCRIPT_DIR%\..\..\..\bin
set MU_SRC=%SCRIPT_DIR%\..\..\microui\src

set INC=-I"%BIN_DIR%\include" -I"%MU_SRC%"
set LIB=-L"%BIN_DIR%\lib" -lSDL3
set SRCS="%SCRIPT_DIR%\main.c" "%SCRIPT_DIR%\renderer_sdl3.c" "%MU_SRC%\microui.c"
set OUT="%SCRIPT_DIR%\demo_microui_sdl3.exe"
set FLAGS=-std=c99 -O2 -Wall -Wextra -Wno-unused-parameter

echo Building demo_microui_sdl3...
gcc %FLAGS% %INC% %SRCS% -o %OUT% %LIB% -mwindows

if %ERRORLEVEL% neq 0 (
    echo.
    echo BUILD FAILED.
    exit /b 1
)

echo.
echo Build succeeded: demo_microui_sdl3.exe
echo.
echo Make sure SDL3.dll is accessible (e.g. copy from %BIN_DIR%\bin or add to PATH).
endlocal
