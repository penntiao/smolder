#!/bin/bash
# Builds build/Smolder.app (Apple Silicon). Needs only the Command Line Tools.
#   scripts/build-app.sh            # build
#   scripts/build-app.sh --install  # build, copy to /Applications and relaunch
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/Smolder.app"

swift build -c release --arch arm64
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --show-bin-path)/Smolder" "$APP/Contents/MacOS/Smolder"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
# Ad-hoc signature: required on Apple Silicon, not a Developer ID.
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP ($VERSION, build $BUILD)"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Smolder 2>/dev/null && sleep 1 || true
    rm -rf /Applications/Smolder.app
    ditto "$APP" /Applications/Smolder.app
    if launchctl print "gui/$(id -u)/io.github.penntiao.smolder" >/dev/null 2>&1; then
        launchctl kickstart -k "gui/$(id -u)/io.github.penntiao.smolder"
    else
        open /Applications/Smolder.app
    fi
    echo "Installed to /Applications/Smolder.app"
fi
