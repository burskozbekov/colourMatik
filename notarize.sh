#!/usr/bin/env bash
# colourMatik — sign + notarize the native effect AND build a notarized installer app,
# so friends install with zero Gatekeeper warnings. macOS.
#
# Prereqs (one-time):
#   1) A "Developer ID Application" certificate in your keychain.
#   2) A notarytool credential profile. See NOTARIZE.md, or:
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
DIST="$DIR/dist"; rm -rf "$DIST"; mkdir -p "$DIST"

echo "==> Checking prerequisites"
security find-identity -v -p codesigning | grep -q "$TEAM" || { echo "  ✗ No Developer ID cert for team $TEAM."; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || {
  echo "  ✗ No notary profile '$PROFILE'. Create it (see NOTARIZE.md):"
  echo "      xcrun notarytool store-credentials $PROFILE --apple-id \"YOUR_APPLE_ID\" --team-id $TEAM"
  exit 1; }
[ -d "$PLUGIN" ] || { echo "  ✗ $PLUGIN not found."; exit 1; }
echo "  ✓ cert + notary profile present"

echo "==> Signing the native effect (Developer ID + hardened runtime + timestamp)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$PLUGIN"

echo "==> Building the installer app"
APP="$DIST/colourMatik Installer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp install.command "$APP/Contents/Resources/install.command"; chmod +x "$APP/Contents/Resources/install.command"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>colourMatik Installer</string>
  <key>CFBundleDisplayName</key><string>colourMatik Installer</string>
  <key>CFBundleIdentifier</key><string>com.catheadai.colourmatik.installer</string>
  <key>CFBundleVersion</key><string>1.0.0</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleExecutable</key><string>installer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cat > "$APP/Contents/MacOS/installer" <<'RUN'
#!/bin/bash
HERE="$(cd "$(dirname "$0")/../Resources" && pwd)"
/usr/bin/osascript <<OSA
tell application "Terminal"
  activate
  do script "clear; bash '$HERE/install.command'; echo; echo 'You can close this window.'"
end tell
OSA
RUN
chmod +x "$APP/Contents/MacOS/installer"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/installer"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"

notarize_and_staple () {  # $1 = path to bundle, $2 = short name
  local target="$1" name="$2" zip="$DIST/$2.zip"
  echo "==> Notarizing $name (uploads to Apple, waits a few minutes)"
  /usr/bin/ditto -c -k --keepParent "$target" "$zip"
  xcrun notarytool submit "$zip" --keychain-profile "$PROFILE" --wait
  echo "==> Stapling the ticket to $name"
  xcrun stapler staple "$target"
}

notarize_and_staple "$PLUGIN" "plugin"
notarize_and_staple "$APP" "installer-app"

echo "==> Verifying"
codesign -dvvv "$PLUGIN" 2>&1 | grep -iE "Authority=Developer|Timestamp|flags" | head -3
xcrun stapler validate "$PLUGIN" && echo "  ✓ effect notarized + stapled"
spctl -a -vvv "$APP" 2>&1 | tail -2 || true

# Final distributable to hand to friends: a zip of the notarized installer app.
/usr/bin/ditto -c -k --keepParent "$APP" "$DIST/colourMatik-Installer.zip"
echo
echo "DONE."
echo "  • Native effect is now notarized + stapled (commit it: git add colourmatik-fx && git commit && git push)."
echo "  • Send friends:  $DIST/colourMatik-Installer.zip  (they unzip and double-click — no warning)."
