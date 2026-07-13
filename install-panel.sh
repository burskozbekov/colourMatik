#!/usr/bin/env bash
# colourMatik — install the UXP panel into Premiere Pro the same way signed
# .ccx plugins are installed (no UXP Developer Tool required). Re-run after edits.
# After running, RESTART Premiere Pro; the panel appears under
# Window ▸ UXP Plugins ▸ colourMatik.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/colourmatik-uxp"
EXT="$HOME/Library/Application Support/Adobe/UXP/Plugins/External"
DEST="$EXT/com.colourmatik.panel_1.0.0"
REG="$HOME/Library/Application Support/Adobe/UXP/PluginsInfo/v1/premierepro.json"

# Create the registry if Premiere hasn't run yet, so a fresh machine works too.
if [ ! -f "$REG" ]; then
    mkdir -p "$(dirname "$REG")"
    echo '{"plugins":[]}' > "$REG"
    echo "(created a new UXP registry — Premiere hadn't been opened yet)"
fi

cp "$REG" "$REG.colourmatik-backup"
mkdir -p "$DEST"
cp "$SRC/manifest.json" "$SRC/index.html" "$SRC/main.js" "$DEST/"

python3 - "$REG" <<'PY'
import json, sys
reg = sys.argv[1]
d = json.load(open(reg))
d.setdefault("plugins", [])
d["plugins"] = [p for p in d["plugins"] if p.get("pluginId") != "com.colourmatik.panel"]
d["plugins"].append({
    "hostMinVersion": "26.0", "name": "colourMatik",
    "path": "$localPlugins/External/com.colourmatik.panel_1.0.0",
    "pluginId": "com.colourmatik.panel", "status": "enabled",
    "type": "uxp", "versionString": "1.2.0",
})
json.dump(d, open(reg, "w"))
print("registered:", [p["pluginId"] for p in d["plugins"]])
PY

echo "Installed. Restart Premiere Pro → Window ▸ UXP Plugins ▸ colourMatik."
echo "Remember to start the engine first:  ./colourmatik-app"
