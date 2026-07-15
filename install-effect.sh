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
echo "Installed (Premiere) → $DEST"

# After Effects does NOT load effects from the shared MediaCore folder — only from
# its OWN Plug-Ins folder. Install a copy there too, for every AE version present,
# or the effect shows in Premiere but is invisible in After Effects.
shopt -s nullglob
for AEAPP in /Applications/Adobe\ After\ Effects\ *; do
    AEPLUG="$AEAPP/Plug-Ins"
    [ -d "$AEPLUG" ] || continue
    AEDEST="$AEPLUG/colourMatik/colourMatik.plugin"
    if [ ! -w "$AEPLUG" ] && [ -z "$SUDO" ]; then
        echo "After Effects plug-ins folder needs admin — you may be asked for your password."
        SUDO="sudo"
    fi
    $SUDO mkdir -p "$AEPLUG/colourMatik"
    $SUDO rm -rf "$AEDEST"
    $SUDO cp -R "$SRC" "$AEDEST"
    $SUDO xattr -dr com.apple.quarantine "$AEPLUG/colourMatik" 2>/dev/null || true
    echo "Installed effect (After Effects) → $AEDEST"
    # the AE Match & Apply panel (ScriptUI — AE has no UXP)
    AESUI="$AEAPP/Scripts/ScriptUI Panels"
    if [ -f "$DIR/colourmatik-ae/colourMatik.jsx" ] && [ -d "$AESUI" ]; then
        $SUDO cp "$DIR/colourmatik-ae/colourMatik.jsx" "$AESUI/colourMatik.jsx"
        $SUDO xattr -d com.apple.quarantine "$AESUI/colourMatik.jsx" 2>/dev/null || true
        echo "Installed panel  (After Effects) → $AESUI/colourMatik.jsx"
    fi
done

# The AE panel talks to the local engine via curl, which needs AE's "Allow Scripts
# to Write Files and Access Network" preference. A running script can't flip it
# (security), so we write it straight into each AE version's prefs — identical to
# ticking the checkbox. AE must be closed (it is during a normal install).
for PF in "$HOME/Library/Preferences/Adobe/After Effects/"*/"Adobe After Effects "*" Prefs.txt"; do
    [ -f "$PF" ] || continue
    if grep -q '"Pref_SCRIPTING_FILE_NETWORK_SECURITY" = "0"' "$PF" 2>/dev/null; then
        sed -i '' 's/"Pref_SCRIPTING_FILE_NETWORK_SECURITY" = "0"/"Pref_SCRIPTING_FILE_NETWORK_SECURITY" = "1"/' "$PF"
        echo "Enabled scripting/network for $(basename "$(dirname "$PF")")"
    fi
done

echo "Restart Premiere Pro / After Effects, then find it under Effects ▸ colourMatik ▸ colourMatik."
