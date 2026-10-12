#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="$PWD/dist/Agent Meter.app"
mkdir -p "$APP/Contents/MacOS"
/usr/bin/install -m 755 .build/release/AgentMeter "$APP/Contents/MacOS/AgentMeter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier dev.samy.AgentMeter "$APP"
printf 'Built: %s\n' "$APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/Agent Meter.app"
    if [[ -e "$DEST" ]]; then
        ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)
        if [[ "$ID" != "dev.samy.AgentMeter" ]]; then
            printf 'Refusing to replace an unrelated application: %s\n' "$DEST" >&2
            exit 1
        fi
    fi
    mkdir -p "$HOME/Applications"
    /usr/bin/ditto "$APP" "$DEST"
    printf 'Installed: %s\n' "$DEST"
fi
