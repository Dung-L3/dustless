#!/bin/bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package="$(cd "$here/.." && pwd)"
root="$(cd "$here/../../.." && pwd)"
engine="$root/dist/dustless"
app="$package/build/Dustless.app"

if [[ ! -x "$engine" ]]; then
  echo "error: $engine not found. Build it first:  cd $root && bun run build" >&2
  exit 1
fi

echo "==> swift build (release)"
swift build --package-path "$here" -c release

binary="$(swift build --package-path "$here" -c release --show-bin-path)/DustlessApp"

echo "==> assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Dustless"
cp "$engine" "$app/Contents/Resources/dustless"

version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$root/package.json")"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Dustless</string>
  <key>CFBundleDisplayName</key><string>Dustless</string>
  <key>CFBundleIdentifier</key><string>dev.dustless.mac</string>
  <key>CFBundleExecutable</key><string>Dustless</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$app" 2>/dev/null || echo "==> codesign unavailable, continuing unsigned"

echo "==> done: $app"
echo "    run: open '$app'"
