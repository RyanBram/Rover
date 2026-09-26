@echo off
setlocal EnableDelayedExpansion

rem ============================================================
rem  rwebview Phase 0 build script
rem  Builds SDL3, SDL3_image, SDL_sound, FreeType2, QuickJS, Lexbor from source
rem  SDL is always linked statically. Format/decoder selection: sdl_formats.conf in project root.
rem  using CMake + Ninja, then verifies rwebview.nim compiles.
rem
rem  Requirements:
rem    cmake.exe  (on PATH)
rem    ninja.exe  (on PATH)
rem    gcc.exe    (MinGW-W64, on PATH)
rem    nim        (on PATH)
rem ============================================================

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

set "LIBS=%ROOT%\libs"
set "BIN=%ROOT%\bin"
set "BUILD=%ROOT%\build"

echo ============================================================
echo  rwebview Phase 0 Build
echo ============================================================
echo  ROOT  = %ROOT%
echo  LIBS  = %LIBS%
echo  BIN   = %BIN%
echo  BUILD = %BUILD%
echo.

rem -- Verify required tools --
where cmake  >nul 2>&1 || ( echo [ERROR] cmake not found on PATH & exit /b 1 )
where ninja  >nul 2>&1 || ( echo [ERROR] ninja not found on PATH & exit /b 1 )
where gcc    >nul 2>&1 || ( echo [ERROR] gcc   not found on PATH & exit /b 1 )
where nim    >nul 2>&1 || ( echo [ERROR] nim   not found on PATH & exit /b 1 )

rem -- Create directories --
if not exist "%BIN%"              mkdir "%BIN%"
if not exist "%BUILD%"            mkdir "%BUILD%"
if not exist "%BIN%\staticlib\lib" mkdir "%BIN%\staticlib\lib"

rem ============================================================
rem  Load format/decoder config from project root (sdl_formats.conf)
rem  Edit that file to toggle SDL_image formats and SDL_sound decoders.
rem ============================================================
set "SDLCONF=%ROOT%\..\..\sdl_formats.conf"

rem -- Defaults (used when key is absent from config file) --
set CFG_IMAGE_BMP=ON
set CFG_IMAGE_GIF=ON
set CFG_IMAGE_JPG=ON
set CFG_IMAGE_PNG=ON
set CFG_IMAGE_QOI=ON
set CFG_IMAGE_SVG=ON
set CFG_IMAGE_TGA=ON
set CFG_IMAGE_TIFF=OFF
set CFG_IMAGE_AVIF=OFF
set CFG_IMAGE_WEBP=OFF
set CFG_IMAGE_PNM=OFF
set CFG_IMAGE_XCF=OFF
set CFG_IMAGE_PCX=OFF
set CFG_IMAGE_LBM=OFF
set CFG_AUDIO_WAV=ON
set CFG_AUDIO_OGG=ON
set CFG_AUDIO_FLAC=ON
set CFG_AUDIO_MP3=ON
set CFG_AUDIO_OPUS=ON
set CFG_AUDIO_AIFF=ON
set CFG_AUDIO_AU=OFF
set CFG_AUDIO_MIDI=OFF
set CFG_AUDIO_MODPLUG=OFF
set CFG_AUDIO_SHN=OFF
set CFG_AUDIO_RAW=OFF

if exist "!SDLCONF!" (
  echo Loading format config from: !SDLCONF!
  for /f "usebackq eol=# tokens=1,2 delims==" %%A in ("!SDLCONF!") do (
    if not "%%A"=="" set "CFG_%%A=%%B"
  )
) else (
  echo [INFO] sdl_formats.conf not found at project root; using defaults.
)
echo.

