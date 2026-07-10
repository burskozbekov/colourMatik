#!/bin/bash
# colourMatik — update to the latest version. Double-click this.
# Pulls the newest code from GitHub, refreshes deps, and reinstalls the panel + effect.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
B='\033[1;34m'; G='\033[1;32m'; N='\033[0m'
echo "${B}==> Updating colourMatik...${N}"

if [ -d .git ]; then
  git pull --ff-only || { echo "Could not pull updates (local changes?). Run: git stash && retry."; }
else
  echo "This folder isn't a git checkout; re-run install.command instead."; exit 1
fi

echo "${B}==> Refreshing engine + AI...${N}";  ./setup.sh
echo "${B}==> Reinstalling panel + effect...${N}"
./install-panel.sh  >/dev/null 2>&1 || true
./install-effect.sh || true
launchctl kickstart -k "gui/$(id -u)/com.colourmatik.engine" 2>/dev/null || true

echo "${G}==> Updated. Restart Premiere Pro.${N}"
[ -t 0 ] && { printf "(press any key)"; read -rn1 _; echo; } || true
