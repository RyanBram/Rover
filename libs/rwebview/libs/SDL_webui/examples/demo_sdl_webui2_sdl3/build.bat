@echo off
:: SDL_webui demo 2 build script — Phase 3b CSS/HTML-mapped API
:: Compiles:  main.c  renderer_sdl3.c  SDL_webui.c  microui.c  flex.c
:: Links:     pre-built SDL3 import library
:: Output:    demo_sdl_webui2_sdl3.exe

setlocal

set SCRIPT_DIR=%~dp0
set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%

:: Paths relative to this script
set BIN_DIR=%SCRIPT_DIR%\..\..\..\..\bin
set SRC_DIR=%SCRIPT_DIR%\..\..\src

set WEBUI_DIR=%SCRIPT_DIR%\..\..
set INC=-I"%BIN_DIR%\include" -I"%SRC_DIR%" -I"%WEBUI_DIR%\include" -I"%SCRIPT_DIR%"
set LIB=-L"%BIN_DIR%\lib" -lSDL3 -lSDL3_ttf
set SRCS="%SCRIPT_DIR%\main.c" "%SCRIPT_DIR%\renderer_sdl3_ttf.c" "%SRC_DIR%\SDL_webui.c" "%SRC_DIR%\microui.c" "%SRC_DIR%\flex.c"
set OUT="%SCRIPT_DIR%\demo_sdl_webui2_sdl3.exe"
set FLAGS=-std=c99 -O2 -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -Wno-unknown-pragmas -Wno-sign-compare

echo Building demo_sdl_webui2_sdl3 (Phase 3b CSS/HTML API)...
gcc %FLAGS% %INC% %SRCS% -o %OUT% %LIB% -mwindows

if %ERRORLEVEL% neq 0 (
    echo.
    echo BUILD FAILED.
    exit /b 1
)

echo.
echo Build succeeded: demo_sdl_webui2_sdl3.exe

:: Copy SDL3.dll if not already present
if not exist "%SCRIPT_DIR%\SDL3.dll" (
    copy "%BIN_DIR%\bin\SDL3.dll" "%SCRIPT_DIR%\SDL3.dll" >nul
    echo Copied SDL3.dll
)

:: Copy SDL3_ttf.dll if not already present
if not exist "%SCRIPT_DIR%\SDL3_ttf.dll" (
    copy "%BIN_DIR%\bin\SDL3_ttf.dll" "%SCRIPT_DIR%\SDL3_ttf.dll" >nul
    echo Copied SDL3_ttf.dll
)

echo Done.
endlocal
