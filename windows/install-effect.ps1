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

# Resolve the .aex once into $Src (local build, else the release zip).
if ($local) {
    Write-Host "==> Using local build: $local"
    $Src = $local
} else {
    Write-Host "==> Downloading the effect from the latest release..."
    $tmp = Join-Path $env:TEMP "colourMatik-effect-windows.zip"
    Invoke-WebRequest -Uri $ReleaseAsset -OutFile $tmp -UseBasicParsing
    $ext = Join-Path $env:TEMP "colourMatik-effect-win"
    if (Test-Path $ext) { Remove-Item -Recurse -Force $ext }
    Expand-Archive $tmp $ext
    $aex = Get-ChildItem $ext -Recurse -Filter "*.aex" | Select-Object -First 1
    if (-not $aex) { throw "colourMatik.aex not found in the release zip." }
    $Src = $aex.FullName
}

# 1) Premiere Pro / Media Encoder: the shared MediaCore folder.
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
Copy-Item $Src $Dest -Force
Unblock-File $Dest -ErrorAction SilentlyContinue
Write-Host "Effect installed (Premiere) -> $Dest"

# 2) After Effects does NOT load effects from MediaCore — only from its OWN
#    Plug-ins folder. Install a copy for every AE version present, or the effect
#    shows in Premiere but is invisible in After Effects.
$aeRoots = @("C:\Program Files\Adobe", "C:\Program Files (x86)\Adobe")
foreach ($aeRoot in $aeRoots) {
    if (-not (Test-Path $aeRoot)) { continue }
    Get-ChildItem $aeRoot -Directory -Filter "Adobe After Effects *" -ErrorAction SilentlyContinue | ForEach-Object {
        $aePlug = Join-Path $_.FullName "Support Files\Plug-ins"
        if (Test-Path $aePlug) {
            $aeDestDir = Join-Path $aePlug "colourMatik"
            New-Item -ItemType Directory -Force -Path $aeDestDir | Out-Null
            $aeDest = Join-Path $aeDestDir "colourMatik.aex"
            Copy-Item $Src $aeDest -Force
            Unblock-File $aeDest -ErrorAction SilentlyContinue
            Write-Host "Effect installed (After Effects) -> $aeDest"
        }
    }
}
Write-Host "Restart Premiere Pro / After Effects, then find it under Effects > colourMatik > colourMatik."
