#!/bin/bash
# colourMatik macOS installer — launched (as root) by "colourMatik Installer.app".
# Downloads the latest colourMatik and sets up EVERYTHING: local engine + AI, the
# Premiere panel, the native effect, and login autostart. Runs headless; the app
# shows a live progress bar by reading the PROGRESS file this script writes
# ("PCT|CAP|message" per stage; "100|100|done" on success, "FAIL|0|reason" on error).
#
# It is run as root (the app asks for the admin password once), then drops to the
# logged-in user for all user-owned steps via `asuser`.
set -u
LOG="/tmp/colourMatik-install.log"
PROGRESS="/tmp/colourMatik-progress"
exec > >(tee -a "$LOG") 2>&1
echo "== colourMatik install $(date) =="

# 666: we write as root but setup.sh refines progress as the logged-in user —
# the user must be able to write this file too, or their redirect fails.
prog() { echo "$1|$2|$3" > "$PROGRESS"; chmod 666 "$PROGRESS" 2>/dev/null || true; }

# If this script dies ANYWHERE unexpectedly, surface it on the progress bar —
# the app must never sit on a frozen bar with nothing actually running.
on_exit() {
  code=$?
  if [ "$code" -ne 0 ] && ! /usr/bin/grep -q '^FAIL' "$PROGRESS" 2>/dev/null; then
    prog FAIL 0 "install stopped unexpectedly (code $code) — see /tmp/colourMatik-install.log"
  fi
}
trap on_exit EXIT

prog 2 5 "Starting…"

CONSOLE_USER="$(/usr/bin/stat -f%Su /dev/console)"
{ [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; } && CONSOLE_USER="$(/usr/bin/ls -l /dev/console | awk '{print $3}')"
USER_UID="$(/usr/bin/id -u "$CONSOLE_USER")"
USER_HOME="$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory | awk '{print $2}')"
DEST="$USER_HOME/colourMatik"
echo "user=$CONSOLE_USER uid=$USER_UID home=$USER_HOME"

# run a command as the logged-in user, inside their GUI session
asuser() { /bin/launchctl asuser "$USER_UID" /usr/bin/sudo -u "$CONSOLE_USER" "$@"; }
notify() { asuser /usr/bin/osascript -e "display notification \"$1\" with title \"colourMatik\"" >/dev/null 2>&1 || true; }
fail()   { echo "FAIL: $1"; prog FAIL 0 "$1"; notify "Install failed — $1"; exit 1; }

# 0) download the latest source (as the user), unzip
prog 5 10 "Downloading colourMatik…"
echo "Downloading colourMatik…"
SRC="$(asuser /usr/bin/mktemp -d "/tmp/colourMatik-src.XXXXXX")"
asuser /usr/bin/curl -fsSL "https://github.com/burskozbekov/colourMatik/archive/refs/heads/main.zip" -o "$SRC/main.zip" || fail "download failed"
asuser /usr/bin/ditto -x -k "$SRC/main.zip" "$SRC" || fail "unzip failed"
INNER="$(/bin/ls -d "$SRC"/colourMatik-* 2>/dev/null | /usr/bin/head -1)"
[ -z "$INNER" ] && fail "extract failed"
echo "source: $INNER"

# 1) place the code in ~/colourMatik (user-owned)
prog 10 13 "Preparing files…"
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
  prog 13 24 "Installing Homebrew…"
  echo "Installing Homebrew (unattended)…"
  /bin/mkdir -p /opt/homebrew
  /usr/sbin/chown -R "$CONSOLE_USER":admin /opt/homebrew
  asuser /bin/bash -c 'NONINTERACTIVE=1 /bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' || echo "WARN: Homebrew install returned non-zero"
  [ -x /opt/homebrew/bin/brew ] && BREW=/opt/homebrew/bin/brew
fi

# 3) Python 3.11 + ffmpeg + git via Homebrew, then the full engine setup + AI (as user)
if [ -n "$BREW" ]; then
  prog 24 32 "Installing Python + ffmpeg…"
  echo "Installing Python 3.11 + ffmpeg + git…"
  # git is needed by setup.sh (clones CanonCGT); install it so a machine without
  # Xcode CLT doesn't hit a blocking install prompt mid-way.
  asuser /bin/bash -c "\"$BREW\" install python@3.11 ffmpeg git >/dev/null 2>&1 || \"$BREW\" install python@3.11 ffmpeg git"
  BREW_PREFIX="$("$BREW" --prefix)"
  prog 32 42 "Setting up the engine…"
  echo "Running engine setup (venv, deps, AI models)…"
  # setup.sh refines progress itself (32 → 84) via COLOURMATIK_PROGRESS
  asuser /bin/bash -c "cd '$DEST' && COLOURMATIK_PROGRESS='$PROGRESS' PATH=\"$BREW_PREFIX/bin:\$PATH\" ./setup.sh" || fail "engine setup failed"
  prog 86 90 "Installing the Premiere panel…"
  echo "Installing the Premiere panel…"
  asuser /bin/bash -c "cd '$DEST' && PATH=\"$BREW_PREFIX/bin:\$PATH\" ./install-panel.sh" || echo "WARN: panel install returned non-zero"
else
  fail "Homebrew unavailable"
fi

# 4) native effect -> shared MediaCore (we are root here, no sudo needed)
prog 90 94 "Installing the colourMatik effect…"
MC="/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore"
if [ -d "$DEST/colourmatik-fx/colourMatik.plugin" ]; then
  /bin/mkdir -p "$MC"
  /bin/rm -rf "$MC/colourMatik.plugin"
  /usr/bin/ditto "$DEST/colourmatik-fx/colourMatik.plugin" "$MC/colourMatik.plugin"
  /usr/bin/xattr -dr com.apple.quarantine "$MC/colourMatik.plugin" 2>/dev/null || true
  echo "Effect installed."
fi

# 5) start the engine at login (LaunchAgent) + now
prog 94 99 "Starting the engine…"
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
prog 100 100 "done"
notify "colourMatik is ready! Restart Premiere Pro."
exit 0
