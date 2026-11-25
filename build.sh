#!/bin/bash
# Usage: ./build.sh            build build/ClipHistory.app
#        ./build.sh install    also copy it to ~/Applications and start it
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/ClipHistory.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ClipHistory "$APP/Contents/MacOS/ClipHistory"
cp Info.plist "$APP/Contents/Info.plist"
# A stable identity keeps the Accessibility permission across rebuilds; an ad hoc signature loses it each time.
IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    DEST="$HOME/Applications/ClipHistory.app"
    pkill -x ClipHistory 2>/dev/null || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "Installed and started $DEST"
fi
