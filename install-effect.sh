#!/usr/bin/env bash
# colourMatik — install the native "colourMatik" effect (the thing that actually
# applies the match, with a built-in Intensity slider) into Premiere Pro / After
# Effects. After running, RESTART the host app; the effect appears under
# Video Effects ▸ colourMatik ▸ colourMatik.  macOS / Apple Silicon.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/colourmatik-fx/colourMatik.plugin"
DEST="/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/colourMatik.plugin"

[ -d "$SRC" ] || { echo "Built plugin not found at $SRC"; exit 1; }
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
codesign --force --sign - --timestamp=none "$DEST" >/dev/null 2>&1 || true
echo "Installed → $DEST"
echo "Restart Premiere Pro / After Effects, then find it under Video Effects ▸ colourMatik."
