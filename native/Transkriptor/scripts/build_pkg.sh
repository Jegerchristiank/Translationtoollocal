#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/Transkriptor.app"
STAGE_APP_BUNDLE="$ROOT_DIR/.staging/Transkriptor.app"
PKG_ROOT="$ROOT_DIR/.pkgroot"
COMPONENT_PLIST="$ROOT_DIR/.pkg-components.plist"
PKG_PATH="$DIST_DIR/Transkriptor.pkg"
PKG_DMG_PATH="$DIST_DIR/Transkriptor-PKG-Installer.dmg"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-$(date +%Y%m%d%H%M%S)}"
PKG_VERSION="${PKG_VERSION:-$APP_BUILD}"

export COPYFILE_DISABLE=1

mkdir -p "$DIST_DIR"

# Build app + dmg first (ensures app bundle exists and icon is embedded)
APP_VERSION="$APP_VERSION" APP_BUILD="$APP_BUILD" SKIP_DIST_APP=1 "$ROOT_DIR/scripts/build_dmg.sh"

rm -f "$PKG_PATH"
rm -rf "$PKG_ROOT"
rm -f "$COMPONENT_PLIST"
mkdir -p "$PKG_ROOT/Applications"
cp -R "$STAGE_APP_BUNDLE" "$PKG_ROOT/Applications/Transkriptor.app"

# Disable bundle relocation so installer always targets /Applications.
pkgbuild --analyze --root "$PKG_ROOT" "$COMPONENT_PLIST"
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST"
/usr/libexec/PlistBuddy -c "Set :0:BundleHasStrictIdentifier true" "$COMPONENT_PLIST" || true
/usr/libexec/PlistBuddy -c "Set :0:BundleIsVersionChecked true" "$COMPONENT_PLIST" || true

pkgbuild \
  --root "$PKG_ROOT" \
  --install-location "/" \
  --identifier "dk.transkriptor.native" \
  --version "$PKG_VERSION" \
  --component-plist "$COMPONENT_PLIST" \
  "$PKG_PATH"

rm -f "$PKG_DMG_PATH"
hdiutil create -volname "Transkriptor Installer" -srcfolder "$PKG_PATH" -ov -format UDZO "$PKG_DMG_PATH"
rm -rf "$PKG_ROOT"
rm -f "$COMPONENT_PLIST"

echo "PKG: $PKG_PATH"
echo "PKG wrapper DMG: $PKG_DMG_PATH"
