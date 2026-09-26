@echo off
setlocal

REM Paths relative to this script's directory
set SCRIPT_DIR=%~dp0
set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%

REM rwebview\bin — 3 levels up: demo_gles3_sdl3 -> microclay_ui -> libs -> rwebview\bin
set BIN_DIR=%SCRIPT_DIR%\..\..\..\bin

REM clay library — 2 levels up from demo_gles3_sdl3: microclay_ui -> libs\clay
set CLAY_DIR=%SCRIPT_DIR%\..\..\clay
set RENDERER_DIR=%CLAY_DIR%\renderers\GLES3
set STB_DIR=%SCRIPT_DIR%\stb

set INCLUDE=-I"%BIN_DIR%\include" -I"%CLAY_DIR%" -I"%STB_DIR%" -I"%RENDERER_DIR%"
set LIBS=-L"%BIN_DIR%\lib" -lSDL3 -lopengl32

REM Copy SDL3.dll next to the exe if not already there
if not exist "%SCRIPT_DIR%\SDL3.dll" (
    copy "%BIN_DIR%\bin\SDL3.dll" "%SCRIPT_DIR%\SDL3.dll" >nul
)

REM Copy the font resource
if not exist "%SCRIPT_DIR%\resources" mkdir "%SCRIPT_DIR%\resources"
if not exist "%SCRIPT_DIR%\resources\Roboto-Regular.ttf" (
    copy "%CLAY_DIR%\examples\GLES3-SDL2-video-demo\resources\Roboto-Regular.ttf" ^
         "%SCRIPT_DIR%\resources\Roboto-Regular.ttf" >nul
)

gcc -std=c99 -O2 -Wall -Wextra ^
    -Wno-unknown-pragmas ^
    -Wno-sign-compare ^
    -Wno-unused-parameter ^
    -Wno-unused-variable ^
    -Wno-missing-field-initializers ^
    -Wno-implicit-function-declaration ^
    -Wno-builtin-declaration-mismatch ^
    %INCLUDE% ^
    "%SCRIPT_DIR%\main.c" ^
    -o "%SCRIPT_DIR%\demo_gles3_sdl3.exe" ^
    %LIBS% -mwindows

if %ERRORLEVEL% EQU 0 (
    echo Build succeeded: demo_gles3_sdl3.exe
) else (
    echo Build FAILED.
    exit /b 1
)
