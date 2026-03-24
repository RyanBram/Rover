@echo off
setlocal EnableDelayedExpansion

rem ============================================================
rem  rwebview Phase 0 build script
rem  Builds SDL3, SDL3_image, SDL3_ttf, SDL_sound, QuickJS, Lexbor from source
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
if not exist "%BIN%"   mkdir "%BIN%"
if not exist "%BUILD%" mkdir "%BUILD%"

rem ============================================================
rem  1. Build SDL3
rem ============================================================
echo [1/7] Building SDL3...
if not exist "%BUILD%\SDL3" mkdir "%BUILD%\SDL3"
pushd "%BUILD%\SDL3"
cmake -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_C_COMPILER=gcc ^
  -DCMAKE_INSTALL_PREFIX="%BIN%" ^
  -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON ^
  -DSDL_SHARED=ON ^
  -DSDL_STATIC=OFF ^
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
echo [OK] SDL3 built and installed.
echo.

rem ============================================================
rem  2. Build SDL3_image
rem ============================================================
echo [2/7] Building SDL3_image...
if not exist "%BUILD%\SDL_image" mkdir "%BUILD%\SDL_image"
pushd "%BUILD%\SDL_image"
cmake -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_C_COMPILER=gcc ^
  -DCMAKE_INSTALL_PREFIX="%BIN%" ^
  -DCMAKE_PREFIX_PATH="%BIN%" ^
  -DSDLIMAGE_SAMPLES=OFF ^
  -DSDLIMAGE_TESTS=OFF ^
  -DSDLIMAGE_AVIF=OFF ^
  -DSDLIMAGE_WEBP=OFF ^
  "%LIBS%\SDL_image"
if %errorlevel% neq 0 ( echo [ERROR] SDL3_image cmake configure failed & popd & exit /b 1 )
cmake --build . --config Release
if %errorlevel% neq 0 ( echo [ERROR] SDL3_image build failed & popd & exit /b 1 )
cmake --install . --config Release
popd
echo [OK] SDL3_image built and installed.
echo.

rem ============================================================
rem  3. Build SDL3_ttf
rem ============================================================
echo [3/7] Building SDL3_ttf...
if not exist "%BUILD%\SDL_ttf" mkdir "%BUILD%\SDL_ttf"
pushd "%BUILD%\SDL_ttf"
cmake -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_C_COMPILER=gcc ^
  -DCMAKE_INSTALL_PREFIX="%BIN%" ^
  -DCMAKE_PREFIX_PATH="%BIN%" ^
  -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON ^
  -DSDLTTF_VENDORED=ON ^
  -DSDLTTF_SAMPLES=OFF ^
  "%LIBS%\SDL_ttf"
if %errorlevel% neq 0 ( echo [ERROR] SDL3_ttf cmake configure failed & popd & exit /b 1 )
cmake --build . --config Release
if %errorlevel% neq 0 ( echo [ERROR] SDL3_ttf build failed & popd & exit /b 1 )
cmake --install . --config Release
popd
echo [OK] SDL3_ttf built and installed.
echo.

rem ============================================================
rem  4. Build SDL_sound (decoder-only audio library)
rem ============================================================
echo [4/7] Building SDL_sound...
if not exist "%BUILD%\SDL_sound" mkdir "%BUILD%\SDL_sound"
pushd "%BUILD%\SDL_sound"
cmake -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_C_COMPILER=gcc ^
  -DCMAKE_INSTALL_PREFIX="%BIN%" ^
  -DCMAKE_PREFIX_PATH="%BIN%" ^
  -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON ^
  -DSDLSOUND_DECODER_MODPLUG=OFF ^
  -DSDLSOUND_DECODER_MIDI=OFF ^
  -DSDLSOUND_DECODER_SHN=OFF ^
  -DSDLSOUND_DECODER_RAW=OFF ^
  -DSDLSOUND_BUILD_STATIC=ON ^
  -DSDLSOUND_BUILD_SHARED=ON ^
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
rem  5. Build QuickJS (static library)
rem ============================================================
echo [5/7] Building QuickJS...
if not exist "%BUILD%\quickjs"       mkdir "%BUILD%\quickjs"
if not exist "%BIN%\lib"             mkdir "%BIN%\lib"
if not exist "%BIN%\include\quickjs" mkdir "%BIN%\include\quickjs"

