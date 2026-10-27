#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/ExitCheck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build
swift Scripts/make_icon.swift "$PWD/build"
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
swiftc -parse-as-library -O -framework Cocoa -framework UserNotifications \
  -o "$APP/Contents/MacOS/ExitCheck" Sources/main.swift
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "built $APP"
