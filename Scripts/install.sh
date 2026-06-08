#!/bin/bash
# Build cat-break (release) and install it as a login agent that runs in the
# background. Installs the binary into ~/Library/Application Support/cat-break
# and registers a launchd agent that starts it at login.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APPDIR="$HOME/Library/Application Support/cat-break"
BIN="$APPDIR/cat-break"
LOG="$APPDIR/cat-break.log"
LABEL="com.cat-break.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "Building cat-break (release)..."
( cd "$REPO" && swift build -c release )
BUILT="$REPO/.build/release/cat-break"

echo "Installing to $APPDIR"
mkdir -p "$APPDIR" "$HOME/Library/LaunchAgents"
cp -f "$BUILT" "$BIN"
chmod +x "$BIN"
# Carry the cat video over too, if it was fetched.
if [ -f "$REPO/Resources/cat.mp4" ]; then cp -f "$REPO/Resources/cat.mp4" "$APPDIR/cat.mp4"; fi

echo "Writing launch agent to $PLIST"
sed -e "s|__BINARY__|$BIN|" -e "s|__LOG__|$LOG|" "$REPO/packaging/com.cat-break.agent.plist" > "$PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "✅ Installed and running. cat-break is watching your terminal."
echo "   Cat appears after 25 min of continuous focused terminal use."
echo "   Logs:   $LOG"
echo "   Remove: $REPO/Scripts/uninstall.sh"