rem ============================================================
rem  1. Build SDL3 (static)
rem ============================================================
echo [1/7] Building SDL3 (static)...
if not exist "%BUILD%\SDL3" mkdir "%BUILD%\SDL3"
pushd "%BUILD%\SDL3"
cmake -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_C_COMPILER=gcc ^
  -DCMAKE_INSTALL_PREFIX="%BIN%\staticlib" ^
  -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON ^
  -DSDL_SHARED=OFF ^
  -DSDL_STATIC=ON ^
  -DSDL_TEST_LIBRARY=OFF ^
  -DSDL_TESTS=OFF ^
  -DSDL_OPENGL=ON ^
  -DSDL_AUDIO=ON ^
  "%LIBS%\SDL"
if %errorlevel% neq 0 ( echo [ERROR] SDL3 cmake configure failed & popd & exit /b 1 )
cmake --build . --config Release
if %errorlevel% neq 0 ( echo [ERROR] SDL3 build failed & popd & exit /b 1 )
cmake --install . --config Release
if %errorlevel% neq 0 ( echo [ERROR] SDL3 install failed & popd & exit /b 1 )
popd
echo [OK] SDL3 static built and installed.
echo.

rem ============================================================
rem  2. Build SDL3_image (static, with configured format flags)
rem ============================================================
echo [2/7] Building SDL3_image (static)...
echo   BMP=!CFG_IMAGE_BMP! GIF=!CFG_IMAGE_GIF! JPG=!CFG_IMAGE_JPG! PNG=!CFG_IMAGE_PNG!
echo   QOI=!CFG_IMAGE_QOI! SVG=!CFG_IMAGE_SVG! TGA=!CFG_IMAGE_TGA! TIFF=!CFG_IMAGE_TIFF!
echo   AVIF=!CFG_IMAGE_AVIF! WEBP=!CFG_IMAGE_WEBP!
if not exist "%BUILD%\SDL_image" mkdir "%BUILD%\SDL_image"
pushd "%BUILD%\SDL_image"
cmake -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_C_COMPILER=gcc ^
  -DCMAKE_INSTALL_PREFIX="%BIN%\staticlib" ^
  -DCMAKE_PREFIX_PATH="%BIN%\staticlib" ^
  -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON ^
  -DBUILD_SHARED_LIBS=OFF ^
  -DSDLIMAGE_SAMPLES=OFF ^
  -DSDLIMAGE_TESTS=OFF ^
  -DSDLIMAGE_BMP=!CFG_IMAGE_BMP! ^
  -DSDLIMAGE_GIF=!CFG_IMAGE_GIF! ^
  -DSDLIMAGE_JPG=!CFG_IMAGE_JPG! ^
  -DSDLIMAGE_PNG=!CFG_IMAGE_PNG! ^
  -DSDLIMAGE_QOI=!CFG_IMAGE_QOI! ^
  -DSDLIMAGE_SVG=!CFG_IMAGE_SVG! ^
  -DSDLIMAGE_TGA=!CFG_IMAGE_TGA! ^
  -DSDLIMAGE_TIFF=!CFG_IMAGE_TIFF! ^
  -DSDLIMAGE_AVIF=!CFG_IMAGE_AVIF! ^
  -DSDLIMAGE_WEBP=!CFG_IMAGE_WEBP! ^
  -DSDLIMAGE_PNM=!CFG_IMAGE_PNM! ^
  -DSDLIMAGE_XCF=!CFG_IMAGE_XCF! ^
  -DSDLIMAGE_PCX=!CFG_IMAGE_PCX! ^
  -DSDLIMAGE_LBM=!CFG_IMAGE_LBM! ^
  "%LIBS%\SDL_image"
if %errorlevel% neq 0 ( echo [ERROR] SDL3_image cmake configure failed & popd & exit /b 1 )
cmake --build . --config Release
if %errorlevel% neq 0 ( echo [ERROR] SDL3_image build failed & popd & exit /b 1 )
cmake --install . --config Release
if %errorlevel% neq 0 ( echo [ERROR] SDL3_image install failed & popd & exit /b 1 )
popd
echo [OK] SDL3_image static built and installed.
echo.

