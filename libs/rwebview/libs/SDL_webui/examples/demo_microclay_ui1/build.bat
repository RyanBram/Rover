@echo off
:: Phase 3a build script — microclay_ui: Clay layout + microui widgets on SDL3
:: Compiles:  main.c  ../demo_microui_sdl3/renderer_sdl3.c  ../../microui/src/microui.c
:: Links:     pre-built SDL3 import library
:: Output:    demo_microclay_ui1_sdl3.exe

setlocal

set SCRIPT_DIR=%~dp0
set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%

:: Paths relative to this script
set BIN_DIR=%SCRIPT_DIR%\..\..\..\bin
set MU_SRC=%SCRIPT_DIR%\..\..\microui\src
set CLAY_DIR=%SCRIPT_DIR%\..\..\clay
set RENDERER_DIR=%SCRIPT_DIR%\..\demo_microui_sdl3

set INC=-I"%BIN_DIR%\include" -I"%MU_SRC%" -I"%CLAY_DIR%" -I"%RENDERER_DIR%"
set LIB=-L"%BIN_DIR%\lib" -lSDL3
set SRCS="%SCRIPT_DIR%\main.c" "%RENDERER_DIR%\renderer_sdl3.c" "%MU_SRC%\microui.c"
set OUT="%SCRIPT_DIR%\demo_microclay_ui1_sdl3.exe"
set FLAGS=-std=c99 -O2 -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -Wno-unknown-pragmas -Wno-sign-compare

echo Building demo_microclay_ui1_sdl3 (Phase 3a)...
gcc %FLAGS% %INC% %SRCS% -o %OUT% %LIB% -mwindows

if %ERRORLEVEL% neq 0 (
    echo.
    echo BUILD FAILED.
    exit /b 1
)

echo.
echo Build succeeded: demo_microclay_ui1_sdl3.exe

:: Copy SDL3.dll if not already present
if not exist "%SCRIPT_DIR%\SDL3.dll" (
    copy "%BIN_DIR%\bin\SDL3.dll" "%SCRIPT_DIR%\SDL3.dll" >nul
    echo Copied SDL3.dll
)

echo Done.
endlocal
