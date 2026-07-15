# colourMatik — elevated cleanup: remove the native effect from Premiere's shared
# MediaCore folder and from every After Effects version (effect + ScriptUI panel).
# Called by uninstall-windows.cmd with admin rights.
$ErrorActionPreference = "SilentlyContinue"

Remove-Item -Force "C:\Program Files\Adobe\Common\Plug-ins\7.0\MediaCore\colourMatik.aex"

foreach ($aeRoot in @("C:\Program Files\Adobe", "C:\Program Files (x86)\Adobe")) {
    if (-not (Test-Path $aeRoot)) { continue }
    Get-ChildItem $aeRoot -Directory -Filter "Adobe After Effects *" | ForEach-Object {
        Remove-Item -Recurse -Force (Join-Path $_.FullName "Support Files\Plug-ins\colourMatik")
        Remove-Item -Force (Join-Path $_.FullName "Support Files\Scripts\ScriptUI Panels\colourMatik.jsx")
    }
}
Write-Host "colourMatik effect + AE panel removed."
