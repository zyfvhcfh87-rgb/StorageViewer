#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift test
swift build -c release
APP="StorageViewer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp .build/release/StorageViewer "$APP/Contents/MacOS/StorageViewer"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/StorageViewer"
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
