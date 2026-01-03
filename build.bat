@echo off
SET icon=%~dp0assets\icons\application.ico
SET fileversion=1.0
SET filedescription=Rover
echo ================================================
echo   Building Rover
echo ================================================
ECHO "Choose your build type"
ECHO 1. debug
ECHO 2. release
SET srcdir=%~dp0src
SET rcedit=%~dp0bin\rcedit\rcedit-x64.exe
SET /p buildtype="Type: "

if /i "%buildtype%"=="1" goto debug
if /i "%buildtype%"=="2" goto release

echo.
echo ================================================
echo   Build Complete!
echo ================================================
pause

@ECHO off

:debug
ECHO Compile debug
nim c -f --opt:size --app:gui "%srcdir%\rover.nim"
goto done

:release
ECHO Compile release
nim c -f -d:release --opt:size --app:gui "%srcdir%\rover.nim"
goto done

:done
"%rcedit%" "%srcdir%\rover.exe" --set-icon "%icon%" --set-file-version "%fileversion%" --set-product-version "%fileversion%" --set-version-string "FileDescription" "%filedescription%"
pause