rem ============================================================
rem  3. Build FreeType2 (standalone, used by fontstash/nanovg)
rem     Source: libs/SDL_ttf/external/freetype  (vendored copy)
rem ============================================================
echo [3/7] Building FreeType2...
if not exist "%BUILD%\freetype" mkdir "%BUILD%\freetype"
pushd "%BUILD%\freetype"
cmake -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_C_COMPILER=gcc ^
  -DCMAKE_INSTALL_PREFIX="%BIN%\freetype" ^
  -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON ^
  -DBUILD_SHARED_LIBS=OFF ^
  -DFT_DISABLE_ZLIB=ON ^
  -DFT_DISABLE_BZIP2=ON ^
  -DFT_DISABLE_PNG=ON ^
  -DFT_DISABLE_HARFBUZZ=ON ^
  -DFT_DISABLE_BROTLI=ON ^
  "%LIBS%\SDL_ttf\external\freetype"
if %errorlevel% neq 0 ( echo [ERROR] FreeType2 cmake configure failed & popd & exit /b 1 )
cmake --build . --config Release
if %errorlevel% neq 0 ( echo [ERROR] FreeType2 build failed & popd & exit /b 1 )
cmake --install . --config Release
if %errorlevel% neq 0 ( echo [ERROR] FreeType2 install failed & popd & exit /b 1 )
popd
echo [OK] FreeType2 built and installed.
echo.

rem ============================================================
rem  4. Build SDL_sound (static, with configured decoder flags)
rem ============================================================
echo [4/7] Building SDL_sound (static)...
echo   WAV=!CFG_AUDIO_WAV! OGG=!CFG_AUDIO_OGG! FLAC=!CFG_AUDIO_FLAC! MP3=!CFG_AUDIO_MP3!
echo   OPUS=!CFG_AUDIO_OPUS! AIFF=!CFG_AUDIO_AIFF! AU=!CFG_AUDIO_AU! MIDI=!CFG_AUDIO_MIDI!
if not exist "%BUILD%\SDL_sound" mkdir "%BUILD%\SDL_sound"
pushd "%BUILD%\SDL_sound"
cmake -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_C_COMPILER=gcc ^
  -DCMAKE_INSTALL_PREFIX="%BIN%" ^
  -DCMAKE_PREFIX_PATH="%BIN%\staticlib;%BIN%" ^
  -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON ^
  -DSDLSOUND_BUILD_STATIC=ON ^
  -DSDLSOUND_BUILD_SHARED=OFF ^
  -DSDLSOUND_DECODER_WAV=!CFG_AUDIO_WAV! ^
  -DSDLSOUND_DECODER_VORBIS=!CFG_AUDIO_OGG! ^
  -DSDLSOUND_DECODER_FLAC=!CFG_AUDIO_FLAC! ^
  -DSDLSOUND_DECODER_MP3=!CFG_AUDIO_MP3! ^
  -DSDLSOUND_DECODER_OPUS=!CFG_AUDIO_OPUS! ^
  -DSDLSOUND_DECODER_AIFF=!CFG_AUDIO_AIFF! ^
  -DSDLSOUND_DECODER_AU=!CFG_AUDIO_AU! ^
  -DSDLSOUND_DECODER_MIDI=!CFG_AUDIO_MIDI! ^
  -DSDLSOUND_DECODER_MODPLUG=!CFG_AUDIO_MODPLUG! ^
  -DSDLSOUND_DECODER_SHN=!CFG_AUDIO_SHN! ^
  -DSDLSOUND_DECODER_RAW=!CFG_AUDIO_RAW! ^
  "%LIBS%\SDL_sound"
if %errorlevel% neq 0 ( echo [ERROR] SDL_sound cmake configure failed & popd & exit /b 1 )
cmake --build . --config Release
if %errorlevel% neq 0 ( echo [ERROR] SDL_sound build failed & popd & exit /b 1 )
cmake --install . --config Release
if %errorlevel% neq 0 ( echo [ERROR] SDL_sound install failed & popd & exit /b 1 )
popd
echo [OK] SDL_sound built and installed.
echo.

