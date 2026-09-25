#!/bin/bash
# Builds EchoPad from source and installs it for the current user in ~/Applications.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/EchoPadKit/Version.swift)"
APP_DIR="$HOME/Applications/EchoPad.app"

if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]; then
    echo "EchoPad needs macOS 26 or later." >&2
    exit 1
fi

echo "Building EchoPad ${VERSION}…"
swift build --disable-sandbox -c release
scripts/bundle-app.sh .build/release/echopad .build/EchoPad.app "$VERSION"

if pgrep -f "EchoPad.app/Contents/MacOS/" > /dev/null; then
    echo "Quitting the running copy…"
    osascript -e 'tell application id "io.github.pieralukasz.echopad" to quit' 2>/dev/null || true
    # EchoPad 1.x used another bundle identifier.
    osascript -e 'tell application id "com.echopad.app" to quit' 2>/dev/null || true
    sleep 1
fi

# EchoPad 1.x (Python) started itself through a LaunchAgent; turn it off so both do not run.
OLD_AGENT="$HOME/Library/LaunchAgents/com.echopad.app.plist"
if [ -f "$OLD_AGENT" ]; then
    launchctl bootout "gui/$(id -u)" "$OLD_AGENT" 2>/dev/null || true
    mv "$OLD_AGENT" "$OLD_AGENT.disabled-by-echopad-2"
    echo "Disabled the EchoPad 1.x login agent."
fi
if [ -d "$APP_DIR" ] && [ "$(defaults read "$APP_DIR/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "com.echopad.app" ]; then
    BACKUP="$HOME/Applications/EchoPad 1.x.app"
    rm -rf "$BACKUP"
    mv "$APP_DIR" "$BACKUP"
    echo "Moved EchoPad 1.x to $BACKUP"
fi

mkdir -p "$HOME/Applications"
rm -rf "$APP_DIR"
ditto .build/EchoPad.app "$APP_DIR"

echo "Installed $APP_DIR"
open "$APP_DIR"
