# colourMatik - install / repair the UXP panel in Premiere Pro (Windows).
#
# How Premiere ACTUALLY finds third-party UXP panels (field-diagnosed from
# Premiere's own UXPLogs on a machine where the panel refused to appear):
#   1. The SYSTEM PluginsInfo registry:
#        C:\Program Files\Common Files\Adobe\UXP\PluginsInfo\v1\premierepro.json
#      written by Adobe's Unified Plugin Installer Agent (UPIA) when a .ccx is
#      installed elevated. Entries use the token $systemPlugins, which resolves
#      to C:\Program Files\Common Files\Adobe\UXP\Plugins. Premiere loads this
#      FIRST, and an entry here claims the plugin id outright - even when its
#      folder no longer exists ("failed to create/initialize plugin", and the
#      same id is then never scanned anywhere else). That stale claim is how
#      the panel stayed invisible for weeks while every fix rewrote the
#      per-user registry below.
#   2. The per-user %APPDATA%\Adobe\UXP\PluginsInfo\v1\premierepro.json - read
#      afterwards; contributes nothing for an id already claimed at system
#      level (Premiere logs "Number of plugins added from user's pluginsInfo: 0").
#   3. Developer Mode ON + the panel in Plugins\External\<id>_<version>\ - the
#      last-resort path when neither registration exists.
# So: install through UPIA when it is present; when we are elevated and UPIA
# fails, write the SYSTEM registration ourselves exactly the way UPIA would.
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
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Machine-level UXP roots. UPIA registers panels in the SYSTEM PluginsInfo file
# under these roots, and Premiere trusts that file before anything per-user.
$SysUxpRoots = @()
foreach ($pfBase in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
    if (-not $pfBase) { continue }
    foreach ($sub in @("Common Files\Adobe\UXP", "Adobe\UXP")) {
        $r = Join-Path $pfBase $sub
        if (Test-Path $r) { $SysUxpRoots += $r }
    }
}

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
    # The SYSTEM PluginsInfo registry too. A stale row for our plugin id there
    # (pointing at a deleted folder) claims the id and blocks EVERY later copy
    # of the panel, per-user and dev-mode alike - Premiere logs "failed to
    # create/initialize" and never rescans that id. This is the registry that
    # was never cleaned in weeks of per-user fixes. Writable when elevated;
    # a plain try/catch keeps non-elevated repair runs harmless.
    foreach ($sysRoot in $script:SysUxpRoots) {
        $sysReg = Join-Path $sysRoot "PluginsInfo\v1"
        if (-not (Test-Path $sysReg)) { continue }
        Get-ChildItem $sysReg -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
                if ($j.plugins) {
                    $keep = @($j.plugins | Where-Object {
                        -not ($_.pluginId -eq $PluginId -and $_.versionString -ne $Version)
                    })
                    if ($keep.Count -ne @($j.plugins).Count) {
                        Write-Host ("    removing stale SYSTEM registration(s) in " + $_.FullName)
                        $j.plugins = $keep
                        # Compact JSON without BOM - byte-for-byte the style UPIA writes.
                        [IO.File]::WriteAllText($_.FullName, ($j | ConvertTo-Json -Depth 10 -Compress),
                                                (New-Object Text.UTF8Encoding $false))
                    }
                }
            } catch { Write-Warning ("Could not tidy SYSTEM " + $_.Name + " ($_ )- run elevated to clean it.") }
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

