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
    # -IncludeAgentCopies: also delete the agent's own PluginsStorage copies.
    # Only safe BEFORE installing. Calling it afterwards deleted the very files
    # the agent had just written, leaving a valid registration pointing at
    # nothing - files gone, panel missing from the UXP window.
    param([switch]$IncludeAgentCopies)
    # Adobe's plugin agent keeps ITS OWN copy under UXP\PluginsStorage\PPRO\
    # <version>\External\<id> — with NO version in the folder name — and
    # Premiere loads THAT one when it is registered. The 1.2.0 installed there
    # long ago survived every fix aimed at Plugins\External, which is exactly
    # why a fresh website install kept reporting 1.2.0. Remove it everywhere;
    # the agent reinstall (or the developer-mode copy) puts the current one back.
    # Machine-wide roots too: an ELEVATED agent install lands under Program
    # Files\Common Files\Adobe\UXP, which no per-user cleanup ever touched -
    # the last place an ancient panel could keep loading from. This script runs
    # elevated during Setup, so it CAN remove them.
    foreach ($pfBase in @($(if ($IncludeAgentCopies) { $env:ProgramFiles }), $(if ($IncludeAgentCopies) { ${env:ProgramFiles(x86)} }), $(if ($IncludeAgentCopies) { $env:ProgramData }))) {
        if (-not $pfBase) { continue }
        foreach ($sub in @("Common Files\Adobe\UXP", "Adobe\UXP")) {
            $mr = Join-Path $pfBase $sub
            if (-not (Test-Path $mr)) { continue }
            Get-ChildItem $mr -Recurse -Directory -Filter "com.colourmatik*" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne ("com.colourmatik.panel_" + $Version) } |
            ForEach-Object {
                Write-Host ("    removing machine-wide panel: " + $_.FullName)
                Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue
            }
        }
    }
    $storageRoot = Join-Path $UserProfile "AppData\Roaming\Adobe\UXP\PluginsStorage"
    if ($IncludeAgentCopies -and (Test-Path $storageRoot)) {
        Get-ChildItem $storageRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $stale = Join-Path $_.FullName "External\com.colourmatik.panel"
                if (Test-Path $stale) {
                    Write-Host ("    removing agent-installed panel: " + $stale)
                    Remove-Item -Recurse -Force $stale -ErrorAction SilentlyContinue
                }
            }
        }
    }
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
    # EVERY registry json, not just premierepro.json: the Premiere BETA keeps its
    # own file here, and a stale registration in it kept resurrecting 1.2.0 for
    # anyone opening the Beta.
    $regDir = Join-Path $UserProfile "AppData\Roaming\Adobe\UXP\PluginsInfo\v1"
    if (Test-Path $regDir) {
        Get-ChildItem $regDir -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
                if ($j.plugins) {
                    $keep = @($j.plugins | Where-Object {
                        -not ($_.pluginId -eq $PluginId -and $_.versionString -ne $Version)
                    })
                    if ($keep.Count -ne @($j.plugins).Count) {
                        Write-Host ("    removing stale registration(s) in " + $_.Name)
                        $j.plugins = $keep
                        # No BOM: Premiere refuses to parse this file with one.
                        [IO.File]::WriteAllText($_.FullName, ($j | ConvertTo-Json -Depth 10),
                                                (New-Object Text.UTF8Encoding $false))
                    }
                }
            } catch { Write-Warning ("Could not tidy " + $_.Name + " ($_).") }
        }
    }
}
Remove-StaleColourMatik -IncludeAgentCopies

# --- install through Adobe's plugin agent (the supported path) ----------------
$upia = $null
foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $root) { continue }
    $p = Join-Path $root "Common Files\Adobe\Adobe Desktop Common\RemoteComponents\UPI\UnifiedPluginInstallerAgent\UnifiedPluginInstallerAgent.exe"
    if (Test-Path $p) { $upia = $p; break }
}

