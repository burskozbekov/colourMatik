@echo off
rem colourMatik - run the engine in a visible console (for troubleshooting).
cd /d "%~dp0.."
echo colourMatik engine starting at http://127.0.0.1:8765  (Ctrl+C to stop)
".venv\Scripts\python.exe" -m colourmatik.webapp
pause
