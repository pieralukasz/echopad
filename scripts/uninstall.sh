#!/bin/bash
# Removes EchoPad. Settings and the conversation library are kept unless you pass
# --purge. Transcripts in your save locations are never touched.
set -euo pipefail

PURGE=false
[ "${1:-}" = "--purge" ] && PURGE=true

osascript -e 'tell application id "io.github.pieralukasz.echopad" to quit' 2>/dev/null || true
sleep 1

rm -rf "$HOME/Applications/EchoPad.app"
echo "Removed EchoPad.app."

if $PURGE; then
    rm -rf "$HOME/Library/Application Support/EchoPad"
    echo "Removed settings and the conversation library."
    echo "The speech models in ~/Library/Application Support/FluidAudio are shared with other FluidAudio apps and were left in place."
else
    echo "Kept ~/Library/Application Support/EchoPad. Run with --purge to delete it."
fi
