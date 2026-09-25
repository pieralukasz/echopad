#!/bin/bash
# Renders Resources/EchoPad.icon to PNGs for the README and the docs site.
set -euo pipefail
cd "$(dirname "$0")/.."

ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
render() {
    "$ICTOOL" Resources/EchoPad.icon --export-image --output-file "$1" \
        --platform macOS --rendition "$2" --width 512 --height 512 --scale 2 > /dev/null
}

render Resources/AppIcon-1024.png Default
if [ -d docs-site ]; then
    render docs-site/public/icon.png Default
    render docs-site/public/icon-dark.png Dark
    sips -z 256 256 docs-site/public/icon.png --out docs-site/public/icon-256.png > /dev/null
    sips -z 64 64 docs-site/public/icon.png --out docs-site/src/app/icon.png > /dev/null
fi
echo "Rendered icon PNGs"
