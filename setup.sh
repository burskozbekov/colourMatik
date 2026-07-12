#!/usr/bin/env bash
# colourMatik — one-shot setup. Creates the Python venv, installs deps, and fetches
# the local-AI model (CanonCGT) + weights. Re-run any time; it is idempotent.
#
#   ./setup.sh          # full install (classical engine + local AI)
#   ./setup.sh --no-ai  # classical engine only (skip PyTorch / CanonCGT)
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
PY="${PYTHON:-python3.11}"

# Optional progress reporting: when COLOURMATIK_PROGRESS is set to a file path,
# write "PCT|CAP|message" stage markers there (read by the installer progress bar).
prog() { if [ -n "${COLOURMATIK_PROGRESS:-}" ]; then echo "$1|$2|$3" > "$COLOURMATIK_PROGRESS"; fi; }

prog 32 37 "Creating the engine environment…"
echo "==> Creating virtualenv (.venv) with $PY"
[ -d .venv ] || "$PY" -m venv .venv
./.venv/bin/pip install --quiet --upgrade pip

prog 37 42 "Installing the engine…"
echo "==> Installing base engine deps"
./.venv/bin/pip install --quiet -r requirements.txt

if [ "$1" = "--no-ai" ]; then
    echo "==> Skipping local AI (--no-ai). Classical engine ready."
    exit 0
fi

prog 42 72 "Downloading the AI engine (a few GB — the long part)…"
echo "==> Installing local-AI deps (PyTorch / transformers). This is a few hundred MB."
./.venv/bin/pip install --quiet -r requirements-ai.txt

prog 72 76 "Fetching the AI grading model…"
echo "==> Fetching CanonCGT (CVPR 2026, Apache-2.0) into vendor/"
mkdir -p vendor
[ -d vendor/CanonCGT ] || git clone --depth 1 https://github.com/Jinwon-Ko/CanonCGT.git vendor/CanonCGT

prog 76 84 "Downloading the AI model weights…"
echo "==> Downloading CanonCGT pretrained weights"
W="vendor/CanonCGT/pretrained/SSL_updated_251111.pth"
if [ ! -s "$W" ] || [ "$(wc -c < "$W" 2>/dev/null || echo 0)" -lt 1000000 ]; then
    ./.venv/bin/gdown "1SqzCXjdJ95TAhDYY9Z4TaQPuoqlEyfkT" -O vendor/CanonCGT/pretrained/_dl.zip
    # the Drive file is a zip bundling the .pth checkpoints
    ( cd vendor/CanonCGT/pretrained && unzip -o -q _dl.zip && rm -f _dl.zip )
fi
echo "==> Done. Start the engine with:  ./colourmatik-app"
echo "    (First AI run also auto-downloads the SegFormer scene model, ~15MB, from Hugging Face.)"
