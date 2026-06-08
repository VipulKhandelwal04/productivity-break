#!/bin/bash
# Build productivity_break (release) and install it as a login agent that runs
# in the background. Installs the binary into
# ~/Library/Application Support/productivity_break and registers a launchd
# agent that starts it at login.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APPDIR="$HOME/Library/Application Support/productivity_break"
BIN="$APPDIR/productivity_break"
LOG="$APPDIR/productivity_break.log"
LABEL="com.productivity_break.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "Building productivity_break (release)..."
( cd "$REPO" && swift build -c release )
BUILT="$REPO/.build/release/productivity_break"

echo "Installing to $APPDIR"
mkdir -p "$APPDIR" "$HOME/Library/LaunchAgents"
cp -f "$BUILT" "$BIN"
chmod +x "$BIN"
# Carry the break video over too, if it was fetched.
if [ -f "$REPO/Resources/productivity_break.mp4" ]; then
    cp -f "$REPO/Resources/productivity_break.mp4" "$APPDIR/productivity_break.mp4"
fi

echo "Writing launch agent to $PLIST"
sed -e "s|__BINARY__|$BIN|" -e "s|__LOG__|$LOG|" \
    "$REPO/packaging/com.productivity_break.agent.plist" > "$PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "✅ Installed and running. productivity_break is watching your terminal."
echo "   Break appears after 25 min of continuous focused terminal use."
echo "   Logs:   $LOG"
echo "   Remove: $REPO/Scripts/uninstall.sh"
