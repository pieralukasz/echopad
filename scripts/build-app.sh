#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/EchoPad.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/EchoPad.app"

mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

swiftc -O -o "$PROJECT_DIR/audio-capture" "$PROJECT_DIR/audio-capture.swift" \
  -framework ScreenCaptureKit -framework CoreMedia -framework AVFoundation

swift build --package-path "$PROJECT_DIR" --disable-sandbox -c release --product EchoPad

cp "$PROJECT_DIR/.build/release/EchoPad" "$APP_DIR/Contents/MacOS/EchoPad"
find "$PROJECT_DIR/.build" -type d -name 'FluidAudio_FluidAudio.bundle' -maxdepth 5 -exec ditto {} "$APP_DIR/Contents/Resources/FluidAudio_FluidAudio.bundle" \; -quit

cp "$PROJECT_DIR/macos/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/macos/PkgInfo" "$APP_DIR/Contents/PkgInfo"
/usr/libexec/PlistBuddy -c "Delete :EchoPadProjectDirectory" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :EchoPadProjectDirectory string $PROJECT_DIR" "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$INSTALL_DIR"
  ditto "$APP_DIR" "$INSTALLED_APP"
  codesign --verify --deep --strict "$INSTALLED_APP"
  echo "$INSTALLED_APP"
else
  echo "$APP_DIR"
fi
