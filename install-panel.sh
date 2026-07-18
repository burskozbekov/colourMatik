#!/usr/bin/env bash
# colourMatik — install the UXP panel into Premiere Pro the same way signed
# .ccx plugins are installed (no UXP Developer Tool required). Re-run after edits.
# After running, RESTART Premiere Pro; the panel appears under
# Window ▸ UXP Plugins ▸ colourMatik.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/colourmatik-uxp"
EXT="$HOME/Library/Application Support/Adobe/UXP/Plugins/External"
REG="$HOME/Library/Application Support/Adobe/UXP/PluginsInfo/v1/premierepro.json"

# Create the registry if Premiere hasn't run yet, so a fresh machine works too.
if [ ! -f "$REG" ]; then
    mkdir -p "$(dirname "$REG")"
    echo '{"plugins":[]}' > "$REG"
    echo "(created a new UXP registry — Premiere hadn't been opened yet)"
fi

cp "$REG" "$REG.colourmatik-backup"

# The install folder MUST be <pluginId>_<manifest version> — that is the
# convention every UXP panel Premiere lists follows. Ours had drifted (folder
# pinned at _1.0.0 while the manifest moved to 1.2.0) and Premiere quietly
# refused to show it. Derive folder + registry entry from the manifest so they
# can never drift apart again.
mkdir -p "$EXT"
python3 - "$SRC" "$EXT" "$REG" <<'PY'
import json, shutil, sys
from pathlib import Path

src, ext, reg = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
mf = json.load(open(src / "manifest.json"))
plugin_id, version = mf["id"], mf["version"]
folder = f"{plugin_id}_{version}"
dest = ext / folder

dest.mkdir(parents=True, exist_ok=True)
for f in ("manifest.json", "index.html", "main.js"):
    shutil.copy2(src / f, dest / f)

# drop stale <pluginId>_<older version> folders so only one copy is ever present
for old in ext.glob(f"{plugin_id}_*"):
    if old.name != folder and old.is_dir():
        shutil.rmtree(old, ignore_errors=True)

d = json.load(open(reg))
d.setdefault("plugins", [])
d["plugins"] = [p for p in d["plugins"] if p.get("pluginId") != plugin_id]
d["plugins"].append({
    "hostMinVersion": mf.get("host", {}).get("minVersion", "26.0"),
    "name": mf.get("name", "colourMatik"),
    "path": f"$localPlugins/External/{folder}",
    "pluginId": plugin_id, "status": "enabled",
    "type": "uxp", "versionString": version,
})
json.dump(d, open(reg, "w"))
print(f"registered {plugin_id} {version} -> {folder}")
PY

echo "Installed. Restart Premiere Pro → Window ▸ UXP Plugins ▸ colourMatik."
echo "Remember to start the engine first:  ./colourmatik-app"
