#!/bin/bash
# Install the latest LouisaWiFi.app from GitHub Releases:
#   curl -fsSL https://raw.githubusercontent.com/madeyexz/louisa-wifi/main/install.sh | bash
set -euo pipefail

REPO=${REPO:-madeyexz/louisa-wifi}
DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "正在下載 Louisa Wi-Fi…"
curl -fsSL "https://github.com/$REPO/releases/latest/download/LouisaWiFi.zip" -o "$tmp/LouisaWiFi.zip"
ditto -x -k "$tmp/LouisaWiFi.zip" "$tmp"

pkill -x LouisaWiFi 2>/dev/null || true
rm -rf "$DEST/LouisaWiFi.app"
mv "$tmp/LouisaWiFi.app" "$DEST/"
# Releases built without signing secrets aren't notarized: drop the quarantine flag so Gatekeeper doesn't block them.
xattr -dr com.apple.quarantine "$DEST/LouisaWiFi.app" 2>/dev/null || true

open "$DEST/LouisaWiFi.app"
echo "已安裝至 $DEST/LouisaWiFi.app。請點選選單列的 ☕，並允許使用定位服務。"
