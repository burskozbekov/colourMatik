# colourMatik — one-click installer for Windows 10/11 (x64).
# Run via install-windows.cmd (double-click). Installs prerequisites, the engine + AI,
# the Premiere panel, the native effect, and auto-starts the engine at login.
# by Sevki Bugra Ozbek - catheadai.com
$ErrorActionPreference = "Stop"
$Repo = "https://github.com/burskozbekov/colourMatik.git"

Write-Host ""
Write-Host "  +----------------------------------------------+"
Write-Host "  |   colourMatik  -  installer (Windows)        |"
Write-Host "  |   Sevki Bugra Ozbek | catheadai.com          |"
Write-Host "  +----------------------------------------------+"
Write-Host ""

# --- self-elevate (the effect goes into Program Files) -----------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Host "==> Requesting administrator rights (for the Premiere plug-ins folder)..."
    Start-Process powershell -Verb RunAs -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$($MyInvocation.MyCommand.Path)`"")
    exit 0
}

# --- prerequisites via winget -------------------------------------------------
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget (App Installer) is required. Install 'App Installer' from the Microsoft Store, then re-run."
}
Write-Host "==> Installing prerequisites (Python 3.11, git, ffmpeg)..."
foreach ($id in @("Python.Python.3.11", "Git.Git", "Gyan.FFmpeg")) {
    winget install -e --id $id --accept-source-agreements --accept-package-agreements 2>$null | Out-Null
}
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
            [Environment]::GetEnvironmentVariable("Path", "User")

# --- get the code (use this checkout if the script sits inside it) ------------
$Self = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $Self
if (Test-Path (Join-Path $Root ".git")) {      # a real checkout -> use in place (updatable)
    $InstallDir = $Root
    Write-Host "==> Using colourMatik in: $InstallDir"
} else {
    $InstallDir = Join-Path $env:USERPROFILE "colourMatik"
    if (Test-Path (Join-Path $InstallDir ".git")) {
        Write-Host "==> Updating colourMatik..."; git -C $InstallDir pull --ff-only
    } else {
        Write-Host "==> Downloading colourMatik to $InstallDir..."
        git clone --depth 1 $Repo $InstallDir
    }
}
Set-Location $InstallDir

# --- engine + AI ---------------------------------------------------------------
Write-Host "==> Setting up the engine + AI (a few GB; 10-20 minutes on first run)"
powershell -NoProfile -ExecutionPolicy Bypass -File "$InstallDir\windows\setup.ps1"

# --- panel + effect -------------------------------------------------------------
Write-Host "==> Installing the Premiere panel..."
powershell -NoProfile -ExecutionPolicy Bypass -File "$InstallDir\windows\install-panel.ps1"
Write-Host "==> Installing the colourMatik effect..."
try {
    powershell -NoProfile -ExecutionPolicy Bypass -File "$InstallDir\windows\install-effect.ps1"
} catch {
    Write-Warning "Effect install failed ($_). You can re-run windows\install-effect.ps1 later."
}

# --- engine autostart (per-user Startup shortcut) --------------------------------
Write-Host "==> Making the engine start automatically at login..."
$Startup = [Environment]::GetFolderPath("Startup")
$Ws = New-Object -ComObject WScript.Shell
$Lnk = $Ws.CreateShortcut((Join-Path $Startup "colourMatik Engine.lnk"))
$Lnk.TargetPath = Join-Path $InstallDir "windows\engine-hidden.vbs"
$Lnk.WorkingDirectory = $InstallDir
$Lnk.Save()
# start it now, silently
Start-Process wscript -ArgumentList "`"$InstallDir\windows\engine-hidden.vbs`"" -WindowStyle Hidden

Write-Host ""
Write-Host "==> All done!"
Write-Host "    Final step: RESTART Premiere Pro, then open  Window > UXP Plugins > colourMatik."
Write-Host "    Pick a REFERENCE clip and a TARGET clip, choose Accurate or Cinematic AI, and Match & Apply."
Write-Host ""
Read-Host "Press Enter to close"