rem ============================================================
rem  5. Build QuickJS (static library)  -- default JS engine
rem ============================================================
echo [5/7] Building QuickJS...
if not exist "%BUILD%\quickjs" mkdir "%BUILD%\quickjs"
if not exist "%BIN%\lib"          mkdir "%BIN%\lib"
if not exist "%BIN%\include\quickjs" mkdir "%BIN%\include\quickjs"
pushd "%BUILD%\quickjs"
cmake -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_C_COMPILER=gcc ^
  -DCMAKE_INSTALL_PREFIX="%BIN%" ^
  -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON ^
  -DBUILD_SHARED_LIBS=OFF ^
  -DQJS_ENABLE_INSTALL=ON ^
  -DQJS_BUILD_EXAMPLES=OFF ^
  -DQJS_BUILD_CLI_STATIC=OFF ^
  "%LIBS%\quickjs"
if %errorlevel% neq 0 ( echo [ERROR] QuickJS cmake configure failed & popd & exit /b 1 )
cmake --build . --config Release
if %errorlevel% neq 0 ( echo [ERROR] QuickJS build failed & popd & exit /b 1 )
cmake --install . --config Release
if %errorlevel% neq 0 ( echo [ERROR] QuickJS install failed & popd & exit /b 1 )
popd
rem Clean up stale aliases from previous builds
if exist "%BIN%\lib\libquickjsng.a" del "%BIN%\lib\libquickjsng.a"
if exist "%BIN%\lib\libquickjs.a"   del "%BIN%\lib\libquickjs.a"
echo [OK] QuickJS built and installed (lib: libqjs.a, header: quickjs.h).
echo.

rem ============================================================
rem  6. Build Lexbor (static HTML parser library)
rem ============================================================
echo [6/7] Building Lexbor...
if not exist "%BUILD%\lexbor" mkdir "%BUILD%\lexbor"
pushd "%BUILD%\lexbor"
cmake -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_C_COMPILER=gcc ^
  -DCMAKE_INSTALL_PREFIX="%BIN%" ^
  -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON ^
  -DLEXBOR_BUILD_SHARED=OFF ^
  -DLEXBOR_BUILD_STATIC=ON ^
  -DLEXBOR_BUILD_EXAMPLES=OFF ^
  -DLEXBOR_BUILD_TESTS=OFF ^
  -DLEXBOR_BUILD_UTILS=OFF ^
  -DLEXBOR_INSTALL_HEADERS=ON ^
  "%LIBS%\lexbor"
if %errorlevel% neq 0 ( echo [ERROR] Lexbor cmake configure failed & popd & exit /b 1 )
cmake --build . --config Release
if %errorlevel% neq 0 ( echo [ERROR] Lexbor build failed & popd & exit /b 1 )
cmake --install . --config Release
if %errorlevel% neq 0 ( echo [ERROR] Lexbor install failed & popd & exit /b 1 )
popd
echo [OK] Lexbor built and installed.
echo.

rem ============================================================
rem  7. Build rgss.dll (rwebview as DLL with QuickJS engine)
rem ============================================================
echo [7/7] Building rgss.dll...
nim c --hints:off --warnings:off --threads:on --opt:size --app:lib -d:rwebviewLib -d:sdlStatic --passL:"-Wl,--export-all-symbols" "--out:%BIN%\rgss.dll" "%ROOT%\rwebview.nim"
if %errorlevel% neq 0 (
    echo [FAIL] rgss.dll compilation failed.
    exit /b 1
)
echo [OK] rgss.dll built successfully.
echo.

rem ============================================================
echo ============================================================
echo  Phase 0 COMPLETE
echo ============================================================
echo  SDL3 static lib     : %BIN%\staticlib\lib\
echo  FreeType2 headers   : %BIN%\freetype\include\
echo  Built lib location  : %BIN%\lib\
echo  Built headers       : %BIN%\include\
echo  rwebview DLL        : %BIN%\rgss.dll
echo.
echo  Next: Phase 1 - SDL3 window + QuickJS bootstrap.
echo        See ROADMAP.md Phase 1 for task list.
