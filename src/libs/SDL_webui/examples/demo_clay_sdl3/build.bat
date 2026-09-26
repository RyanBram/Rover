@echo off
:: Phase 2 build script — clay SDL3-simple-demo (MinGW, no CMake)
:: Compiles:  main.c  (which #includes clay_renderer_SDL3.c and clay-video-demo.c)
:: Links against pre-built SDL3 + SDL3_ttf + SDL3_image from ../../../../bin/
:: Output: demo_clay_sdl3.exe (this directory)

setlocal

set SCRIPT_DIR=%~dp0
set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%

set BIN_DIR=%SCRIPT_DIR%\..\..\..\bin

set INC=-I"%BIN_DIR%\include"
set LIB=-L"%BIN_DIR%\lib" -lSDL3 -lSDL3_ttf -lSDL3_image
set SRCS="%SCRIPT_DIR%\main.c"
set OUT="%SCRIPT_DIR%\demo_clay_sdl3.exe"
set FLAGS=-std=c99 -O2 -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers

:: Suppress pragma/sign-compare warnings that come from upstream clay headers/renderer.
:: These are not our code and cannot be changed without modifying upstream files.
set FLAGS=%FLAGS% -Wno-unknown-pragmas -Wno-sign-compare -Wno-pedantic

echo Building demo_clay_sdl3...
gcc %FLAGS% %INC% %SRCS% -o %OUT% %LIB% -mwindows

if %ERRORLEVEL% neq 0 (
    echo.
    echo BUILD FAILED.
    exit /b 1
)

echo.
echo Build succeeded: demo_clay_sdl3.exe
echo.
echo Resources (font + image) are read from .\resources\ at runtime.
echo Make sure SDL3.dll, SDL3_ttf.dll, SDL3_image.dll are accessible.
endlocal
