; colourMatik - Windows Setup.exe (NSIS). One file, double-click, installs.
; Bootstrapper: downloads the latest colourMatik and runs the full installer
; (Python + ffmpeg + engine + AI + Premiere panel + native effect + autostart).
; by Sevki Bugra Ozbek - catheadai.com

Unicode true
Name "colourMatik"
OutFile "colourMatik-Setup.exe"
InstallDir "$LOCALAPPDATA\colourMatik"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
BrandingText "colourMatik  -  catheadai.com"

!include "MUI2.nsh"
!define MUI_ICON   "colourMatik.ico"
!define MUI_UNICON "colourMatik.ico"
!define MUI_WELCOMEPAGE_TITLE "Install colourMatik for Premiere Pro"
!define MUI_WELCOMEPAGE_TEXT  "This sets up colourMatik on your PC: the local engine + AI, the Premiere panel, and the native effect.$\r$\n$\r$\nIt downloads a few things the first time, so it can take 10-20 minutes. Just leave it running.$\r$\n$\r$\nClick Install to begin."
!define MUI_FINISHPAGE_TITLE  "colourMatik is installed"
!define MUI_FINISHPAGE_TEXT   "Restart Premiere Pro, then open  Window > UXP Plugins > colourMatik.$\r$\n$\r$\nPick a reference clip and a target clip, then Match and Apply."
!define MUI_FINISHPAGE_LINK   "catheadai.com"
!define MUI_FINISHPAGE_LINK_LOCATION "https://catheadai.com"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_LANGUAGE "English"

Section "colourMatik"
  SetDetailsPrint both
  DetailPrint "Preparing..."
  SetOutPath "$TEMP\colourMatik-setup"

  ; Write the bootstrap PowerShell to a file (avoids NSIS quoting issues).
  FileOpen $0 "$TEMP\colourMatik-setup\boot.ps1" w
  FileWrite $0 "$$ErrorActionPreference='Stop'$\r$\n"
  FileWrite $0 "Write-Host 'Downloading colourMatik...'$\r$\n"
  FileWrite $0 "$$z=Join-Path $$env:TEMP 'colourmatik-src.zip'$\r$\n"
  FileWrite $0 "Invoke-WebRequest 'https://github.com/burskozbekov/colourMatik/archive/refs/heads/main.zip' -OutFile $$z -UseBasicParsing$\r$\n"
  FileWrite $0 "$$d=Join-Path $$env:TEMP 'colourmatik-src'$\r$\n"
  FileWrite $0 "if(Test-Path $$d){Remove-Item -Recurse -Force $$d}$\r$\n"
  FileWrite $0 "Expand-Archive $$z $$d$\r$\n"
  FileWrite $0 "$$inner=Get-ChildItem $$d -Directory | Select-Object -First 1$\r$\n"
  FileWrite $0 "& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $$inner.FullName 'windows\install-windows.ps1')$\r$\n"
  FileClose $0

  DetailPrint "Installing colourMatik (Python, ffmpeg, engine + AI, panel, effect)..."
  DetailPrint "First run downloads a few GB - this can take 10-20 minutes. Please wait."
  nsExec::ExecToLog 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$TEMP\colourMatik-setup\boot.ps1"'
  Pop $1
  DetailPrint "Installer finished (code $1)."

  StrCmp $1 "0" ok fail
  fail:
    MessageBox MB_OK|MB_ICONEXCLAMATION "Something went wrong (code $1). Check your internet connection and run Setup again.$\r$\nManual: github.com/burskozbekov/colourMatik"
    Goto done
  ok:
    DetailPrint "Done. Restart Premiere Pro."
  done:
SectionEnd
