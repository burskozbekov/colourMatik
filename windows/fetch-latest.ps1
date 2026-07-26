# colourMatik - refresh the install directory from the source zip.
#
# Kept as its own file on purpose: building this inline inside update-windows.cmd
# meant echoing PowerShell (which is full of parentheses) into a parenthesised
# batch block, and batch closes such a block at the first unescaped ")" - the
# script would have been written out truncated and the update would fail in a
# way that looks like "nothing happened".
param([Parameter(Mandatory = $true)][string]$Dest)
$ErrorActionPreference = 'Stop'
$tmp = Join-Path $env:TEMP ('cmk-upd-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    Write-Host "==> Downloading the latest colourMatik..."
    Invoke-WebRequest 'https://github.com/burskozbekov/colourMatik/archive/refs/heads/main.zip' `
        -OutFile (Join-Path $tmp 'main.zip') -UseBasicParsing
    Expand-Archive (Join-Path $tmp 'main.zip') $tmp -Force
    $inner = Get-ChildItem $tmp -Directory -Filter 'colourMatik-*' | Select-Object -First 1
    if (-not $inner) { throw 'Unexpected zip layout.' }
    # Overwrite the code in place; .venv, vendored models and slot files live
    # outside the archive and are left alone.
    Copy-Item (Join-Path $inner.FullName '*') $Dest -Recurse -Force
    Write-Host "==> Source refreshed into $Dest"
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
