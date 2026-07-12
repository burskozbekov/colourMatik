#!/usr/bin/env bash
# Build (and optionally sign + notarize) the one-double-click macOS installer
# colourMatik-Installer.pkg. The code is bundled in the payload, so no git /
# Xcode CLT is needed on the user's Mac; the postinstall runs the full setup.
#
#   ./mac/pkg/build-pkg.sh            # unsigned (for local testing)
#   ./mac/pkg/build-pkg.sh sign       # sign + notarize + staple (needs certs)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$ROOT"
MODE="${1:-unsigned}"
VER="1.2.0"
ID="com.catheadai.colourmatik"
TEAM="PCH6L56487"
INSTALLER_IDENTITY="Developer ID Installer: Sevki Bugra Ozbek ($TEAM)"
PROFILE="colourmatik"

BUILD="$ROOT/mac/pkg/build"; rm -rf "$BUILD"; mkdir -p "$BUILD"
STAGE="$BUILD/root/Library/Application Support/colourMatik-stage"
mkdir -p "$STAGE"

echo "==> Staging bundled code (git-tracked, minus heavy non-runtime files)"
git archive --format=tar HEAD | ( cd "$STAGE" && tar -xf - )
# drop things the runtime doesn't need, to keep the pkg small
rm -rf "$STAGE/assets" "$STAGE/mac" "$STAGE/.github" "$STAGE/windows/setup" \
       "$STAGE"/*.md "$STAGE"/chameleon-icon-source.png 2>/dev/null || true
echo "    staged $(du -sh "$STAGE" | awk '{print $1}')"

echo "==> Scripts"
SCRIPTS="$BUILD/scripts"; mkdir -p "$SCRIPTS"
cp "$ROOT/mac/pkg/postinstall" "$SCRIPTS/postinstall"; chmod +x "$SCRIPTS/postinstall"

echo "==> pkgbuild (component)"
pkgbuild --root "$BUILD/root" --scripts "$SCRIPTS" \
         --identifier "$ID" --version "$VER" --install-location / \
         "$BUILD/component.pkg"

echo "==> productbuild (distribution + welcome)"
RES="$BUILD/resources"; mkdir -p "$RES"
cat > "$RES/welcome.html" <<'HTML'
<!DOCTYPE html><html><body style="font-family:-apple-system,Helvetica;margin:18px;color:#222">
<h2 style="margin:0 0 8px">colourMatik for Premiere Pro</h2>
<p>This installs everything for you: the local engine + AI, the Premiere panel, and the native effect.</p>
<p>It downloads a few things the first time, so it can take <b>10&ndash;20 minutes</b>. Just let it run.</p>
<p>When it finishes, <b>restart Premiere Pro</b> and open <b>Window &rsaquo; UXP Plugins &rsaquo; colourMatik</b>.</p>
<p style="color:#888">Free &middot; Local AI &middot; by Sevki Bugra Ozbek &middot; catheadai.com</p>
</body></html>
HTML
cat > "$BUILD/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>colourMatik</title>
  <welcome file="welcome.html"/>
  <options customize="never" require-scripts="true" rootVolumeOnly="true"/>
  <domains enable_localSystem="true"/>
  <pkg-ref id="$ID"/>
  <choices-outline><line choice="default"/></choices-outline>
  <choice id="default" title="colourMatik"><pkg-ref id="$ID"/></choice>
  <pkg-ref id="$ID" version="$VER" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
XML

OUT="$ROOT/dist/colourMatik-Installer.pkg"; mkdir -p "$ROOT/dist"
if [ "$MODE" = "sign" ]; then
  echo "==> productbuild + sign"
  productbuild --distribution "$BUILD/distribution.xml" --resources "$RES" \
               --package-path "$BUILD" --sign "$INSTALLER_IDENTITY" "$OUT"
  echo "==> Notarizing (uploads to Apple, waits)"
  xcrun notarytool submit "$OUT" --keychain-profile "$PROFILE" --wait
  echo "==> Stapling"
  xcrun stapler staple "$OUT"
  xcrun stapler validate "$OUT" && echo "  pkg notarized + stapled"
else
  productbuild --distribution "$BUILD/distribution.xml" --resources "$RES" \
               --package-path "$BUILD" "$OUT"
  echo "==> UNSIGNED (local test only). Run './mac/pkg/build-pkg.sh sign' to ship."
fi
echo "==> $OUT  ($(du -h "$OUT" | awk '{print $1}'))"
