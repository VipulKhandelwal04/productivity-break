#!/bin/bash
# Stop cat-break and remove its login agent.
set -euo pipefail

LABEL="com.cat-break.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APPDIR="$HOME/Library/Application Support/cat-break"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
pkill -x cat-break 2>/dev/null || true

echo "✅ cat-break stopped and removed from login items."
echo "   Installed files remain in: $APPDIR"
echo "   Delete them with: rm -rf \"$APPDIR\""
