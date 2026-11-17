#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift test
swift build -c release
APP="StorageViewer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/StorageViewer "$APP/Contents/MacOS/StorageViewer"
cp packaging/Info.plist "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/StorageViewer"
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
