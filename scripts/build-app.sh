#!/bin/bash
# Builds build/SpaceSaver.app (and optionally a DMG) using only the Swift toolchain.
#
#   scripts/build-app.sh            # release build, ad-hoc signed
#   scripts/build-app.sh --dmg      # also create build/SpaceSaver.dmg
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh --dmg
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.0.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
OUT="build"
APP="$OUT/SpaceSaver.app"
MAKE_DMG=false
[[ "${1:-}" == "--dmg" ]] && MAKE_DMG=true

echo "▸ Compiling (release)…"
swift build -c release --product SpaceSaverApp
swift build -c release --product spacesaver
BIN="$(swift build -c release --show-bin-path)"

echo "▸ Assembling $APP"
mkdir -p "$OUT"
if [ -d "$APP" ]; then mv "$APP" "$OUT/.old-$BUILD_NUMBER.app" && rm -rf "$OUT/.old-$BUILD_NUMBER.app"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/SpaceSaverApp" "$APP/Contents/MacOS/SpaceSaver"
cp "$BIN/spacesaver" "$APP/Contents/Helpers/spacesaver"

echo "▸ Drawing icon"
ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$OUT/AppIcon-1024.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$OUT/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$OUT/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SpaceSaver</string>
  <key>CFBundleDisplayName</key><string>SpaceSaver</string>
  <key>CFBundleIdentifier</key><string>com.spacesaver.app</string>
  <key>CFBundleExecutable</key><string>SpaceSaver</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>SpaceSaver. Local-first disk cleanup for developers.</string>
  <key>NSDesktopFolderUsageDescription</key><string>SpaceSaver looks for code projects and large files on your Desktop. Nothing is removed without your confirmation.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>SpaceSaver looks for code projects, build artifacts and large files in Documents. Nothing is removed without your confirmation.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>SpaceSaver finds old installers and archives in Downloads. Nothing is removed without your confirmation.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>SpaceSaver can map external drives you choose to scan.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Signing"
IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP/Contents/Helpers/spacesaver"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP" && echo "  signature OK ($([ "$IDENTITY" = "-" ] && echo ad-hoc || echo "$IDENTITY"))"

if $MAKE_DMG; then
  echo "▸ Creating DMG"
  STAGE="$OUT/dmg-stage"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -sf /Applications "$STAGE/Applications"
  hdiutil create -volname "SpaceSaver" -srcfolder "$STAGE" -ov -format UDZO "$OUT/SpaceSaver.dmg" >/dev/null
  rm -rf "$STAGE"
  echo "  $OUT/SpaceSaver.dmg ($(du -h "$OUT/SpaceSaver.dmg" | cut -f1))"
fi

echo "✓ $APP ($(du -sh "$APP" | cut -f1))"
