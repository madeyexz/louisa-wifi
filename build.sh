#!/bin/bash
# Build build/LouisaWiFi.app (and a zip for GitHub Releases).
# Needs only the Xcode Command Line Tools: xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=${ARCHS:-"arm64 x86_64"}
APP=build/LouisaWiFi.app

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

bins=()
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13" app/Sources/*.swift -o "build/LouisaWiFi-$arch"
  bins+=("build/LouisaWiFi-$arch")
done
lipo -create "${bins[@]}" -output "$APP/Contents/MacOS/LouisaWiFi"
rm "${bins[@]}"

cp app/Info.plist "$APP/Contents/"
# Release builds pass VERSION=1.2.3 (from the git tag).
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
cp data/stores.json "$APP/Contents/Resources/"

# App icon: app/AppIcon.png (1024×1024) → AppIcon.icns
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size app/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) app/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Release builds set SIGN_IDENTITY ("Developer ID Application: …") and an App Store
# Connect API key (NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID) so Gatekeeper
# opens the app without warnings. Local builds get an ad-hoc signature.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --entitlements app/LouisaWiFi.entitlements --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi

ditto -c -k --keepParent "$APP" build/LouisaWiFi.zip

if [ -n "${NOTARY_KEY_PATH:-}" ]; then
  xcrun notarytool submit build/LouisaWiFi.zip --wait \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
  # Fails unless Apple accepted the submission; `xcrun notarytool log <id>` says why.
  xcrun stapler staple "$APP"
  rm build/LouisaWiFi.zip
  ditto -c -k --keepParent "$APP" build/LouisaWiFi.zip
fi
echo "Built $APP"
