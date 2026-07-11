# colourMatik — install the native effect (.aex) into Premiere Pro (Windows, x64).
# Uses a local build if present (windows\colourMatik.aex or colourmatik-fx\colourMatik.aex),
# otherwise downloads it from the project's latest GitHub release. Needs admin for
# the shared MediaCore folder (the caller elevates).
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$DestDir = "C:\Program Files\Adobe\Common\Plug-ins\7.0\MediaCore"
$Dest = Join-Path $DestDir "colourMatik.aex"
$ReleaseAsset = "https://github.com/burskozbekov/colourMatik/releases/latest/download/colourMatik-effect-windows.zip"

$local = @("$Root\windows\colourMatik.aex", "$Root\colourmatik-fx\colourMatik.aex") |
         Where-Object { Test-Path $_ } | Select-Object -First 1

New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
if ($local) {
    Write-Host "==> Installing local build: $local"
    Copy-Item $local $Dest -Force
} else {
    Write-Host "==> Downloading the effect from the latest release..."
    $tmp = Join-Path $env:TEMP "colourMatik-effect-windows.zip"
    Invoke-WebRequest -Uri $ReleaseAsset -OutFile $tmp -UseBasicParsing
    $ext = Join-Path $env:TEMP "colourMatik-effect-win"
    if (Test-Path $ext) { Remove-Item -Recurse -Force $ext }
    Expand-Archive $tmp $ext
    $aex = Get-ChildItem $ext -Recurse -Filter "*.aex" | Select-Object -First 1
    if (-not $aex) { throw "colourMatik.aex not found in the release zip." }
    Copy-Item $aex.FullName $Dest -Force
}
Unblock-File $Dest -ErrorAction SilentlyContinue
Write-Host "Effect installed -> $Dest"
Write-Host "Restart Premiere Pro, then find it under Video Effects > colourMatik."
