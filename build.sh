#!/bin/bash
# Builds Wi-Fi Autologin.app, signs it, installs it in ~/Applications and restarts it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
app=".build/Wi-Fi Autologin.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/WifiAutologin "$app/Contents/MacOS/"
cp Info.plist "$app/Contents/"
codesign --force --options runtime --sign "Developer ID Application" "$app"

pkill -x WifiAutologin || true
rm -rf ~/Applications/"Wi-Fi Autologin.app"
ditto "$app" ~/Applications/"Wi-Fi Autologin.app"
open ~/Applications/"Wi-Fi Autologin.app"
