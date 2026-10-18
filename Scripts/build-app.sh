#!/bin/zsh
# Builds "Folio.app" in ./build using only the Command Line Tools.
# Usage: Scripts/build-app.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"
APP="build/Folio.app"
swift build -c release
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Folio "$APP/Contents/MacOS/Folio"
swift Scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Folio</string>
  <key>CFBundleDisplayName</key><string>Folio</string>
  <key>CFBundleIdentifier</key><string>com.anshu.folio</string>
  <key>CFBundleExecutable</key><string>Folio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Folio uses Pages, Keynote and Numbers to convert Office documents to PDF.</string>
  <key>NSCameraUsageDescription</key><string>Folio uses Continuity Camera to scan documents.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $APP"
