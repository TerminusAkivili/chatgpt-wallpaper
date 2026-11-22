#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
bundle="$root/.build/ChatGPT Wallpaper.app"
arch="$(uname -m)"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$root"/Resources/*.mjs "$bundle/Contents/Resources/"
cp "$root/Info.plist" "$bundle/Contents/Info.plist"
xcrun swiftc -O -target "$arch-apple-macos13.0" "$root"/Sources/*.swift \
    -o "$bundle/Contents/MacOS/ChatGPTWallpaper"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
printf '%s\n' "$bundle"
