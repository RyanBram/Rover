@echo off
:: SDL_webui demo 3 build script — Phase 3b with NanoVG renderer
::
:: Renderer:  renderer_nvg_sdl3.c  (NanoVG + stb_truetype, no SDL3_ttf)
:: Backend:   nanovg_sdl3.c        (SDL_RenderGeometry backend for NanoVG)
:: NanoVG:    nanovg.c             (unity-built inside renderer_nvg_sdl3.c)
:: Layout:    SDL_webui.c  microui.c  flex.c
::
:: Libraries: SDL3 only (SDL3_ttf no longer required)
:: Output:    demo_sdl_webui3_sdl3.exe

setlocal

set SCRIPT_DIR=%~dp0
set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%

:: Paths relative to this script
set BIN_DIR=%SCRIPT_DIR%\..\..\..\..\bin
set SRC_DIR=%SCRIPT_DIR%\..\..\src
set ROOT_DIR=%SCRIPT_DIR%\..\..\..\..
set FREETYPE_INC=%ROOT_DIR%\libs\SDL_ttf\external\freetype\include
set FREETYPE_LIB=%ROOT_DIR%\build\SDL_ttf\external\freetype-build\libfreetype.a
set HARFBUZZ_LIB=%ROOT_DIR%\build\SDL_ttf\external\harfbuzz-build\libharfbuzz.a

set WEBUI_DIR=%SCRIPT_DIR%\..\..
set INC=-I"%BIN_DIR%\include" -I"%SRC_DIR%" -I"%WEBUI_DIR%\include" -I"%SCRIPT_DIR%" -I"%FREETYPE_INC%"
set LIB=-L"%BIN_DIR%\lib" -lSDL3 -lSDL3_image "%FREETYPE_LIB%" "%HARFBUZZ_LIB%" -lrpcrt4 -lm

::
:: nanovg.c is compiled as a separate translation unit.
:: nanovg_sdl3.c is the SDL3_Renderer backend for NanoVG.
:: renderer_nvg_sdl3.c includes only nanovg.h (no unity build).
::
set SRCS="%SCRIPT_DIR%\main.c" "%SCRIPT_DIR%\renderer_nvg_sdl3.c" "%SRC_DIR%\nanovg.c" "%SRC_DIR%\nanovg_sdl3.c" "%SRC_DIR%\SDL_webui.c" "%SRC_DIR%\microui.c" "%SRC_DIR%\flex.c"
set OUT="%SCRIPT_DIR%\demo_sdl_webui3_sdl3.exe"
set FLAGS=-std=c99 -O2 -Wall -Wextra -DFONS_USE_FREETYPE -Wno-unused-parameter -Wno-missing-field-initializers -Wno-unknown-pragmas -Wno-sign-compare -Wno-unused-function

echo Building demo_sdl_webui3_sdl3 (Phase 3b + NanoVG renderer)...
gcc %FLAGS% %INC% %SRCS% -o %OUT% %LIB% -mwindows

if %ERRORLEVEL% neq 0 (
    echo.
    echo BUILD FAILED.
    exit /b 1
)

echo.
echo Build succeeded: demo_sdl_webui3_sdl3.exe

:: Copy SDL3.dll if not already present
if not exist "%SCRIPT_DIR%\SDL3.dll" (
    copy "%BIN_DIR%\bin\SDL3.dll" "%SCRIPT_DIR%\SDL3.dll" >nul
    echo Copied SDL3.dll
)

:: Copy Roboto-Bold.ttf from nanovg demo resources (for bold font variant)
if not exist "%SCRIPT_DIR%\resources\Roboto-Bold.ttf" (
    if exist "%SCRIPT_DIR%\..\demo_nanovg_sdl3\resources\Roboto-Bold.ttf" (
        copy "%SCRIPT_DIR%\..\demo_nanovg_sdl3\resources\Roboto-Bold.ttf" "%SCRIPT_DIR%\resources\Roboto-Bold.ttf" >nul
        echo Copied Roboto-Bold.ttf
    )
)

echo Done.
endlocal
