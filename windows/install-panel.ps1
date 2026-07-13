# colourMatik — install the UXP panel into Premiere Pro (Windows).
# Mirrors install-panel.sh: copies the panel + registers it in Premiere's UXP registry.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Src  = Join-Path $Root "colourmatik-uxp"
$Ext  = Join-Path $env:APPDATA "Adobe\UXP\Plugins\External"
$Dest = Join-Path $Ext "com.colourmatik.panel_1.0.0"
$Reg  = Join-Path $env:APPDATA "Adobe\UXP\PluginsInfo\v1\premierepro.json"

if (-not (Test-Path $Reg)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Reg) | Out-Null
    '{"plugins":[]}' | Set-Content -Encoding UTF8 $Reg
    Write-Host "(created a new UXP registry - Premiere hadn't been opened yet)"
}
Copy-Item $Reg "$Reg.colourmatik-backup" -Force

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
foreach ($f in @("manifest.json", "index.html", "main.js")) {
    Copy-Item (Join-Path $Src $f) $Dest -Force
}

$j = Get-Content $Reg -Raw | ConvertFrom-Json
if (-not $j.plugins) { $j | Add-Member -Force NoteProperty plugins @() }
$j.plugins = @($j.plugins | Where-Object { $_.pluginId -ne "com.colourmatik.panel" })
$j.plugins += [pscustomobject]@{
    hostMinVersion = "26.0"; name = "colourMatik"
    path = '$localPlugins/External/com.colourmatik.panel_1.0.0'
    pluginId = "com.colourmatik.panel"; status = "enabled"
    type = "uxp"; versionString = "1.2.0"
}
($j | ConvertTo-Json -Depth 8 -Compress) | Set-Content -Encoding UTF8 $Reg
Write-Host "Panel installed. Restart Premiere Pro -> Window > UXP Plugins > colourMatik."
