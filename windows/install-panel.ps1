# colourMatik — install / repair the UXP panel in Premiere Pro (Windows).
# Per-user, NO admin needed. Safe to run standalone to fix a panel that isn't
# showing up:  powershell -NoProfile -ExecutionPolicy Bypass -File install-panel.ps1
# Mirrors install-panel.sh (mac): copies the panel + registers it in Premiere's
# UXP registry.  by Sevki Bugra Ozbek - catheadai.com
$ErrorActionPreference = "Stop"

# --- resolve the LOGGED-IN user's profile, even when run elevated -------------
# The Premiere setup self-elevates. When it is elevated with a DIFFERENT admin
# account, $env:APPDATA points at the admin's profile, not the person using
# Premiere — the panel would register where their Premiere never looks. Find the
# owner of the interactive explorer.exe instead (the effect installer does the
# same). When run non-elevated (the standalone repair) this resolves to the same
# user, so both paths are correct.
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
$Roaming = Join-Path $UserProfile "AppData\Roaming"

# --- find the panel source (next to this script, or the default install dir) --
# $MyInvocation.MyCommand.Path is $null when this is run via Invoke-Expression
# (the one-line repair), so guard it and always try <profile>\colourMatik too.
$ScriptPath = $MyInvocation.MyCommand.Path
$Src = $null
$cands = @()
if ($ScriptPath) { $cands += (Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptPath)) "colourmatik-uxp") }
$cands += (Join-Path $UserProfile "colourMatik\colourmatik-uxp")
$cands += (Join-Path $env:USERPROFILE "colourMatik\colourmatik-uxp")
foreach ($cand in $cands) {
    if ($cand -and (Test-Path (Join-Path $cand "manifest.json"))) { $Src = $cand; break }
}

$Ext  = Join-Path $Roaming "Adobe\UXP\Plugins\External"
$Dest = Join-Path $Ext "com.colourmatik.panel_1.0.0"
$Reg  = Join-Path $Roaming "Adobe\UXP\PluginsInfo\v1\premierepro.json"

# --- copy the panel files -----------------------------------------------------
if ($Src) {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    foreach ($f in @("manifest.json", "index.html", "main.js")) {
        Copy-Item (Join-Path $Src $f) $Dest -Force
    }
} elseif (-not (Test-Path (Join-Path $Dest "manifest.json"))) {
    throw "Couldn't find the colourMatik panel files. Re-run the colourMatik setup, then this."
}

# --- register it in Premiere's UXP registry -----------------------------------
if (Test-Path $Reg) {
    Copy-Item $Reg "$Reg.colourmatik-backup" -Force
    $j = Get-Content $Reg -Raw | ConvertFrom-Json
    if (-not $j.plugins) { $j | Add-Member -Force NoteProperty plugins @() }
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $Reg) | Out-Null
    $j = [pscustomobject]@{ plugins = @() }
}

$entry = [pscustomobject]@{
    hostMinVersion = "26.0"
    name           = "colourMatik"
    path           = '$localPlugins/External/com.colourmatik.panel_1.0.0'
    pluginId       = "com.colourmatik.panel"
    status         = "enabled"
    type           = "uxp"
    versionString  = "1.2.0"
}
$others = @($j.plugins | Where-Object { $_.pluginId -ne "com.colourmatik.panel" })
$all    = @($others) + @($entry)

# Build the JSON by hand so it is bullet-proof on Windows PowerShell 5.1:
#  1) serialise each plugin on its own, so a SINGLE entry still lands inside a
#     JSON array [ ... ] (ConvertTo-Json otherwise collapses a 1-item array to an
#     object, which Premiere then reads as "no plugins").
#  2) keep every OTHER top-level key Premiere may have written.
$pluginsJson = "[" + (($all | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }) -join ",") + "]"
$j.PSObject.Properties.Remove("plugins")
$rest = $j | ConvertTo-Json -Depth 10 -Compress            # "{}" when nothing else
if ($rest.Length -gt 2) { $json = $rest.Substring(0, $rest.Length - 1) + ',"plugins":' + $pluginsJson + "}" }
else                    { $json = '{"plugins":' + $pluginsJson + "}" }

# Write UTF-8 WITHOUT a BOM. Windows PowerShell 5.1's `Set-Content -Encoding UTF8`
# prepends a BOM (EF BB BF); Premiere's JSON parser then rejects the whole file
# and NO UXP panel loads. .NET's UTF8Encoding($false) writes clean bytes, exactly
# like the mac Python installer.
[System.IO.File]::WriteAllText($Reg, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "colourMatik panel registered for $env:USERNAME."
Write-Host "Now: fully quit and reopen Premiere Pro -> Window > UXP Plugins > colourMatik."