$installed = $false
if ($upia) {
    # Ask the agent to forget any previous colourMatik first — its database is
    # the source Premiere trusts, and an old registration there outlives every
    # file we delete by hand.
    & $upia /remove com.colourmatik.panel 2>&1 | Select-String -Pattern "colourMatik|success|error" |
        ForEach-Object { Write-Host ("    " + $_) }
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
        # NOTE: no agent-copy purge here - that would delete what was just
        # installed. Only stale VERSIONED folders and registry rows are tidied.
        Remove-StaleColourMatik
        & $upia /list all 2>&1 | Select-String -Pattern "colourMatik" | ForEach-Object { Write-Host "   $_" }
        # Real verification: find a panel on disk whose OWN main.js reports the
        # version we just installed. "Agent said success" and "a folder exists"
        # both lied on real machines.
        $verified = $null
        $searchRoots = @((Join-Path $UserProfile "AppData\Roaming\Adobe\UXP\PluginsStorage"),
                         (Join-Path $UserProfile "AppData\Roaming\Adobe\UXP\Plugins\External"))
        foreach ($sr in $searchRoots) {
            if (-not (Test-Path $sr)) { continue }
            Get-ChildItem $sr -Recurse -Filter "main.js" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "com\.colourmatik" } | ForEach-Object {
                $mm = Select-String -Path $_.FullName -Pattern 'LOCAL_VERSION = "([^"]+)"' | Select-Object -First 1
                if ($mm -and $mm.Matches[0].Groups[1].Value -eq $Version) { $verified = $_.Directory.FullName }
            }
        }
        if ($verified) {
            Write-Host ("    agent installed -> " + $verified)
            # Do NOT return here: fall through so the files also land in the
            # developer-mode folder AND our own registry entry is written. The
            # agent's registration alone has proven fragile in the field (its
            # database can be cleared out from under us), and belt-and-braces
            # is what makes the macOS side never fail.
            $agentOk = $true
        } else {
            Write-Host "    (the agent reported success but no v$Version panel is on disk - installing it directly)"
        }
    }
    if (-not $installed) { Write-Host "    (the agent didn't confirm the install - installing directly)" }
} else {
    Write-Host "==> Adobe's plugin agent isn't on this machine - using the developer-mode path."
}

# --- always-works path: files + our own registry entry -------------------------
# The folder MUST be <pluginId>_<manifest version> - Premiere keys on it.
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
foreach ($f in $PanelFiles) { Copy-Item (Join-Path $Src $f) $Dest -Force }
Remove-StaleColourMatik

# Write the UXP registry entry ourselves. macOS has always done this, which is
# why the Mac panel never disappears; Windows trusted Adobe's agent alone, so
# whenever that registration was absent the panel vanished from the UXP window
# while its files sat right there on disk.
$regDir2 = Join-Path $UserProfile "AppData\Roaming\Adobe\UXP\PluginsInfo\v1"
if (-not (Test-Path $regDir2)) { New-Item -ItemType Directory -Force -Path $regDir2 | Out-Null }
$hostMin = "26.0"
try { if ($mf.host -and $mf.host.minVersion) { $hostMin = $mf.host.minVersion } } catch {}
$entry = [ordered]@{
    hostMinVersion = $hostMin
    name           = $(if ($mf.name) { $mf.name } else { "colourMatik" })
    path           = '$localPlugins/External/' + $Folder
    pluginId       = $PluginId
    status         = "enabled"
    type           = "uxp"
    versionString  = $Version
}
$regFile2 = Join-Path $regDir2 "premierepro.json"
if (-not (Test-Path $regFile2)) {
    [IO.File]::WriteAllText($regFile2, '{"plugins":[]}', (New-Object Text.UTF8Encoding $false))
}
try {
    $j2 = Get-Content $regFile2 -Raw | ConvertFrom-Json
    $keep2 = @()
    if ($j2.plugins) { $keep2 = @($j2.plugins | Where-Object { $_.pluginId -ne $PluginId }) }
    $keep2 += [pscustomobject]$entry
    $j2.plugins = $keep2
    [IO.File]::WriteAllText($regFile2, ($j2 | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
    Write-Host ("    registered -> " + $entry.path)
} catch { Write-Warning ("Could not write the UXP registry (" + $_.Exception.Message + ").") }

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
