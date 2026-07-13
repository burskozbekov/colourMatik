#!/usr/bin/env bash
# colourMatik — sign + notarize + staple the NATIVE EFFECT (colourMatik.plugin).
#
# NOTE: the one-double-click installer app is built by ./mac/app/build-app.sh
# ("sign" mode) — NOT here. This script no longer builds any installer, so it can
# never clobber dist/ or produce a stale colourMatik-Installer.zip.
#
# Prereqs (one-time):
#   1) A "Developer ID Application" certificate in your keychain.
#   2) A notarytool credential profile:
#        xcrun notarytool store-credentials colourmatik \
#           --apple-id "YOUR_APPLE_ID_EMAIL" --team-id PCH6L56487
#
# Usage:  ./notarize.sh            (uses profile "colourmatik")
#         ./notarize.sh myprofile
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$DIR"
PROFILE="${1:-colourmatik}"
TEAM="PCH6L56487"
IDENTITY="Developer ID Application: Sevki Bugra Ozbek ($TEAM)"
PLUGIN="colourmatik-fx/colourMatik.plugin"

echo "==> Checking prerequisites"
security find-identity -v -p codesigning | grep -q "$TEAM" || { echo "  x No Developer ID cert for team $TEAM."; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || {
  echo "  x No notary profile '$PROFILE'. Create it (see NOTARIZE.md)."; exit 1; }
[ -d "$PLUGIN" ] || { echo "  x $PLUGIN not found."; exit 1; }
echo "  + cert + notary profile present"

echo "==> Signing the native effect (Developer ID + hardened runtime + timestamp)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$PLUGIN"
codesign --verify --strict --verbose=2 "$PLUGIN"

echo "==> Notarizing (uploads to Apple, waits a few minutes)"
ZIP="$(mktemp -t colourmatik-plugin).zip"
/usr/bin/ditto -c -k --keepParent "$PLUGIN" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
rm -f "$ZIP"

echo "==> Stapling"
xcrun stapler staple "$PLUGIN"
xcrun stapler validate "$PLUGIN" && echo "  + effect notarized + stapled"
echo "DONE. Commit it:  git add colourmatik-fx && git commit && git push"
