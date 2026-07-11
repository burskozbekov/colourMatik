@echo off
rem colourMatik - update to the latest version (Windows). Double-click me.
cd /d "%~dp0.."
echo ==^> Updating colourMatik...
git pull --ff-only || echo Could not pull updates (local changes?).
echo ==^> Refreshing engine + AI...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
echo ==^> Reinstalling panel + effect...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-panel.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-effect.ps1"
echo ==^> Restarting the engine...
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'colourmatik.webapp' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
start "" wscript "%~dp0engine-hidden.vbs"
echo ==^> Updated. Restart Premiere Pro.
pause
