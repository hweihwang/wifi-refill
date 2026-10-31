#!/bin/bash
# Builds and signs "Wi-Fi Refill.app" in .build/app.
#   scripts/build-app.sh                 this Mac's architecture, version 0.0.0
#   scripts/build-app.sh 1.2.0 --release Apple silicon and Intel, with secure timestamps for notarization
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:-0.0.0}
release=false
[[ ${2:-} == --release ]] && release=true
identity=${SIGNING_IDENTITY:-Developer ID Application}

flags=(-c release)
$release && flags+=(--arch arm64 --arch x86_64)
swift build "${flags[@]}"
bin=$(swift build "${flags[@]}" --show-bin-path)

app=".build/app/Wi-Fi Refill.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin/WiFiRefill" "$app/Contents/MacOS/"
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$app/Contents/"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$app/Contents/Info.plist"
cp -R Resources/en.lproj Resources/vi.lproj "$app/Contents/Resources/"
xcrun actool Resources/WiFiRefill.icon --compile "$app/Contents/Resources" --app-icon WiFiRefill --include-all-app-icons \
    --output-partial-info-plist .build/app/icon.plist --development-region en --target-device mac \
    --minimum-deployment-target 14.0 --platform macosx --errors --warnings > /dev/null

# Sign from the inside out, as Sparkle's documentation describes for apps that are not sandboxed.
sign=(codesign --force --sign "$identity" --options runtime)
$release && sign+=(--timestamp)
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
"${sign[@]}" "$sparkle/XPCServices/Installer.xpc"
"${sign[@]}" --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
"${sign[@]}" "$sparkle/Autoupdate"
"${sign[@]}" "$sparkle/Updater.app"
"${sign[@]}" "$app/Contents/Frameworks/Sparkle.framework"
"${sign[@]}" "$app"
codesign --verify --deep --strict "$app"
echo "$app"
