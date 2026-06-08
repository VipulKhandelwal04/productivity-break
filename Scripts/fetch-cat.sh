#!/bin/bash
# Download the optional "floating cat" video for PERSONAL USE.
#
# The video is third-party artwork (a Pinterest pin) and is intentionally NOT
# committed to this repo. This script fetches it into the repo's Resources/
# folder so `swift run` picks it up, and also into Application Support so an
# installed cat-break finds it. Without it, cat-break draws a vector cat.
#
# Make sure you have the right to use this clip. To use your own video instead,
# skip this script and set CAT_VIDEO=/path/to/your.mp4 (or .mov).
set -euo pipefail

PIN="https://in.pinimg.com/pin/2251868559305065/"
VIDEO_URL="https://v1.pinimg.com/videos/iht/expMp4/ee/b3/d9/eeb3d9c23ecdafd2e84dac9edcdb7ba2_720w.mp4"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST_REPO="$REPO/Resources/cat.mp4"
DEST_APP="$HOME/Library/Application Support/cat-break/cat.mp4"

echo "Fetching cat video (source pin: $PIN)..."
mkdir -p "$REPO/Resources" "$(dirname "$DEST_APP")"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15"
curl -fsSL -A "$UA" "$VIDEO_URL" -o "$DEST_REPO"
cp -f "$DEST_REPO" "$DEST_APP"

echo "✅ Saved:"
echo "   $DEST_REPO"
echo "   $DEST_APP"
echo "cat-break will now use the floating-cat video instead of the drawn cat."
