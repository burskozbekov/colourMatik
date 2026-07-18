# colourMatik - install / repair the UXP panel in Premiere Pro (Windows).
#
# Premiere does NOT honour a hand-written PluginsInfo\v1\premierepro.json. That
# registry is owned by Adobe's agent, which ignores (or regenerates) hand edits -
# which is why copying the files and writing that JSON left the panel invisible
# even though everything on disk looked correct. Premiere loads a third-party UXP
# panel through exactly two supported paths:
#   1. Adobe's Unified Plugin Installer Agent (UPIA) - the same path a .ccx
#      double-click in Creative Cloud takes. No Adobe signing needed for a plain
#      HTML/JS panel. This is what we do.
#   2. Developer Mode ON + the panel in Plugins\External\<id>_<version>\ - our
#      fallback when Creative Cloud / UPIA isn't present.
#
# Safe to run standalone to repair an install:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install-panel.ps1
# by Sevki Bugra Ozbek - catheadai.com
$ErrorActionPreference = "Stop"

# --- find the panel source (next to this script, or the default install dir) --
# $MyInvocation.MyCommand.Path is $null under Invoke-Expression, so guard it.
$ScriptPath = $MyInvocation.MyCommand.Path
$cands = @()
if ($ScriptPath) { $cands += (Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptPath)) "colourmatik-uxp") }
$cands += (Join-Path $env:USERPROFILE "colourMatik\colourmatik-uxp")
$Src = $null
foreach ($c in $cands) {
    if ($c -and (Test-Path (Join-Path $c "manifest.json"))) { $Src = $c; break }
}
if (-not $Src) { throw "Couldn't find the colourMatik panel files. Re-run the colourMatik setup, then this." }

$mf        = Get-Content (Join-Path $Src "manifest.json") -Raw | ConvertFrom-Json
$PluginId  = $mf.id
$Version   = $mf.version
$PanelFiles = @("manifest.json", "index.html", "main.js")

# --- the .ccx: a FLAT zip of the panel (manifest.json at the archive root) -----
$Ccx = Join-Path $Src "colourMatik.ccx"
if (-not (Test-Path $Ccx)) {
    $zip = Join-Path $env:TEMP "colourMatik-panel.zip"
    if (Test-Path $zip) { Remove-Item -Force $zip }
    Compress-Archive -Path ($PanelFiles | ForEach-Object { Join-Path $Src $_ }) -DestinationPath $zip -Force
    $Ccx = Join-Path $env:TEMP "colourMatik.ccx"
    if (Test-Path $Ccx) { Remove-Item -Force $Ccx }
    Move-Item $zip $Ccx -Force
}

# --- install through Adobe's plugin agent (the supported path) ----------------
$upia = $null
foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $root) { continue }
    $p = Join-Path $root "Common Files\Adobe\Adobe Desktop Common\RemoteComponents\UPI\UnifiedPluginInstallerAgent\UnifiedPluginInstallerAgent.exe"
    if (Test-Path $p) { $upia = $p; break }
}

$installed = $false
if ($upia) {
    Write-Host "==> Installing the panel through Adobe's plugin agent..."
    # NOTE: on Windows UPIA takes /flags. The macOS form (--install) silently
    # no-ops here, which looks exactly like "the installer did nothing".
    $out = (& $upia /install $Ccx 2>&1 | Out-String).Trim()
    if ($out) { Write-Host $out }
    if ($out -match "(?i)success") { $installed = $true }
    if ($installed) {
        Write-Host ""
        Write-Host "colourMatik $Version installed."
        Write-Host "Now: fully quit and reopen Premiere Pro -> Window > UXP Plugins > colourMatik."
        & $upia /list all 2>&1 | Select-String -Pattern "colourMatik" | ForEach-Object { Write-Host "   $_" }
        return
    }
    Write-Host "    (the agent didn't confirm the install - falling back to developer mode)"
} else {
    Write-Host "==> Adobe's plugin agent isn't on this machine - using the developer-mode path."
}

# --- fallback: Plugins\External + Developer Mode -------------------------------
# Resolve the LOGGED-IN user's profile even when this runs elevated: under a
# different admin account $env:APPDATA is the admin's, not the person using
# Premiere, and the panel would land where their Premiere never looks.
$UserProfile = $env:USERPROFILE
try {
    $ex = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1
    if ($ex) {
        $owner = Invoke-CimMethod -InputObject $ex -MethodName GetOwner
        if ($owner.User) {
            $p = Join-Path (Join-Path $env:SystemDrive "Users") $owner.User
            if (Test-Path $p) { $UserProfile = $p }
        }
    }
} catch {}

# The folder MUST be <pluginId>_<manifest version> - Premiere keys on it.
$Ext    = Join-Path $UserProfile "AppData\Roaming\Adobe\UXP\Plugins\External"
$Folder = $PluginId + "_" + $Version
$Dest   = Join-Path $Ext $Folder
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
foreach ($f in $PanelFiles) { Copy-Item (Join-Path $Src $f) $Dest -Force }
# drop stale <pluginId>_<older version> copies
Get-ChildItem $Ext -Directory -Filter ($PluginId + "_*") -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne $Folder } |
    ForEach-Object { Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "colourMatik $Version placed in $Folder."
Write-Host "ONE manual step is needed for this path:"
Write-Host "   Premiere Pro > Settings > Plugins > tick 'Enable developer mode'"
Write-Host "   then fully quit and reopen Premiere -> Window > UXP Plugins > colourMatik."
