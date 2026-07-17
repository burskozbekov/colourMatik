# colourMatik — one-click installer for Windows 10/11 (x64).
# Run via install-windows.cmd (double-click) for the full install, or with
# -Phase <name> to run one stage (used by colourMatik-Setup.exe so its progress
# bar can advance stage by stage): prereqs | code | engine | panel | effect | autostart
# by Sevki Bugra Ozbek - catheadai.com
param([string]$Phase = "all")
$ErrorActionPreference = "Stop"
$Repo = "https://github.com/burskozbekov/colourMatik.git"

if ($Phase -eq "all") {
    Write-Host ""
    Write-Host "  +----------------------------------------------+"
    Write-Host "  |   colourMatik  -  installer (Windows)        |"
    Write-Host "  |   Sevki Bugra Ozbek | catheadai.com          |"
    Write-Host "  +----------------------------------------------+"
    Write-Host ""

    # --- self-elevate (the effect goes into Program Files) -------------------
    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $IsAdmin) {
        Write-Host "==> Requesting administrator rights (for the Premiere plug-ins folder)..."
        Start-Process powershell -Verb RunAs -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$($MyInvocation.MyCommand.Path)`"")
        exit 0
    }
}

# --- where the code lives (same rule for every phase) -------------------------
$Self = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $Self
if (Test-Path (Join-Path $Root ".git")) { $InstallDir = $Root }   # real checkout -> in place
else { $InstallDir = Join-Path $env:USERPROFILE "colourMatik" }

function Phase-Prereqs {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget (App Installer) is required. Install 'App Installer' from the Microsoft Store, then re-run."
    }
    Write-Host "==> Installing prerequisites (Python 3.11, git, ffmpeg)..."
    foreach ($id in @("Python.Python.3.11", "Git.Git", "Gyan.FFmpeg")) {
        winget install -e --id $id --accept-source-agreements --accept-package-agreements 2>$null | Out-Null
    }
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
}

function Phase-Code {
    if ($InstallDir -eq $Root) { Write-Host "==> Using colourMatik in: $InstallDir"; return }
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
    if (Test-Path (Join-Path $InstallDir ".git")) {
        Write-Host "==> Updating colourMatik..."; git -C $InstallDir pull --ff-only
    } else {
        Write-Host "==> Downloading colourMatik to $InstallDir..."
        git clone --depth 1 $Repo $InstallDir
    }
}

function Phase-Engine {
    Set-Location $InstallDir
    Write-Host "==> Setting up the engine + AI (a few GB; 10-20 minutes on first run)"
    powershell -NoProfile -ExecutionPolicy Bypass -File "$InstallDir\windows\setup.ps1"
    if ($LASTEXITCODE -ne 0) { throw "engine setup failed" }
}

function Phase-Panel {
    Write-Host "==> Installing the Premiere panel..."
    powershell -NoProfile -ExecutionPolicy Bypass -File "$InstallDir\windows\install-panel.ps1"
}

function Phase-Effect {
    Write-Host "==> Installing the colourMatik effect..."
    try {
        powershell -NoProfile -ExecutionPolicy Bypass -File "$InstallDir\windows\install-effect.ps1"
    } catch {
        Write-Warning "Effect install failed ($_). You can re-run windows\install-effect.ps1 later."
    }
}

function Phase-Autostart {
    Write-Host "==> Making the engine start automatically at login..."
    $Startup = [Environment]::GetFolderPath("Startup")
    $Ws = New-Object -ComObject WScript.Shell
    $Lnk = $Ws.CreateShortcut((Join-Path $Startup "colourMatik Engine.lnk"))
    $Lnk.TargetPath = Join-Path $InstallDir "windows\engine-hidden.vbs"
    $Lnk.WorkingDirectory = $InstallDir
    $Lnk.Save()
    # start it now, silently
    Start-Process wscript -ArgumentList "`"$InstallDir\windows\engine-hidden.vbs`"" -WindowStyle Hidden
}

switch ($Phase) {
    "prereqs"   { Phase-Prereqs }
    "code"      { Phase-Code }
    "engine"    { Phase-Engine }
    "panel"     { Phase-Panel }
    "effect"    { Phase-Effect }
    "autostart" { Phase-Autostart }
    "all" {
        Phase-Prereqs
        Phase-Code
        # Install the quick, reliable UI parts (panel + effect) BEFORE the slow,
        # network-heavy engine/AI download, and never let a failure in one stop the
        # rest — a flaky connection during the multi-GB model download must not
        # leave the user with no panel.
        try { Phase-Panel }  catch { Write-Warning "Panel install issue ($_) - re-run windows\install-panel.ps1." }
        Phase-Effect
        try { Phase-Engine } catch { Write-Warning "Engine/AI setup didn't finish ($_). The panel + effect ARE installed; re-run Setup to finish the engine download." }
        Phase-Autostart
        Write-Host ""
        Write-Host "==> All done!"
        Write-Host "    Final step: RESTART Premiere Pro, then open  Window > UXP Plugins > colourMatik."
        Write-Host "    Pick a REFERENCE clip and a TARGET clip, choose Accurate or Cinematic AI, and Match & Apply."
        Write-Host ""
        if ([Environment]::UserInteractive -and -not $env:COLOURMATIK_SILENT) {
            try { Read-Host "Press Enter to close" } catch {}
        }
    }
    default { throw "Unknown -Phase '$Phase'" }
}
