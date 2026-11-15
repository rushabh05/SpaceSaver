#!/bin/bash
# Captures marketing screenshots of SpaceSaver filled with made-up sample data (demo mode), so no
# real files or names appear. The app walks through its screens and this script grabs each window
# with screencapture. Needs Screen Recording permission for your terminal.
#
#   scripts/capture-tour.sh [path/to/SpaceSaver.app] [output-dir]
#
# Nothing is scanned or cleaned: demo mode only simulates.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/SpaceSaver.app}"
OUT="${2:-marketing/screens}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
[ -d "$APP" ] || { echo "No app at $APP. Run scripts/build-app.sh first." >&2; exit 1; }

# A normal launch through LaunchServices, so the window is the active one in the captures.
open -n "$APP" --env SPACESAVER_TOUR="$OUT" --env SPACESAVER_TOUR_EXTERNAL=1 \
  --args -AppleLocale en_US -AppleLanguages '(en)'

start=$SECONDS
seen_running=0
while (( SECONDS - start < 180 )); do
  for request in "$OUT"/*.request; do
    [ -e "$request" ] || continue
    name="${request%.request}"
    [ -e "$name.png" ] && continue
    screencapture -x -l"$(cat "$request")" "$name.tmp.png" && mv "$name.tmp.png" "$name.png"
    echo "  $(basename "$name").png"
  done
  if pgrep -f "$APP/Contents/MacOS/SpaceSaver" >/dev/null; then seen_running=1
  elif (( seen_running )); then break
  fi
  sleep 0.1
done
echo "✓ $(ls "$OUT"/*.png | wc -l | tr -d ' ') screens in $OUT"
