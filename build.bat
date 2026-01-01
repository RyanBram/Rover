@echo off
echo ================================================
echo   Building Rover
echo ================================================
ECHO "Choose your build type"
ECHO 1. debug
ECHO 2. release
SET srcdir=%~dp0src
SET /p buildtype= "Type: "

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
pause
