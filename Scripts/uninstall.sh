#!/bin/bash
# Stop productivity_break and remove its login agent.
set -euo pipefail

LABEL="com.productivity_break.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APPDIR="$HOME/Library/Application Support/productivity_break"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
pkill -x productivity_break 2>/dev/null || true

echo "✅ productivity_break stopped and removed from login items."
echo "   Installed files remain in: $APPDIR"
echo "   Delete them with: rm -rf \"$APPDIR\""