function Invoke-Upia {
    # ALWAYS run the agent with its working directory on the system drive.
    # UPIA resolves the user profile drive-relatively ("\Users\<name>\..."
    # without "C:"), so when it is launched from another drive - say a
    # D:\Downloads folder, exactly where people run Setup.exe from - every
    # install fails with status -198 ("Adobe folder neither exist, nor have
    # the permission to create \Users\...") while the identical command
    # succeeds from C:\. Field-diagnosed; this wrapper is not optional.
    param([string[]]$UpiaArgs)
    Push-Location ($env:SystemDrive + "\")
    try { return (& $upia @UpiaArgs 2>&1 | Out-String) } finally { Pop-Location }
}

# An elevated cleanup/debug session can leave %APPDATA%\Adobe\UXP or ...\UPI
# owned by BUILTIN\Administrators. UPIA validates folder OWNERSHIP
# (createDirectoriesWithOwnership) and refuses every install with -198 until
# the folders belong to the user again. Hand them back before calling it.
if ($IsElevated) {
    $ownerUser = Split-Path $UserProfile -Leaf
    foreach ($own in @("AppData\Roaming\Adobe\UXP", "AppData\Roaming\Adobe\UPI")) {
        $p = Join-Path $UserProfile $own
        if (-not (Test-Path $p)) { continue }
        try {
            $curOwner = (Get-Acl $p).Owner
            if ($curOwner -notlike ("*\" + $ownerUser)) {
                icacls $p /setowner $ownerUser /T /C /Q 2>&1 | Out-Null
                Write-Host ("    returned ownership of " + $p + " to " + $ownerUser + " (was " + $curOwner + ")")
            }
        } catch {}
    }
}

$installed = $false
$agentOk = $false
if ($upia) {
    # Ask the agent to forget any previous colourMatik first — its database is
    # the source Premiere trusts, and an old registration there outlives every
    # file we delete by hand.
    # NOTE: /remove takes the extension NAME as shown by /list ("colourMatik"),
    # NOT the plugin id - the id form fails with status -406 and the stale
    # registration silently survives. Field-diagnosed. Name first, id second.
    foreach ($rmArg in @($(if ($mf.name) { $mf.name } else { "colourMatik" }), $PluginId)) {
        $rmOut = (Invoke-Upia @("/remove", $rmArg)).Trim()
        if ($rmOut) { Write-Host ("    agent /remove " + $rmArg + ": " + (($rmOut -split "`r?`n") | Select-Object -Last 1)) }
        if ($rmOut -match "(?i)successful") { break }
    }
    Write-Host "==> Installing the panel through Adobe's plugin agent..."
    # NOTE: on Windows UPIA takes /flags. The macOS form (--install) silently
    # no-ops here, which looks exactly like "the installer did nothing".
    $out = (Invoke-Upia @("/install", $Ccx)).Trim()
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
        (Invoke-Upia @("/list", "all")) -split "`r?`n" | Select-String -Pattern "colourMatik" | ForEach-Object { Write-Host "   $_" }
        # Real verification: find a panel on disk whose OWN main.js reports the
        # version we just installed. "Agent said success" and "a folder exists"
        # both lied on real machines.
        $verified = $null
        # Include the machine-wide root: an elevated agent install ("for all
        # users") puts the files under Program Files\Common Files\Adobe\UXP,
        # NOT in the per-user folders - without this the check called a
        # perfectly good install a failure.
        $searchRoots = @((Join-Path $UserProfile "AppData\Roaming\Adobe\UXP\PluginsStorage"),
                         (Join-Path $UserProfile "AppData\Roaming\Adobe\UXP\Plugins\External"))
        foreach ($sysRoot in $SysUxpRoots) { $searchRoots += (Join-Path $sysRoot "Plugins\External") }
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
    if (-not $installed) {
        Write-Host "    (the agent didn't confirm the install - installing directly)"
        if ($out -match "-198") {
            Write-Host "    (status -198 usually means wrong folder ownership on %APPDATA%\Adobe\UXP or"
            Write-Host "     the agent was started from a non-system drive; both are pre-handled above,"
            Write-Host "     so if it persists run windows\diag.ps1 and send the report)"
        }
    }
} else {
    Write-Host "==> Adobe's plugin agent isn't on this machine - using the developer-mode path."
}

# --- always-works path: files + our own registry entry -------------------------
# The folder MUST be <pluginId>_<manifest version> - Premiere keys on it.
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
foreach ($f in $PanelFiles) { Copy-Item (Join-Path $Src $f) $Dest -Force }
Remove-StaleColourMatik

# When we are elevated and the agent did not do it, mirror EXACTLY what a
# successful agent install writes: files in the machine-wide Plugins\External
# and a row in the SYSTEM PluginsInfo registry (token $systemPlugins with
# backslashes - copied verbatim from a working agent-written entry). This is
# the registration Premiere provably loads; the per-user entry further below
# is only belt-and-braces (Premiere reads it but adds 0 plugins from it when
# the id is claimed at system level).
$hostMin = "26.0"
try { if ($mf.host -and $mf.host.minVersion) { $hostMin = $mf.host.minVersion } } catch {}
if ($IsElevated -and -not $agentOk) {
    try {
        $sysPlugRoot = Join-Path $env:ProgramFiles "Common Files\Adobe\UXP"
        $sysDest = Join-Path $sysPlugRoot ("Plugins\External\" + $Folder)
        New-Item -ItemType Directory -Force -Path $sysDest | Out-Null
        foreach ($f in $PanelFiles) { Copy-Item (Join-Path $Src $f) $sysDest -Force }
        $sysRegDir = Join-Path $sysPlugRoot "PluginsInfo\v1"
        if (-not (Test-Path $sysRegDir)) { New-Item -ItemType Directory -Force -Path $sysRegDir | Out-Null }
        $sysRegFile = Join-Path $sysRegDir "premierepro.json"
        if (-not (Test-Path $sysRegFile)) {
            [IO.File]::WriteAllText($sysRegFile, '{"plugins":[]}', (New-Object Text.UTF8Encoding $false))
        }
        $sj = Get-Content $sysRegFile -Raw | ConvertFrom-Json
        $skeep = @()
        if ($sj.plugins) { $skeep = @($sj.plugins | Where-Object { $_.pluginId -ne $PluginId }) }
        $skeep += [pscustomobject][ordered]@{
            hostMinVersion = $hostMin
            name           = $(if ($mf.name) { $mf.name } else { "colourMatik" })
            path           = ('$systemPlugins\External\' + $Folder)
            pluginId       = $PluginId
            status         = "enabled"
            type           = "uxp"
            versionString  = $Version
        }
        $sj.plugins = $skeep
        # Compact, no BOM - byte-for-byte the style the agent writes.
        [IO.File]::WriteAllText($sysRegFile, ($sj | ConvertTo-Json -Depth 10 -Compress), (New-Object Text.UTF8Encoding $false))
        Write-Host ("    registered SYSTEM-level -> " + '$systemPlugins\External\' + $Folder)
        $agentOk = $true   # same net effect: the panel shows with no developer-mode toggle
    } catch { Write-Warning ("Could not write the SYSTEM registration (" + $_.Exception.Message + ").") }
}

# Write the per-user UXP registry entry as well. macOS has always done this,
# which is why the Mac panel never disappears; on Windows it is a last resort
# for non-elevated repair runs.
$regDir2 = Join-Path $UserProfile "AppData\Roaming\Adobe\UXP\PluginsInfo\v1"
if (-not (Test-Path $regDir2)) { New-Item -ItemType Directory -Force -Path $regDir2 | Out-Null }
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
if ($agentOk) {
    # Adobe's agent registered it: Premiere shows the panel with no toggles.
    Write-Host "colourMatik $Version is installed and registered."
    Write-Host "Quit Premiere Pro completely and open it again -> Window > UXP Plugins > colourMatik."
} else {
    Write-Host "colourMatik $Version placed in $Folder."
    Write-Host "If the panel does not appear after restarting Premiere, turn this on once:"
    Write-Host "   Premiere Pro > Settings > Plugins > tick 'Enable developer mode'"
    Write-Host "   then fully quit and reopen Premiere -> Window > UXP Plugins > colourMatik."
}

# Say out loud what is actually on disk, so "it still says 1.2.0" can never be a
# mystery again.
Write-Host ""
Write-Host "--- installed panels for this user ---"
Get-ChildItem $Ext -Directory -Filter ($PluginId + "_*") -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host ("   " + $_.Name) }
if (-not (Test-Path $Dest)) { throw "The panel was not installed into $Dest." }
