# Signing & notarizing colourMatik (for distribution)

This makes the native effect and the installer install on any Mac with **zero
Gatekeeper warnings**. macOS only. Requires a paid **Apple Developer** account.

## One-time setup

**1. Developer ID Application certificate** — you already have one if this prints a line:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

If not, create it in **Xcode ▸ Settings ▸ Accounts ▸ (your team) ▸ Manage Certificates ▸ + ▸ Developer ID Application**.

**2. An app-specific password** for notarization:
- Go to **appleid.apple.com ▸ Sign-In and Security ▸ App-Specific Passwords ▸ generate one** (name it e.g. `notarytool`). Copy it.

**3. Store the notary credentials once** (paste the app-specific password when asked):

```bash
xcrun notarytool store-credentials colourmatik \
   --apple-id "YOUR_APPLE_ID_EMAIL" \
   --team-id PCH6L56487
```

## Build the notarized bundles

```bash
./notarize.sh
```

This signs the effect, builds a **colourMatik Installer.app**, notarizes both, staples the
tickets, and writes `dist/colourMatik-Installer.zip`.

- **Effect:** commit the now-notarized plugin — `git add colourmatik-fx && git commit && git push`.
- **Installer:** send friends `dist/colourMatik-Installer.zip`; they unzip and double-click
  **colourMatik Installer** — no warning.
