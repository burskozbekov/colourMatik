# colourMatik — Windows engine setup. Creates the Python venv, installs deps,
# and fetches the local-AI model (CanonCGT) + weights. Idempotent; re-run any time.
#   powershell -ExecutionPolicy Bypass -File windows\setup.ps1 [-NoAI]
param([switch]$NoAI)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

function Find-Python311 {
    foreach ($cand in @("py -3.11", "python3.11", "python")) {
        try {
            $v = & cmd /c "$cand -c ""import sys;print(sys.version_info[:2])""" 2>$null
            if ($v -match "\(3, 1[1-9]\)") { return $cand }
        } catch {}
    }
    return $null
}

Write-Host "==> Locating Python 3.11+"
$py = Find-Python311
if (-not $py) {
    Write-Host "==> Installing Python 3.11 via winget..."
    winget install -e --id Python.Python.3.11 --accept-source-agreements --accept-package-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "User") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "Machine")
    $py = Find-Python311
    if (-not $py) { throw "Python 3.11 not found after install - open a new terminal and re-run." }
}
Write-Host "    using: $py"

if (-not (Test-Path ".venv")) {
    Write-Host "==> Creating virtualenv (.venv)"
    & cmd /c "$py -m venv .venv"
}
$pip = ".\.venv\Scripts\pip.exe"
& $pip install --quiet --upgrade pip

Write-Host "==> Installing base engine deps"
& $pip install --quiet -r requirements.txt

if ($NoAI) { Write-Host "==> Skipping local AI (-NoAI). Classical engine ready."; exit 0 }

Write-Host "==> Installing local-AI deps (PyTorch / transformers). A few hundred MB."
& $pip install --quiet -r requirements-ai.txt

Write-Host "==> Fetching CanonCGT (CVPR 2026, Apache-2.0) into vendor\"
New-Item -ItemType Directory -Force -Path vendor | Out-Null
if (-not (Test-Path "vendor\CanonCGT")) {
    git clone --depth 1 https://github.com/Jinwon-Ko/CanonCGT.git vendor\CanonCGT
}

Write-Host "==> Downloading CanonCGT pretrained weights"
$w = "vendor\CanonCGT\pretrained\SSL_updated_251111.pth"
if (-not (Test-Path $w) -or ((Get-Item $w).Length -lt 1000000)) {
    & ".\.venv\Scripts\gdown.exe" "1SqzCXjdJ95TAhDYY9Z4TaQPuoqlEyfkT" -O "vendor\CanonCGT\pretrained\_dl.zip"
    Expand-Archive -Force "vendor\CanonCGT\pretrained\_dl.zip" "vendor\CanonCGT\pretrained"
    Remove-Item -Force "vendor\CanonCGT\pretrained\_dl.zip"
}
Write-Host "==> Done. Start the engine with:  windows\colourmatik-app.cmd"
Write-Host "    (First AI run also auto-downloads the SegFormer scene model, ~15MB.)"
