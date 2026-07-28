# colourMatik - one-paste diagnostic + repair (Windows).
#   Win+R -> powershell -> paste:
#   irm https://raw.githubusercontent.com/burskozbekov/colourMatik/main/windows/diag.ps1 | iex
# Prints where every copy of the panel lives and what version it is, removes
# stale ones, installs the current panel, and leaves a report on the Desktop.
# ASCII-only on purpose: PowerShell 5.1 mangles non-ASCII piped through iex.

$ErrorActionPreference = "Continue"
$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { Write-Host $s; $lines.Add($s) | Out-Null }

Say "=== colourMatik DIAG $(Get-Date -Format s) ==="

# -- engine ---------------------------------------------------------------
try {
    $v = (Invoke-RestMethod "http://127.0.0.1:8765/version" -TimeoutSec 3).version
    Say ("engine        : " + $v)
} catch { Say "engine        : NOT RUNNING" }

# -- install dir ----------------------------------------------------------
$inst = Join-Path $env:USERPROFILE "colourMatik"
if (Test-Path (Join-Path $inst "version.json")) {
    $iv = (Get-Content (Join-Path $inst "version.json") -Raw | ConvertFrom-Json).version
    Say ("install dir   : " + $inst + "  version " + $iv)
} else { Say ("install dir   : " + $inst + "  (no version.json)") }

# -- every panel copy on this machine --------------------------------------
$uxp = Join-Path $env:APPDATA "Adobe\UXP"
# Machine-wide UXP roots: when the agent runs ELEVATED it installs here, and no
# per-user cleanup ever touches them - the last hiding place a 1.2.0 can live.
$machineRoots = @()
foreach ($pfBase in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
    if (-not $pfBase) { continue }
    foreach ($sub in @("Common Files\Adobe\UXP\PluginsStorage", "Common Files\Adobe\UXP\Plugins\External", "Adobe\UXP\PluginsStorage", "Adobe\UXP\Plugins\External")) {
        $mr = Join-Path $pfBase $sub
        if (Test-Path $mr) { $machineRoots += $mr }
    }
}
Say "--- panel copies ---"
$found = @()
foreach ($root in (@((Join-Path $uxp "Plugins\External"), (Join-Path $uxp "PluginsStorage")) + $machineRoots)) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -Recurse -Directory -Filter "com.colourmatik*" -ErrorAction SilentlyContinue |
    ForEach-Object {
        $mj = Join-Path $_.FullName "main.js"
        $ver = "?"
        if (Test-Path $mj) {
            $m = Select-String -Path $mj -Pattern 'LOCAL_VERSION = "([^"]+)"' | Select-Object -First 1
            if ($m) { $ver = $m.Matches[0].Groups[1].Value }
        }
        Say ("  " + $_.FullName.Replace($env:APPDATA, "%APPDATA%") + "  -> v" + $ver)
        $found += $_
    }
}
if (-not $found) { Say "  (none found)" }

# -- every UXP registry file ------------------------------------------------
Say "--- UXP registries ---"
$regDir = Join-Path $uxp "PluginsInfo\v1"
if (Test-Path $regDir) {
    Get-ChildItem $regDir -Filter "*.json" | ForEach-Object {
        try {
            $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $ours = @($j.plugins | Where-Object { $_.pluginId -like "com.colourmatik*" })
            foreach ($p in $ours) { Say ("  " + $_.Name + " : " + $p.pluginId + " v" + $p.versionString + " path=" + $p.path) }
            if (-not $ours) { Say ("  " + $_.Name + " : no colourMatik entry") }
        } catch { Say ("  " + $_.Name + " : UNREADABLE (" + $_.Exception.Message + ")") }
    }
} else { Say "  (no PluginsInfo dir)" }

# -- Adobe plugin agent -------------------------------------------------------
$upia = $null
foreach ($r in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $r) { continue }
    $p = Join-Path $r "Common Files\Adobe\Adobe Desktop Common\RemoteComponents\UPI\UnifiedPluginInstallerAgent\UnifiedPluginInstallerAgent.exe"
    if (Test-Path $p) { $upia = $p; break }
}
Say "--- plugin agent ---"
if ($upia) {
    (& $upia /list all 2>&1 | Select-String "colourMatik") | ForEach-Object { Say ("  " + $_) }
} else { Say "  (agent not installed)" }

