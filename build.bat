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
ECHO 3. rwebview
SET srcdir=%~dp0src
SET rcedit=%~dp0bin\rcedit\rcedit-x64.exe
SET upx=%~dp0bin\upx\upx.exe
SET /p buildtype="Type: "

if /i "%buildtype%"=="1" goto debug
if /i "%buildtype%"=="2" goto release
if /i "%buildtype%"=="3" goto rwebview

echo.
echo ================================================
echo   Build Complete!
echo ================================================
pause

@ECHO off

:debug
ECHO Compile debug
nim c -f --threads:on --opt:size --app:gui "%srcdir%\rover.nim"
goto done

:release
ECHO Compile release
nim c -f -d:release --threads:on --opt:size --app:gui "%srcdir%\rover.nim"
goto done

:rwebview
nim c -f -d:rwebview --threads:on --opt:size --app:gui "%srcdir%\rover.nim"

:done
"%rcedit%" "%srcdir%\rover.exe" --set-icon "%icon%" --set-file-version "%fileversion%" --set-product-version "%fileversion%" --set-version-string "FileDescription" "%filedescription%"
rem "%upx%" --no-env --overlay=strip "%srcdir%\rover.exe"
pause