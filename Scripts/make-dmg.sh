#!/bin/zsh
# Builds Folio.app and packages it as build/Folio-<version>.dmg with an Applications shortcut.
# Usage: Scripts/make-dmg.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"
./Scripts/build-app.sh "$VERSION"
STAGE=build/dmg
DMG="build/Folio-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/Folio.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Folio $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Created $DMG"
shasum -a 256 "$DMG"
