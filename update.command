#!/bin/bash
# colourMatik — update to the latest version. Double-click this.
# Pulls the newest code from GitHub, refreshes deps, and reinstalls the panel + effect.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
B='\033[1;34m'; G='\033[1;32m'; N='\033[0m'
echo "${B}==> Updating colourMatik...${N}"

if [ -d .git ] && command -v git >/dev/null 2>&1; then
  git pull --ff-only || { echo "Could not pull updates (local changes?). Run: git stash && retry."; }
else
  # Installed from the one-click installer (zip, no .git): refresh from the zip.
  # .venv / vendor / slot files are untouched; setup.sh below refreshes deps.
  echo "==> Downloading the latest colourMatik (zip)..."
  TMP="$(mktemp -d /tmp/colourMatik-upd.XXXXXX)"
  curl -fsSL "https://github.com/burskozbekov/colourMatik/archive/refs/heads/main.zip" -o "$TMP/main.zip" || { echo "Download failed - check your internet connection."; exit 1; }
  ditto -x -k "$TMP/main.zip" "$TMP" || { echo "Unzip failed."; exit 1; }
  INNER="$(ls -d "$TMP"/colourMatik-* 2>/dev/null | head -1)"
  [ -z "$INNER" ] && { echo "Unexpected zip layout."; exit 1; }
  ditto "$INNER" "$DIR"
  rm -rf "$TMP"
fi

echo "${B}==> Refreshing engine + AI...${N}";  ./setup.sh
echo "${B}==> Reinstalling panel + effect...${N}"
./install-panel.sh  >/dev/null 2>&1 || true
./install-effect.sh || true
launchctl kickstart -k "gui/$(id -u)/com.colourmatik.engine" 2>/dev/null || true

echo "${G}==> Updated. Restart Premiere Pro.${N}"
[ -t 0 ] && { printf "(press any key)"; read -rn1 _; echo; } || true
