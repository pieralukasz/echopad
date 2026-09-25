#!/bin/bash
# Packages the release binary into EchoPad.app with the Liquid Glass icon.
set -euo pipefail

BINARY="${1:-.build/release/echopad}"
APP_DIR="${2:-EchoPad.app}"
VERSION="${3:-2.0.0}"
BUNDLE_ID="io.github.pieralukasz.echopad"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/echopad"

# SwiftPM resource bundles (FluidAudio ships some) must sit in Resources.
find .build -maxdepth 6 -type d -name '*_*.bundle' -path '*release*' -print0 2>/dev/null |
    while IFS= read -r -d '' bundle; do
        ditto "$bundle" "$APP_DIR/Contents/Resources/$(basename "$bundle")"
    done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Compiles the layered Liquid Glass icon into Assets.car plus an EchoPad.icns fallback.
# actool only accepts absolute paths.
RESOURCES_DIR="$(cd "$APP_DIR/Contents/Resources" && pwd)"
xcrun actool "$REPO_DIR/Resources/EchoPad.icon" \
    --compile "$RESOURCES_DIR" \
    --output-partial-info-plist "$(mktemp -t echopad-icon).plist" \
    --app-icon EchoPad --include-all-app-icons \
    --enable-on-demand-resources NO --development-region en \
    --target-device mac --minimum-deployment-target 26.0 --platform macosx \
    --errors --warnings > /dev/null

cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>echopad</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>EchoPad</string>
    <key>CFBundleDisplayName</key>
    <string>EchoPad</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>CFBundleIconFile</key>
    <string>EchoPad</string>
    <key>CFBundleIconName</key>
    <string>EchoPad</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>EchoPad records your side of the conversation and transcribes it on this Mac.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>EchoPad records the other side of your calls and transcribes it on this Mac. Nothing is uploaded.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Only used when you choose ScreenCaptureKit to record system audio. EchoPad never records your screen.</string>
</dict>
</plist>
PLIST

# An ad-hoc signature is pinned to this exact build's hash, so macOS would forget
# the Microphone and System Audio grants after every rebuild. Naming the bundle
# identifier as the requirement keeps them across updates.
codesign --force --deep --sign - --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP_DIR"

echo "Built $APP_DIR"