for /f "usebackq" %%v in ("%LIBS%\quickjs\VERSION") do set "QJSVER=%%v"
echo          QuickJS version: %QJSVER%
echo #define CONFIG_VERSION "%QJSVER%">"%BUILD%\quickjs\qjscfg.h"

set "QJS=%LIBS%\quickjs"
set "QO=%BUILD%\quickjs"

gcc -c -O2 -std=gnu99 -I"%QJS%" -I"%QO%" -include qjscfg.h "%QJS%\quickjs.c"      -o "%QO%\quickjs.o"
if %errorlevel% neq 0 ( echo [ERROR] QuickJS: quickjs.c failed & exit /b 1 )
gcc -c -O2 -std=gnu99 -I"%QJS%" -I"%QO%" -include qjscfg.h "%QJS%\libregexp.c"    -o "%QO%\libregexp.o"
if %errorlevel% neq 0 ( echo [ERROR] QuickJS: libregexp.c failed & exit /b 1 )
gcc -c -O2 -std=gnu99 -I"%QJS%" -I"%QO%" -include qjscfg.h "%QJS%\libunicode.c"   -o "%QO%\libunicode.o"
if %errorlevel% neq 0 ( echo [ERROR] QuickJS: libunicode.c failed & exit /b 1 )
gcc -c -O2 -std=gnu99 -I"%QJS%" -I"%QO%" -include qjscfg.h "%QJS%\cutils.c"       -o "%QO%\cutils.o"
if %errorlevel% neq 0 ( echo [ERROR] QuickJS: cutils.c failed & exit /b 1 )
gcc -c -O2 -std=gnu99 -I"%QJS%" -I"%QO%" -include qjscfg.h "%QJS%\dtoa.c"         -o "%QO%\dtoa.o"
if %errorlevel% neq 0 ( echo [ERROR] QuickJS: dtoa.c failed & exit /b 1 )
gcc -c -O2 -std=gnu99 -I"%QJS%" -I"%QO%" -include qjscfg.h "%QJS%\quickjs-libc.c" -o "%QO%\quickjs_libc.o"
if %errorlevel% neq 0 ( echo [ERROR] QuickJS: quickjs-libc.c failed & exit /b 1 )

ar rcs "%BIN%\lib\libquickjs.a" ^
  "%QO%\quickjs.o" ^
  "%QO%\libregexp.o" ^
  "%QO%\libunicode.o" ^
  "%QO%\cutils.o" ^
  "%QO%\dtoa.o" ^
  "%QO%\quickjs_libc.o"
if %errorlevel% neq 0 ( echo [ERROR] QuickJS: ar archive failed & exit /b 1 )

copy "%QJS%\quickjs.h"      "%BIN%\include\quickjs\" >nul
copy "%QJS%\quickjs-libc.h" "%BIN%\include\quickjs\" >nul
echo [OK] QuickJS built and installed.
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
rem  7. Verify rwebview.nim skeleton compiles
rem ============================================================
echo [7/7] Verifying rwebview.nim skeleton...
nim c --hints:off --warnings:off "--outdir:%BIN%" "%ROOT%\rwebview.nim"
if %errorlevel% neq 0 (
    echo [FAIL] rwebview.nim compilation failed.
    exit /b 1
)
echo [OK] rwebview.nim compiles successfully.
echo.

rem ============================================================
echo ============================================================
echo  Phase 0 COMPLETE
echo ============================================================
echo  Built DLLs location : %BIN%\bin\
echo  Built lib location  : %BIN%\lib\
echo  Built headers       : %BIN%\include\
echo  Nim test binary     : %BIN%\rwebview.exe
echo.
echo  Next: Phase 1 - SDL3 window + QuickJS bootstrap.
echo        See ROADMAP.md Phase 1 for task list.
