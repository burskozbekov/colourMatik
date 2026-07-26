@echo off
rem colourMatik - update to the latest version (Windows). Double-click me.
rem Self-elevates: the panel (Adobe plugin agent) and the effect (Program Files)
rem both need admin; without it those steps quietly fell over and the machine
rem looked like it "never got the update".
net session >nul 2>&1
if errorlevel 1 (
  echo ==^> Requesting administrator rights...
  if "%~1"=="/silent" (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '/silent' -Verb RunAs -WindowStyle Hidden"
  ) else (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  )
  exit /b
)
cd /d "%~dp0.."
rem The panel shows a live bar by polling this file through the engine.
set "CMKPROG=%APPDATA%\colourMatik\update_progress"
if not exist "%APPDATA%\colourMatik" mkdir "%APPDATA%\colourMatik" >nul 2>&1
<nul set /p="5|Downloading the newest colourMatik" > "%CMKPROG%" 2>nul
echo ==^> Updating colourMatik...
rem Fetch the newest code. A Setup-made install is only a git checkout when git
rem was on the machine; on every other PC there is no .git, so a bare "git pull"
rem fetched NOTHING and the update then ran over the same old code - the bar
rem filled and the version never moved. Fall back to the source zip, exactly
rem like the macOS updater does. The download lives in its own .ps1 so no
rem PowerShell parentheses are ever echoed inside a batch block.
set "CMKGOT="
if exist ".git" (
  git pull --ff-only
  if not errorlevel 1 set "CMKGOT=1"
)
if not defined CMKGOT powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fetch-latest.ps1" -Dest "%CD%"

<nul set /p="25|Refreshing the engine" > "%CMKPROG%" 2>nul
echo ==^> Refreshing engine + AI...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
<nul set /p="75|Reinstalling the panel" > "%CMKPROG%" 2>nul
echo ==^> Reinstalling panel + effect...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-panel.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-effect.ps1"
<nul set /p="92|Restarting the engine" > "%CMKPROG%" 2>nul
echo ==^> Restarting the engine...
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'colourmatik.webapp' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
start "" wscript "%~dp0engine-hidden.vbs"
<nul set /p="100|Done" > "%CMKPROG%" 2>nul
echo ==^> Updated. Restart Premiere Pro.
if not "%~1"=="/silent" pause
