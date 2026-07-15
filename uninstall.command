#!/bin/bash
# colourMatik — uninstaller for macOS. Double-click to remove the panel, the native
# effect, and the background engine. Leaves the colourMatik folder itself (delete it
# yourself if you want). by catheadai.com
set -uo pipefail
say(){ printf "\n==> %s\n" "$1"; }

say "Stopping the background engine..."
launchctl bootout "gui/$(id -u)/com.colourmatik.engine" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.colourmatik.engine.plist"

say "Removing the Premiere panel..."
rm -rf "$HOME/Library/Application Support/Adobe/UXP/Plugins/External/com.colourmatik.panel_1.0.0"
REG="$HOME/Library/Application Support/Adobe/UXP/PluginsInfo/v1/premierepro.json"
if [ -f "$REG" ]; then
  python3 - "$REG" <<'PY' 2>/dev/null || true
import json,sys
r=sys.argv[1]; d=json.load(open(r))
d["plugins"]=[p for p in d.get("plugins",[]) if p.get("pluginId")!="com.colourmatik.panel"]
json.dump(d,open(r,"w"))
PY
fi

say "Removing the native effect (Premiere)..."
DEST="/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/colourMatik.plugin"
if [ -w "$(dirname "$DEST")" ]; then rm -rf "$DEST"; else sudo rm -rf "$DEST"; fi

say "Removing the After Effects effect + panel..."
for AEAPP in /Applications/Adobe\ After\ Effects\ *; do
  [ -d "$AEAPP" ] || continue
  for T in "$AEAPP/Plug-Ins/colourMatik" "$AEAPP/Scripts/ScriptUI Panels/colourMatik.jsx"; do
    [ -e "$T" ] || continue
    if [ -w "$(dirname "$T")" ]; then rm -rf "$T"; else sudo rm -rf "$T"; fi
  done
done

say "Removing the colourMatik support folder..."
rm -rf "$HOME/Library/Application Support/colourMatik"

echo
echo "Done. Restart Premiere Pro to finish. (The colourMatik app folder was left in place.)"
[ -t 0 ] && { printf "(press any key)"; read -rn1 _; echo; } || true
