#!/bin/bash
# colourMatik macOS installer — launched (as root) by "colourMatik Installer.app".
# Downloads the latest colourMatik and sets up EVERYTHING: local engine + AI, the
# Premiere panel, the native effect, and login autostart. Runs headless in the
# background and notifies the logged-in user when it is ready.
#
# It is run as root (the app asks for the admin password once), then drops to the
# logged-in user for all user-owned steps via `asuser`.
set -u
LOG="/tmp/colourMatik-install.log"
exec > >(tee -a "$LOG") 2>&1
echo "== colourMatik install $(date) =="

CONSOLE_USER="$(/usr/bin/stat -f%Su /dev/console)"
{ [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; } && CONSOLE_USER="$(/usr/bin/ls -l /dev/console | awk '{print $3}')"
USER_UID="$(/usr/bin/id -u "$CONSOLE_USER")"
USER_HOME="$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory | awk '{print $2}')"
DEST="$USER_HOME/colourMatik"
echo "user=$CONSOLE_USER uid=$USER_UID home=$USER_HOME"

# run a command as the logged-in user, inside their GUI session
asuser() { /bin/launchctl asuser "$USER_UID" /usr/bin/sudo -u "$CONSOLE_USER" "$@"; }
notify() { asuser /usr/bin/osascript -e "display notification \"$1\" with title \"colourMatik\"" >/dev/null 2>&1 || true; }
fail()   { echo "FAIL: $1"; notify "Install failed — $1"; asuser /usr/bin/osascript -e "display dialog \"colourMatik couldn't finish installing.\n\n$1\n\nCheck your internet connection and run the installer again.\" buttons {\"OK\"} default button 1 with title \"colourMatik\" with icon stop" >/dev/null 2>&1 || true; exit 1; }

notify "Installing… this takes about 10–20 minutes."

# 0) download the latest source (as the user), unzip
echo "Downloading colourMatik…"
SRC="$(asuser /usr/bin/mktemp -d "/tmp/colourMatik-src.XXXXXX")"
asuser /usr/bin/curl -fsSL "https://github.com/burskozbekov/colourMatik/archive/refs/heads/main.zip" -o "$SRC/main.zip" || fail "download failed"
asuser /usr/bin/ditto -x -k "$SRC/main.zip" "$SRC" || fail "unzip failed"
INNER="$(/bin/ls -d "$SRC"/colourMatik-* 2>/dev/null | /usr/bin/head -1)"
[ -z "$INNER" ] && fail "extract failed"
echo "source: $INNER"

# 1) place the code in ~/colourMatik (user-owned)
/bin/rm -rf "$DEST"; /bin/mkdir -p "$DEST"
/usr/bin/ditto "$INNER" "$DEST"
/usr/sbin/chown -R "$CONSOLE_USER" "$DEST"
/usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# 2) Homebrew (only if missing). Pre-create the prefix owned by the user so the
#    unattended installer needs no password.
BREW=""
[ -x /opt/homebrew/bin/brew ] && BREW=/opt/homebrew/bin/brew
[ -x /usr/local/bin/brew ]   && BREW=/usr/local/bin/brew
if [ -z "$BREW" ]; then
  echo "Installing Homebrew (unattended)…"
  notify "Installing Homebrew…"
  /bin/mkdir -p /opt/homebrew
  /usr/sbin/chown -R "$CONSOLE_USER":admin /opt/homebrew
  asuser /bin/bash -c 'NONINTERACTIVE=1 /bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' || echo "WARN: Homebrew install returned non-zero"
  [ -x /opt/homebrew/bin/brew ] && BREW=/opt/homebrew/bin/brew
fi

# 3) Python 3.11 + ffmpeg via Homebrew, then the full engine setup + AI (as user)
if [ -n "$BREW" ]; then
  echo "Installing Python 3.11 + ffmpeg + git…"
  notify "Installing Python + ffmpeg…"
  # git is needed by setup.sh (clones CanonCGT); install it so a machine without
  # Xcode CLT doesn't hit a blocking install prompt mid-way.
  asuser /bin/bash -c "\"$BREW\" install python@3.11 ffmpeg git >/dev/null 2>&1 || \"$BREW\" install python@3.11 ffmpeg git"
  BREW_PREFIX="$("$BREW" --prefix)"
  echo "Running engine setup (venv, deps, AI models)…"
  notify "Setting up the engine + AI (this is the long part)…"
  asuser /bin/bash -c "cd '$DEST' && PATH=\"$BREW_PREFIX/bin:\$PATH\" ./setup.sh" || fail "engine setup failed"
  echo "Installing the Premiere panel…"
  asuser /bin/bash -c "cd '$DEST' && PATH=\"$BREW_PREFIX/bin:\$PATH\" ./install-panel.sh" || echo "WARN: panel install returned non-zero"
else
  fail "Homebrew unavailable"
fi

# 4) native effect -> shared MediaCore (we are root here, no sudo needed)
MC="/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore"
if [ -d "$DEST/colourmatik-fx/colourMatik.plugin" ]; then
  /bin/mkdir -p "$MC"
  /bin/rm -rf "$MC/colourMatik.plugin"
  /usr/bin/ditto "$DEST/colourmatik-fx/colourMatik.plugin" "$MC/colourMatik.plugin"
  /usr/bin/xattr -dr com.apple.quarantine "$MC/colourMatik.plugin" 2>/dev/null || true
  echo "Effect installed."
fi

# 5) start the engine at login (LaunchAgent) + now
if [ -n "${BREW:-}" ] && [ -d "$DEST/.venv" ]; then
  BREW_PREFIX="$("$BREW" --prefix)"
  PLIST="$USER_HOME/Library/LaunchAgents/com.colourmatik.engine.plist"
  asuser /bin/mkdir -p "$USER_HOME/Library/LaunchAgents" "$USER_HOME/Library/Logs"
  /bin/cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.colourmatik.engine</string>
  <key>ProgramArguments</key><array>
    <string>$DEST/.venv/bin/python</string><string>-u</string><string>-m</string><string>colourmatik.webapp</string>
  </array>
  <key>WorkingDirectory</key><string>$DEST</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$BREW_PREFIX/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string><key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$USER_HOME/Library/Logs/colourmatik-engine.log</string>
  <key>StandardErrorPath</key><string>$USER_HOME/Library/Logs/colourmatik-engine.log</string>
</dict></plist>
PL
  /usr/sbin/chown "$CONSOLE_USER" "$PLIST"
  asuser /bin/launchctl bootout "gui/$USER_UID/com.colourmatik.engine" 2>/dev/null || true
  asuser /bin/launchctl bootstrap "gui/$USER_UID" "$PLIST" 2>/dev/null || \
  asuser /bin/launchctl load "$PLIST" 2>/dev/null || true
  echo "Engine autostart configured."
fi

# clean up the download
/bin/rm -rf "$SRC" 2>/dev/null || true

echo "== colourMatik install done $(date) =="
notify "colourMatik is ready! Restart Premiere Pro."
asuser /usr/bin/osascript -e 'display dialog "colourMatik is installed. 🦎\n\nRestart Premiere Pro, then open  Window ▸ UXP Plugins ▸ colourMatik.\n\nPick a reference clip and a target clip, then Match & Apply." buttons {"Great"} default button 1 with title "colourMatik" with icon note' >/dev/null 2>&1 || true
exit 0
