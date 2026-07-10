#!/usr/bin/env bash
# colourMatik — install the native "colourMatik" effect (applies the match, with a
# built-in Intensity slider) into Premiere Pro / After Effects. After running,
# RESTART the host app; it appears under Video Effects ▸ colourMatik ▸ colourMatik.
# macOS / Apple Silicon. Uses admin (sudo) only if the plug-ins folder isn't writable.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/colourmatik-fx/colourMatik.plugin"
DEST="/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/colourMatik.plugin"
DESTDIR="$(dirname "$DEST")"

[ -d "$SRC" ] || { echo "Built plugin not found at $SRC"; exit 1; }

# Prefer no-sudo; fall back to sudo if the shared MediaCore folder needs admin.
SUDO=""
if ! mkdir -p "$DESTDIR" 2>/dev/null || [ ! -w "$DESTDIR" ]; then
    echo "The Adobe plug-ins folder needs admin rights — you'll be asked for your Mac password."
    SUDO="sudo"
    $SUDO mkdir -p "$DESTDIR"
fi
$SUDO rm -rf "$DEST"
$SUDO cp -R "$SRC" "$DEST"   # preserves the shipped signature (Developer ID + notarization)
$SUDO xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
# Only adhoc-sign as a fallback if the copy has no valid signature at all (e.g. a
# locally hand-built plugin). A shipped Developer-ID/notarized build is left untouched.
if ! codesign --verify "$DEST" >/dev/null 2>&1; then
    $SUDO codesign --force --sign - --timestamp=none "$DEST" >/dev/null 2>&1 || true
fi

echo "Installed → $DEST"
echo "Restart Premiere Pro / After Effects, then find it under Video Effects ▸ colourMatik."
