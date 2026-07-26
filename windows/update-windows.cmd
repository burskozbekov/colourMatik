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
rem Re-exec from a copy: the refresh below overwrites this very file, and cmd.exe
rem keeps reading the script by BYTE OFFSET — replacing it mid-run makes the
rem interpreter resume at a meaningless position in the new bytes.
if not "%CMK_RELAUNCHED%"=="1" (
  copy /y "%~f0" "%TEMP%\cmk-update-run.cmd" >nul 2>&1
  set "CMK_RELAUNCHED=1"
  set "CMK_HOME=%~dp0"
  call "%TEMP%\cmk-update-run.cmd" %*
  exit /b
)
cd /d "%CMK_HOME%.."
rem The panel shows a live bar by polling this file through the engine.
set "CMKPROG=%APPDATA%\colourMatik\update_progress"
if not exist "%APPDATA%\colourMatik" mkdir "%APPDATA%\colourMatik" >nul 2>&1
<nul set /p "=5|Downloading the newest colourMatik" > "%CMKPROG%" 2>nul
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
if not defined CMKGOT powershell -NoProfile -ExecutionPolicy Bypass -File "%CMK_HOME%fetch-latest.ps1" -Dest "%CD%"

<nul set /p "=25|Refreshing the engine" > "%CMKPROG%" 2>nul
echo ==^> Refreshing engine + AI...
powershell -NoProfile -ExecutionPolicy Bypass -File "%CMK_HOME%setup.ps1"
<nul set /p "=75|Reinstalling the panel" > "%CMKPROG%" 2>nul
echo ==^> Reinstalling panel + effect...
powershell -NoProfile -ExecutionPolicy Bypass -File "%CMK_HOME%install-panel.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%CMK_HOME%install-effect.ps1"
rem The AE panel is per-user and needs no admin. install-effect.ps1 can die on a
rem locked colourMatik.aex while Premiere is open and never reach its CEP step,
rem so refresh it here directly — same guarantee the macOS updater added.
if exist "colourmatik-cep" (
  if not exist "%APPDATA%\Adobe\CEP\extensions\com.catheadai.colourmatik" mkdir "%APPDATA%\Adobe\CEP\extensions\com.catheadai.colourmatik" >nul 2>&1
  xcopy /e /y /i /q "colourmatik-cep\*" "%APPDATA%\Adobe\CEP\extensions\com.catheadai.colourmatik\" >nul 2>&1
)
<nul set /p "=92|Restarting the engine" > "%CMKPROG%" 2>nul
echo ==^> Restarting the engine...
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'colourmatik.webapp' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
start "" wscript "%CMK_HOME%engine-hidden.vbs"
<nul set /p "=100|Done" > "%CMKPROG%" 2>nul
echo ==^> Updated. Restart Premiere Pro.
if not "%~1"=="/silent" pause
