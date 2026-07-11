@echo off
rem =====================================================================
rem  colourMatik - one-file setup for Windows 10/11 (x64). Double-click me.
rem  Downloads the latest colourMatik and runs the full installer
rem  (Python + ffmpeg + engine + AI + Premiere panel + effect + autostart).
rem  by Sevki Bugra Ozbek - catheadai.com
rem =====================================================================
title colourMatik Setup
echo.
echo   +----------------------------------------------+
echo   ^|   colourMatik  -  Setup (Windows)            ^|
echo   ^|   downloading the latest version...          ^|
echo   +----------------------------------------------+
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$z=Join-Path $env:TEMP 'colourmatik-src.zip';" ^
  "Invoke-WebRequest 'https://github.com/burskozbekov/colourMatik/archive/refs/heads/main.zip' -OutFile $z -UseBasicParsing;" ^
  "$d=Join-Path $env:TEMP 'colourmatik-src';" ^
  "if(Test-Path $d){Remove-Item -Recurse -Force $d};" ^
  "Expand-Archive $z $d;" ^
  "$inner=Get-ChildItem $d -Directory | Select-Object -First 1;" ^
  "& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $inner.FullName 'windows\install-windows.ps1')"
if errorlevel 1 (
  echo.
  echo   Something went wrong. Check your internet connection and try again.
  echo   Manual install: github.com/burskozbekov/colourMatik  -^> windows\install-windows.cmd
)
echo.
pause
