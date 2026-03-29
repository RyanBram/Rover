@echo off
SET icon=%~dp0assets\icons\application.ico
SET fileversion=3.0
SET filedescription=Rover
echo ================================================
echo   Building Rover
echo ================================================
ECHO "Choose your build type"
ECHO 1. debug
ECHO 2. release
ECHO 3. rgss
SET srcdir=%~dp0src
SET builddir=%~dp0build
IF NOT EXIST "%builddir%" mkdir "%builddir%"
SET rcedit=%~dp0bin\rcedit\rcedit-x64.exe
SET upx=%~dp0bin\upx\upx.exe
SET /p buildtype="Type: "

if /i "%buildtype%"=="1" goto debug
if /i "%buildtype%"=="2" goto release
if /i "%buildtype%"=="3" goto rgss

echo.
echo ================================================
echo   Build Complete!
echo ================================================
pause

@ECHO off

:debug
ECHO Compile debug
nim c -f --threads:on --opt:size --app:gui --out:"%builddir%\Rover.exe" "%srcdir%\rover.nim"
"%rcedit%" "%builddir%\Rover.exe" --set-icon "%icon%" --set-file-version "%fileversion%" --set-product-version "%fileversion%" --set-version-string "FileDescription" "webview2"

goto done

:release
ECHO Compile release
nim c -f -d:release --threads:on --opt:size --app:gui --out:"%builddir%\Rover.exe" "%srcdir%\rover.nim"
goto done

:rgss
set "sdl3static=%~dp0libs\rwebview\bin\staticlib\lib\libSDL3.a"
set "sdlimgstatic=%~dp0libs\rwebview\bin\staticlib\lib\libSDL3_image.a"
set "freetypelib=%~dp0libs\rwebview\bin\freetype\lib\libfreetype.a"
if not exist "%sdl3static%" goto builddeps
if not exist "%sdlimgstatic%" goto builddeps
if not exist "%freetypelib%" goto builddeps
goto compilergss

:builddeps
ECHO Dependensi SDL3 static belum dibangun. Menjalankan buildrwebview.bat...
call "%~dp0libs\rwebview\buildrwebview.bat"
if %errorlevel% neq 0 (
    ECHO [ERROR] buildrwebview.bat gagal. Hentikan build.
    goto done
)

:compilergss
ECHO Compiling rgss.dll (SDL+QuickJS engine)...
nim c -f --threads:on --opt:size --app:lib -d:rwebviewLib -d:sdlStatic --passL:"-Wl,--export-all-symbols" "--out:%builddir%\rgss.dll" "%~dp0libs\rwebview\rwebview.nim"
"%rcedit%" "%builddir%\rgss.dll" --set-file-version "%fileversion%" --set-product-version "%fileversion%" --set-version-string "FileDescription" "rgss"

if %errorlevel% neq 0 goto done
ECHO Compiling Rover.exe (webview2 + rgss support)...
nim c -f --threads:on --opt:size "--out:%builddir%\Rover.exe" "%srcdir%\rover.nim"
if %errorlevel% neq 0 goto done
"%rcedit%" "%builddir%\Rover.exe" --set-icon "%icon%" --set-file-version "%fileversion%" --set-product-version "%fileversion%" --set-version-string "FileDescription" "Rover"

:done
rem "%upx%" --no-env --overlay=strip "%srcdir%\rover.exe"
pause