# ============================ REPAIR =========================================
Say ""
Say "=== REPAIR ==="
$curVer = $null
$srcPanel = Join-Path $inst "colourmatik-uxp"
if (Test-Path (Join-Path $srcPanel "manifest.json")) {
    $curVer = ((Get-Content (Join-Path $srcPanel "manifest.json") -Raw | ConvertFrom-Json).version)
    Say ("current panel available: v" + $curVer)

    # 1) agent forgets us (its database outlives file deletion)
    if ($upia) { & $upia /remove com.colourmatik.panel 2>&1 | Out-Null; Say "  agent /remove done" }

    # 2) delete every stale copy (per-user AND machine-wide, all hosts/versions)
    $needElevation = @()
    foreach ($root in (@((Join-Path $uxp "Plugins\External"), (Join-Path $uxp "PluginsStorage")) + $machineRoots)) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -Recurse -Directory -Filter "com.colourmatik*" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne ("com.colourmatik.panel_" + $curVer) } |
        ForEach-Object {
            Say ("  removing " + $_.FullName.Replace($env:APPDATA, "%APPDATA%"))
            Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue
            if (Test-Path $_.FullName) { $needElevation += $_.FullName }
        }
    }
    if ($needElevation.Count -gt 0) {
        Say ""
        Say "!! Some copies are in protected folders and need ADMIN to remove:"
        foreach ($ne in $needElevation) { Say ("     " + $ne) }
        $cmd = ($needElevation | ForEach-Object { "Remove-Item -Recurse -Force '" + $_ + "'" }) -join "; "
        Say "   Removing them now via an elevated window (approve the prompt)..."
        try {
            Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile", "-Command", $cmd
            $left = @($needElevation | Where-Object { Test-Path $_ })
            if ($left.Count -eq 0) { Say "   removed with admin rights - done" }
            else { Say "   STILL PRESENT (prompt declined?) - run PowerShell as Administrator and paste:"; Say ("     " + $cmd) }
        } catch { Say ("   elevation failed - run PowerShell as Administrator and paste:"); Say ("     " + $cmd) }
    }

    # 3) clean EVERY registry json (premierepro.json, the Beta's file, all of them)
    if (Test-Path $regDir) {
        Get-ChildItem $regDir -Filter "*.json" | ForEach-Object {
            try {
                $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
                if ($j.plugins) {
                    $keep = @($j.plugins | Where-Object { -not ($_.pluginId -eq "com.colourmatik.panel" -and $_.versionString -ne $curVer) })
                    if ($keep.Count -ne @($j.plugins).Count) {
                        $j.plugins = $keep
                        [IO.File]::WriteAllText($_.FullName, ($j | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
                        Say ("  cleaned " + $_.Name)
                    }
                }
            } catch {}
        }
    }

    # 4) put the current panel in place (developer-mode path)
    $PluginFolder = "com.colourmatik.panel_" + $curVer
    $dest = Join-Path $uxp ("Plugins\External\" + $PluginFolder)
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item (Join-Path $srcPanel "*") $dest -Force -Exclude "*.ccx"
    Say ("  installed -> " + $dest.Replace($env:APPDATA, "%APPDATA%"))
    # 5) REGISTER it through Adobe's agent so Premiere shows it WITHOUT any
    # developer-mode toggle. Removing the old registration above without doing
    # this left one field machine with files on disk and an empty UXP window.
    # 5a) WRITE THE REGISTRY ENTRY OURSELVES - this is what macOS has always
    # done, and it is why the Mac panel never goes missing. Windows relied
    # entirely on Adobe's agent, so when the agent's row was gone the panel
    # vanished from the UXP window with the files sitting right there.
    if (-not (Test-Path $regDir)) { New-Item -ItemType Directory -Force -Path $regDir | Out-Null }
    $mf = Get-Content (Join-Path $srcPanel "manifest.json") -Raw | ConvertFrom-Json
    $hostMin = "26.0"
    try { if ($mf.host -and $mf.host.minVersion) { $hostMin = $mf.host.minVersion } } catch {}
    $entry = [ordered]@{
        hostMinVersion = $hostMin
        name           = $(if ($mf.name) { $mf.name } else { "colourMatik" })
        path           = '$localPlugins/External/' + $PluginFolder
        pluginId       = "com.colourmatik.panel"
        status         = "enabled"
        type           = "uxp"
        versionString  = $curVer
    }
    foreach ($regName in @("premierepro.json", "PremierePro.json")) {
        $regFile = Join-Path $regDir $regName
        if (-not (Test-Path $regFile)) {
            if ($regName -ne "premierepro.json") { continue }
            [IO.File]::WriteAllText($regFile, '{"plugins":[]}', (New-Object Text.UTF8Encoding $false))
        }
        try {
            $j = Get-Content $regFile -Raw | ConvertFrom-Json
            $keep = @()
            if ($j.plugins) { $keep = @($j.plugins | Where-Object { $_.pluginId -ne "com.colourmatik.panel" }) }
            $keep += [pscustomobject]$entry
            $j.plugins = $keep
            # NO BOM - Premiere refuses to parse this file with one.
            [IO.File]::WriteAllText($regFile, ($j | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
            Say ("  registered in " + $regName + " -> " + $entry.path)
        } catch { Say ("  could not write " + $regName + " (" + $_.Exception.Message + ")") }
    }

    if ($upia) {
        $zip = Join-Path $env:TEMP "colourMatik-diag.zip"
        $ccx = Join-Path $env:TEMP "colourMatik-diag.ccx"
        foreach ($f in @($zip, $ccx)) { if (Test-Path $f) { Remove-Item -Force $f } }
        $files = Get-ChildItem $srcPanel -File | Where-Object { $_.Extension -in ".json",".html",".js",".png" }
        Compress-Archive -Path ($files | ForEach-Object { $_.FullName }) -DestinationPath $zip -Force
        Move-Item $zip $ccx -Force
        $out = (& $upia /install $ccx 2>&1 | Out-String).Trim()
        if ($out) { Say ("  agent install: " + ($out -split "`n")[0]) }
        if ($out -match "(?i)success") { Say "  panel REGISTERED through Adobe's agent - no developer mode needed" }
        else { Say "  agent did not confirm - if the panel is missing, enable Settings > Plugins > developer mode once" }
    }
    Say ""
    Say "NOW: quit Premiere completely and open it again."
    Say "If the panel is missing under Window > UXP Plugins, turn on"
    Say "Settings > Plugins > 'Enable developer mode' once, then restart Premiere."
} else {
    Say "colourMatik install dir has no panel source - run colourMatik-Setup.exe once first."
}

# -- engine repair ------------------------------------------------------------
# The smoking gun on the reported machine: install dir at 1.6.6 but the RUNNING
# engine answering 0.2.0 - a leftover process from the very first install held
# port 8765, so every newer engine died at bind and the ancient one kept
# serving (no /update_now endpoint -> the panel could only download files; and
# ancient matching code -> "everything is slow"). Kill anything matching, start
# the current engine, and wait until the version it ANSWERS matches the disk.
Say ""
Say "=== ENGINE REPAIR ==="
$diskVer = $null
if (Test-Path (Join-Path $inst "version.json")) {
    $diskVer = (Get-Content (Join-Path $inst "version.json") -Raw | ConvertFrom-Json).version
}
$liveVer = $null
try { $liveVer = (Invoke-RestMethod "http://127.0.0.1:8765/version" -TimeoutSec 3).version } catch {}
if ($diskVer -and $liveVer -ne $diskVer) {
    Say ("running engine v" + $liveVer + " != installed v" + $diskVer + " - restarting it")
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "colourmatik" -and $_.Name -match "python|pythonw" } |
        ForEach-Object { Say ("  killing pid " + $_.ProcessId); Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep 2
    $vbs = Join-Path $inst "windows\engine-hidden.vbs"
    if (Test-Path $vbs) { Start-Process wscript -ArgumentList ('"' + $vbs + '"') -WindowStyle Hidden; Say "  engine start requested" }
    else { Say ("  MISSING " + $vbs + " - run colourMatik-Setup.exe once") }
    $ok = $null
    for ($i = 0; $i -lt 45; $i++) {
        Start-Sleep 2
        try {
            $nv = (Invoke-RestMethod "http://127.0.0.1:8765/version" -TimeoutSec 2).version
            if ($nv -eq $diskVer) { $ok = $nv; break }
        } catch {}
    }
    if ($ok) { Say ("  ENGINE NOW v" + $ok + " - all good") }
    else { Say "  engine did not come up in 90s - it can need a few minutes on first run (AI libraries); check again with: irm http://127.0.0.1:8765/version" }
} elseif ($diskVer) {
    Say ("engine already matches the install (v" + $diskVer + ")")
}

$rep = Join-Path ([Environment]::GetFolderPath("Desktop")) "colourmatik-diag.txt"
$lines | Set-Content -Path $rep -Encoding UTF8
Say ""
Say ("Report saved to " + $rep + " - send a photo of THIS window if anything still looks wrong.")
