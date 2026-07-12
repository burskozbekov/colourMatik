#!/usr/bin/env bash
# colourMatik — one-shot setup. Creates the Python venv, installs deps, and fetches
# the local-AI model (CanonCGT) + weights. Re-run any time; it is idempotent.
# Needs ONLY Python 3.11+ — no Homebrew, no git, no system ffmpeg (ffmpeg is
# bundled via the imageio-ffmpeg pip package; CanonCGT is fetched as a zip).
#
#   ./setup.sh          # full install (classical engine + local AI)
#   ./setup.sh --no-ai  # classical engine only (skip PyTorch / CanonCGT)
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# Find Python 3.11+: $PYTHON override, PATH, python.org framework, Homebrew.
find_py() {
  for c in "${PYTHON:-}" python3.11 python3.12 python3.13 \
           /Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11 \
           /usr/local/bin/python3.11 /opt/homebrew/bin/python3.11 python3; do
    [ -n "$c" ] || continue
    if "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' 2>/dev/null; then
      echo "$c"; return 0
    fi
  done
  return 1
}
PY="$(find_py)" || { echo "ERROR: Python 3.11+ not found."; exit 1; }

# Optional progress reporting: when COLOURMATIK_PROGRESS is set to a file path,
# write "PCT|CAP|message" stage markers there (read by the installer progress bar).
# A failed write must NEVER kill the setup (set -e) — progress is cosmetic.
prog() { { [ -n "${COLOURMATIK_PROGRESS:-}" ] && echo "$1|$2|$3" > "$COLOURMATIK_PROGRESS"; } 2>/dev/null || true; }

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
echo "==> Fetching CanonCGT (CVPR 2026, Apache-2.0) into vendor/ (zip, no git needed)"
mkdir -p vendor
if [ ! -d vendor/CanonCGT ]; then
    curl -fsSL "https://github.com/Jinwon-Ko/CanonCGT/archive/refs/heads/main.zip" -o vendor/_canoncgt.zip
    ( cd vendor && unzip -o -q _canoncgt.zip && rm -f _canoncgt.zip && mv CanonCGT-main CanonCGT )
fi

prog 76 84 "Downloading the AI model weights…"
echo "==> Downloading CanonCGT pretrained weights"
mkdir -p vendor/CanonCGT/pretrained
W="vendor/CanonCGT/pretrained/SSL_updated_251111.pth"
if [ ! -s "$W" ] || [ "$(wc -c < "$W" 2>/dev/null || echo 0)" -lt 1000000 ]; then
    ./.venv/bin/gdown "1SqzCXjdJ95TAhDYY9Z4TaQPuoqlEyfkT" -O vendor/CanonCGT/pretrained/_dl.zip
    # the Drive file is a zip bundling the .pth checkpoints
    ( cd vendor/CanonCGT/pretrained && unzip -o -q _dl.zip && rm -f _dl.zip )
fi
echo "==> Done. Start the engine with:  ./colourmatik-app"
echo "    (First AI run also auto-downloads the SegFormer scene model, ~15MB, from Hugging Face.)"
