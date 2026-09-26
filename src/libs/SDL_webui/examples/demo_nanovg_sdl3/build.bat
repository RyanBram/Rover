@echo off
:: demo_nanovg_sdl3 — NanoVG + SDL3 + OpenGL3 (FreeType font backend)
::
:: Unity build: main.c #includes nanovg.c + nanovg_gl.c so the GL3 loader
:: macros are in scope during compilation of the nanovg GL backend.
::
:: Requires MinGW-w64 gcc in PATH.

setlocal

set SCRIPT_DIR=%~dp0
set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%

:: rwebview\bin — 4 levels up: demo_nanovg_sdl3 -> examples -> SDL_webui -> libs -> rwebview\bin
set BIN_DIR=%SCRIPT_DIR%\..\..\..\..\bin

:: nanovg source (3 levels up: demo_nanovg_sdl3 -> examples -> SDL_webui -> libs -> nanovg\\src)
set NANOVG_SRC=%SCRIPT_DIR%\..\..\..\nanovg\src

:: FreeType headers bundled with SDL_ttf (4 levels up to rwebview, then libs\SDL_ttf)
set FREETYPE_INC=%SCRIPT_DIR%\..\..\..\..\libs\SDL_ttf\external\freetype\include

:: FreeType static library built alongside SDL_ttf
set FREETYPE_LIB=%SCRIPT_DIR%\..\..\..\..\build\SDL_ttf\external\freetype-build\libfreetype.a

:: Copy SDL3.dll next to the exe if not already present
if not exist "%SCRIPT_DIR%\SDL3.dll" (
    copy "%BIN_DIR%\bin\SDL3.dll" "%SCRIPT_DIR%\SDL3.dll" >nul
)

:: HarfBuzz static library (needed because libfreetype.a was built with HarfBuzz support)
set HARFBUZZ_LIB=%SCRIPT_DIR%\..\..\..\..\build\SDL_ttf\external\harfbuzz-build\libharfbuzz.a

:: nanovg example dir — fonts and demo images are copied from here
set NVG_EXAMPLE=%SCRIPT_DIR%\..\..\..\nanovg\example

:: ---- Copy demo resources (fonts + images) to resources/ -----------------
if not exist "%SCRIPT_DIR%\resources"        mkdir "%SCRIPT_DIR%\resources"
if not exist "%SCRIPT_DIR%\resources\images" mkdir "%SCRIPT_DIR%\resources\images"

for %%F in (entypo.ttf Roboto-Regular.ttf Roboto-Bold.ttf Roboto-Light.ttf NotoEmoji-Regular.ttf) do (
    if not exist "%SCRIPT_DIR%\resources\%%F" (
        copy "%NVG_EXAMPLE%\%%F" "%SCRIPT_DIR%\resources\%%F" >nul
    )
)
robocopy "%NVG_EXAMPLE%\images" "%SCRIPT_DIR%\resources\images" *.jpg /NFL /NDL /NJH /NJS >nul

echo Building demo_nanovg_sdl3...
gcc -std=c99 -O2 -Wall -Wextra ^
    -Wno-unused-parameter ^
    -Wno-unused-variable ^
    -Wno-sign-compare ^
    -Wno-missing-field-initializers ^
    -Wno-implicit-function-declaration ^
    -Wno-implicit-fallthrough ^
    -I"%SCRIPT_DIR%" ^
    -I"%NANOVG_SRC%" ^
    -I"%BIN_DIR%\include" ^
    -I"%FREETYPE_INC%" ^
    "%SCRIPT_DIR%\main.c" ^
    -o "%SCRIPT_DIR%\demo_nanovg_sdl3.exe" ^
    -L"%BIN_DIR%\lib" -lSDL3 "%FREETYPE_LIB%" "%HARFBUZZ_LIB%" -lopengl32 -lm -lstdc++ -lrpcrt4 -mwindows

if %ERRORLEVEL% EQU 0 (
    echo Build succeeded: demo_nanovg_sdl3.exe
) else (
    echo Build FAILED.
    exit /b 1
)
