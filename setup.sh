#!/usr/bin/env bash
# colourMatik — one-shot setup. Creates the Python venv and installs the fast
# classical engine. Re-run any time; it is idempotent.
# Needs ONLY Python 3.11+ — no Homebrew, no git, no system ffmpeg (ffmpeg is
# bundled via the imageio-ffmpeg pip package).
#
#   ./setup.sh          # fast classical engine (the product default)
#   ./setup.sh --ai     # optional: heavy local-AI extras (GBs; not required)
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

# The heavy local-AI stack (PyTorch, transformers, CanonCGT weights - GBs of
# downloads and minutes of install) is OPT-IN now. The default engine is the
# fast classical core; nothing below downloads anything.
if [ "${1:-}" = "--ai" ]; then
    prog 42 72 "Downloading the AI engine (a few GB)..."
    ./.venv/bin/pip install --quiet -r requirements-ai.txt
    mkdir -p vendor
    if [ ! -d vendor/CanonCGT ]; then
        curl -fsSL "https://github.com/Jinwon-Ko/CanonCGT/archive/refs/heads/main.zip" -o vendor/_canoncgt.zip
        ( cd vendor && unzip -o -q _canoncgt.zip && rm -f _canoncgt.zip && mv CanonCGT-main CanonCGT )
    fi
    # The weights are what make CanonCGT actually load — without this step the
    # multi-GB opt-in silently degrades to classical forever.
    mkdir -p vendor/CanonCGT/pretrained
    W="vendor/CanonCGT/pretrained/SSL_updated_251111.pth"
    if [ ! -s "$W" ] || [ "$(wc -c < "$W" 2>/dev/null || echo 0)" -lt 1000000 ]; then
        ./.venv/bin/gdown "1SqzCXjdJ95TAhDYY9Z4TaQPuoqlEyfkT" -O vendor/CanonCGT/pretrained/_dl.zip
        ( cd vendor/CanonCGT/pretrained && unzip -o -q _dl.zip && rm -f _dl.zip )
    fi
fi

echo "==> Done. Start the engine with:  ./colourmatik-app"
