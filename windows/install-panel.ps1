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
# Every panel asset — the chameleon frames (cham*.png) ship alongside the three
# core files and the progress bar is blank without them.
$PanelFiles = @("manifest.json", "index.html", "main.js") +
              (Get-ChildItem (Join-Path $Src "cham*.png") -ErrorAction SilentlyContinue |
               ForEach-Object { $_.Name })

# --- the .ccx: a FLAT zip of the panel (manifest.json at the archive root) -----
# ALWAYS rebuild from the loose files. Trusting a committed colourMatik.ccx
# meant that forgetting to re-zip it after a panel change shipped Windows an
# OLD panel while macOS (which copies loose files) got the new one — installs
# that looked like they had silently reverted.
$Ccx = $null
if ($true) {
    $zip = Join-Path $env:TEMP "colourMatik-panel.zip"
    if (Test-Path $zip) { Remove-Item -Force $zip }
    Compress-Archive -Path ($PanelFiles | ForEach-Object { Join-Path $Src $_ }) -DestinationPath $zip -Force
    $Ccx = Join-Path $env:TEMP "colourMatik.ccx"
    if (Test-Path $Ccx) { Remove-Item -Force $Ccx }
    Move-Item $zip $Ccx -Force
}

# --- resolve the LOGGED-IN user's UXP folder FIRST ----------------------------
# Needed before anything else: stale copies of older versions must be removed on
# EVERY path, and when this script runs elevated under a different admin account
# $env:APPDATA is the admin's, not the person actually using Premiere.
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
$Ext    = Join-Path $UserProfile "AppData\Roaming\Adobe\UXP\Plugins\External"
$Folder = $PluginId + "_" + $Version
$Dest   = Join-Path $Ext $Folder

function Remove-StaleColourMatik {
    # THE bug behind "I reinstalled and it still says 1.2.0": an older
    # <pluginId>_<version> folder, and its entry in Premiere's UXP registry,
    # survived every reinstall. Adobe's agent installs the new build elsewhere,
    # Premiere keeps loading the old registered folder, and the panel reports the
    # old version forever. Both must go, on every install path.
    Get-ChildItem $Ext -Directory -Filter ($PluginId + "_*") -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $Folder } |
        ForEach-Object {
            Write-Host ("    removing stale panel: " + $_.Name)
            Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue
        }
    $reg = Join-Path $UserProfile "AppData\Roaming\Adobe\UXP\PluginsInfo\v1\premierepro.json"
    if (Test-Path $reg) {
        try {
            $j = Get-Content $reg -Raw | ConvertFrom-Json
            if ($j.plugins) {
                $keep = @($j.plugins | Where-Object {
                    -not ($_.pluginId -eq $PluginId -and $_.versionString -ne $Version)
                })
                if ($keep.Count -ne @($j.plugins).Count) {
                    Write-Host "    removing stale panel registration(s)"
                    $j.plugins = $keep
                    # No BOM: Premiere refuses to parse this file with one.
                    [IO.File]::WriteAllText($reg, ($j | ConvertTo-Json -Depth 10),
                                            (New-Object Text.UTF8Encoding $false))
                }
            }
        } catch { Write-Warning "Could not tidy the UXP registry ($_)." }
    }
}
Remove-StaleColourMatik

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
        # "Success" from the agent is not proof the panel reached THIS user: when
        # the installer is elevated with another account's credentials the agent
        # writes into that admin's profile. Verify, tidy again, and fall through
        # to the manual copy if the folder is not where Premiere will look.
        Remove-StaleColourMatik
        & $upia /list all 2>&1 | Select-String -Pattern "colourMatik" | ForEach-Object { Write-Host "   $_" }
        if (Test-Path $Dest) {
            Write-Host ""
            Write-Host "colourMatik $Version installed -> $Dest"
            Write-Host "Now: fully quit and reopen Premiere Pro -> Window > UXP Plugins > colourMatik."
            return
        }
        Write-Host "    (the agent reported success but the panel is not in this user's profile - installing it directly)"
    }
    Write-Host "    (the agent didn't confirm the install - falling back to developer mode)"
} else {
    Write-Host "==> Adobe's plugin agent isn't on this machine - using the developer-mode path."
}

# --- fallback: Plugins\External + Developer Mode -------------------------------
# The folder MUST be <pluginId>_<manifest version> - Premiere keys on it.
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
foreach ($f in $PanelFiles) { Copy-Item (Join-Path $Src $f) $Dest -Force }
Remove-StaleColourMatik

Write-Host ""
Write-Host "colourMatik $Version placed in $Folder."
Write-Host "ONE manual step is needed for this path:"
Write-Host "   Premiere Pro > Settings > Plugins > tick 'Enable developer mode'"
Write-Host "   then fully quit and reopen Premiere -> Window > UXP Plugins > colourMatik."

# Say out loud what is actually on disk, so "it still says 1.2.0" can never be a
# mystery again.
Write-Host ""
Write-Host "--- installed panels for this user ---"
Get-ChildItem $Ext -Directory -Filter ($PluginId + "_*") -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host ("   " + $_.Name) }
if (-not (Test-Path $Dest)) { throw "The panel was not installed into $Dest." }
