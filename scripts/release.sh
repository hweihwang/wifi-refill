#!/bin/bash
# Builds, notarizes and packages a release; with --publish also tags it, uploads it to GitHub, updates the
# Homebrew tap and the appcast on hweihwang.com.
#   scripts/release.sh 1.0.0             build dist/1.0.0/Wi-Fi-Refill.dmg and check it
#   scripts/release.sh 1.0.0 --publish  then publish it
# Needs APPLE_API_KEY (path to the .p8), APPLE_API_KEY_ID and APPLE_API_ISSUER for notarization, the Sparkle key
# at $SPARKLE_KEY, and clones of hweihwang/homebrew-wifi-refill and hweihwang/hweihwang.com next to this repository.
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: scripts/release.sh VERSION [--publish]}
publish=false
[[ ${2:-} == --publish ]] && publish=true
sparkle_key=${SPARKLE_KEY:-$HOME/.appstoreconnect/private_keys/wifi-refill-sparkle-ed25519.key}
sparkle_bin=${SPARKLE_BIN:-$HOME/.local/share/sparkle/bin}
tap=${TAP_DIR:-../homebrew-wifi-refill}
site=${SITE_DIR:-../hweihwang.com}
# The file name stays the same in every release, so releases/latest/download/Wi-Fi-Refill.dmg always works.
dmg="dist/$version/Wi-Fi-Refill.dmg"
notary=(--key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" --wait)

grep -q "^## $version" CHANGELOG.md || { echo "CHANGELOG.md has no section for $version" >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
swift test

app=$(scripts/build-app.sh "$version" --release | tail -1)
lipo "$app/Contents/MacOS/WiFiRefill" -verify_arch arm64 x86_64

echo "Notarizing the app…"
mkdir -p "dist/$version"
ditto -c -k --keepParent "$app" "dist/$version/app.zip"
xcrun notarytool submit "dist/$version/app.zip" "${notary[@]}"
xcrun stapler staple "$app"
rm "dist/$version/app.zip"

echo "Building the disk image…"
staging=$(mktemp -d)
ditto "$app" "$staging/Wi-Fi Refill.app"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname "Wi-Fi Refill" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" > /dev/null
rm -rf "$staging"
codesign --force --sign "${SIGNING_IDENTITY:-Developer ID Application}" --timestamp "$dmg"
xcrun notarytool submit "$dmg" "${notary[@]}"
xcrun stapler staple "$dmg"

echo "Checking what a downloaded copy will see…"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature -v "$dmg"
mount=$(hdiutil attach -nobrowse -readonly "$dmg" | tail -1 | cut -f3)
spctl --assess --type execute -v "$mount/Wi-Fi Refill.app"
xcrun stapler validate "$mount/Wi-Fi Refill.app"
hdiutil detach "$mount" > /dev/null

signature=$("$sparkle_bin/sign_update" --ed-key-file "$sparkle_key" "$dmg")
sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
echo "$dmg"
echo "sha256 $sha"
echo "sparkle $signature"
$publish || exit 0

echo "Publishing…"
notes=$(awk -v v="## $version" '$0 ~ "^## " { on = index($0, v) == 1; next } on' CHANGELOG.md)
git tag -a "v$version" -m "Wi-Fi Refill $version"
git push origin main "v$version"
gh release create "v$version" "$dmg" --title "Wi-Fi Refill $version" --notes "$notes"
url="https://github.com/hweihwang/wifi-refill/releases/download/v$version/$(basename "$dmg")"

# Appcast: newest item first, kept on hweihwang.com so the feed address never changes.
appcast="$site/wifi-refill/appcast.xml"
build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$app/Contents/Info.plist")
html=$(printf '%s\n' "$notes" | sed -E 's/^- (.*)$/<li>\1<\/li>/' | grep '^<li>' | tr -d '\n')
item="        <item>
            <title>$version</title>
            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
            <sparkle:version>$build</sparkle:version>
            <sparkle:shortVersionString>$version</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[<ul>$html</ul>]]></description>
            <enclosure url=\"$url\" type=\"application/octet-stream\" $signature/>
        </item>"
python3 -I - "$appcast" "$item" <<'EOF'
import sys
path, item = sys.argv[1], sys.argv[2]
text = open(path).read()
marker = "<language>en</language>\n"
assert marker in text, "appcast has no channel header"
open(path, "w").write(text.replace(marker, marker + item + "\n", 1))
EOF
git -C "$site" add wifi-refill/appcast.xml
git -C "$site" commit -m "fix(site): Wi-Fi Refill $version is published"
git -C "$site" push

sed -i '' -E "s/^  version \".*\"/  version \"$version\"/; s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$tap/Casks/wifi-refill.rb"
git -C "$tap" commit -am "Wi-Fi Refill $version"
git -C "$tap" push
echo "Published $version."
