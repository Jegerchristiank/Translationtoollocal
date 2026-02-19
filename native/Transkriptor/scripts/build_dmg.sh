#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="Transkriptor"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
STAGE_DIR="$ROOT_DIR/.staging"
STAGE_APP_BUNDLE="$STAGE_DIR/${APP_NAME}.app"
BIN_PATH="$ROOT_DIR/.build/arm64-apple-macosx/release/TranskriptorApp"
DMG_PATH="$DIST_DIR/${APP_NAME}-Installer.dmg"
DMG_RW_PATH="$DIST_DIR/${APP_NAME}-Installer-rw.dmg"
DMG_LAYOUT_DIR="$ROOT_DIR/.dmg-layout"
DMG_VOLUME_NAME="${APP_NAME} Installer"
DMG_WINDOW_LEFT=240
DMG_WINDOW_TOP=140
DMG_WINDOW_WIDTH=760
DMG_WINDOW_HEIGHT=440
DMG_WINDOW_RIGHT=$((DMG_WINDOW_LEFT + DMG_WINDOW_WIDTH))
DMG_WINDOW_BOTTOM=$((DMG_WINDOW_TOP + DMG_WINDOW_HEIGHT))
DMG_ICON_SIZE=132
DMG_TEXT_SIZE=14
APP_ICON_X=200
APP_LINK_X=560
ICON_Y=250
DMG_BG_DIR="$DMG_LAYOUT_DIR/.background"
DMG_BG_FILE="installer-background.tiff"
DMG_BG_PATH="$DMG_BG_DIR/$DMG_BG_FILE"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-$(date +%Y%m%d%H%M%S)}"
SKIP_DIST_APP="${SKIP_DIST_APP:-0}"

export COPYFILE_DISABLE=1

mkdir -p "$DIST_DIR"
mkdir -p "$STAGE_DIR"

swift build --package-path "$ROOT_DIR" -c release --product TranskriptorApp

rm -rf "$STAGE_APP_BUNDLE"
mkdir -p "$STAGE_APP_BUNDLE/Contents/MacOS"
mkdir -p "$STAGE_APP_BUNDLE/Contents/Resources"

cp -X "$BIN_PATH" "$STAGE_APP_BUNDLE/Contents/MacOS/${APP_NAME}"
chmod +x "$STAGE_APP_BUNDLE/Contents/MacOS/${APP_NAME}"

cat > "$STAGE_APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Transkriptor</string>
    <key>CFBundleDisplayName</key>
    <string>Transkriptor</string>
    <key>CFBundleIdentifier</key>
    <string>dk.transkriptor.native</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>Transkriptor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Transkriptor bruger mikrofonadgang til lokal fallback-transskription.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Transkriptor bruger talegenkendelse til lokal fallback-transskription.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

if [[ -f "$PROJECT_ROOT/build-assets/app-icon.icns" ]]; then
  cp -X "$PROJECT_ROOT/build-assets/app-icon.icns" "$STAGE_APP_BUNDLE/Contents/Resources/app-icon.icns"
  if /usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$STAGE_APP_BUNDLE/Contents/Info.plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile app-icon.icns" "$STAGE_APP_BUNDLE/Contents/Info.plist"
  else
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string app-icon.icns" "$STAGE_APP_BUNDLE/Contents/Info.plist"
  fi
fi

SIGN_IDENTITY="${MAC_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  # Fallback to ad-hoc signing so the bundle is structurally valid.
  # Without this, Gatekeeper may report the app as "beskadiget".
  SIGN_IDENTITY="-"
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Codesign: bruger ad-hoc signering (ingen distribution-certifikat sat)."
  codesign --force --deep --sign - "$STAGE_APP_BUNDLE"
else
  echo "Codesign: bruger identity '$SIGN_IDENTITY'."
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STAGE_APP_BUNDLE"
fi

codesign --verify --deep --strict --verbose=2 "$STAGE_APP_BUNDLE"

if [[ "$SKIP_DIST_APP" != "1" ]]; then
  # Best effort: mirror staged .app into dist if writable.
  if [[ -e "$APP_BUNDLE" ]]; then
    rm -rf "$APP_BUNDLE" 2>/dev/null || true
  fi
  cp -R "$STAGE_APP_BUNDLE" "$APP_BUNDLE" 2>/dev/null || true
else
  # When building installer packages we intentionally avoid leaving a local app bundle in dist
  # to prevent macOS Installer bundle-relocation to dev paths.
  rm -rf "$APP_BUNDLE" 2>/dev/null || true
  if [[ -e "$APP_BUNDLE" ]]; then
    echo "Warning: $APP_BUNDLE still exists (permissions). Remove it manually if needed."
  fi
fi

rm -rf "$DMG_LAYOUT_DIR"
mkdir -p "$DMG_LAYOUT_DIR" "$DMG_BG_DIR"
cp -R "$STAGE_APP_BUNDLE" "$DMG_LAYOUT_DIR/${APP_NAME}.app"
ln -s /Applications "$DMG_LAYOUT_DIR/Applications"
swift "$ROOT_DIR/scripts/generate_dmg_background.swift" "$DMG_BG_PATH" "$DMG_WINDOW_WIDTH" "$DMG_WINDOW_HEIGHT"

rm -f "$DMG_PATH" "$DIST_DIR/${APP_NAME}.dmg" "$DMG_RW_PATH"
hdiutil create -volname "$DMG_VOLUME_NAME" -srcfolder "$DMG_LAYOUT_DIR" -ov -format UDRW "$DMG_RW_PATH"

# Ensure no stale mounted volumes conflict with Finder disk naming.
for mounted in /Volumes/"$DMG_VOLUME_NAME"*; do
  if [[ -e "$mounted" ]]; then
    hdiutil detach "$mounted" -force -quiet || true
  fi
done

MOUNT_DIR=""
MOUNT_NAME=""
DEVICE=""
if ATTACH_OUTPUT="$(hdiutil attach "$DMG_RW_PATH" -nobrowse -noverify)"; then
  DEVICE="$(echo "$ATTACH_OUTPUT" | awk '/\/Volumes\// {print $1; exit}')"
  MOUNT_DIR="$(echo "$ATTACH_OUTPUT" | sed -n 's#.*\(/Volumes/.*\)$#\1#p' | tail -n 1)"
  MOUNT_NAME="$(basename "$MOUNT_DIR")"
  if [[ -z "$DEVICE" || -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
    echo "Kunne ikke finde mountpoint for DMG." >&2
    [[ -n "$DEVICE" ]] && hdiutil detach "$DEVICE" -force -quiet || true
    exit 1
  fi
  if [[ -n "$DEVICE" ]] && command -v osascript >/dev/null 2>&1; then
    osascript <<OSA
tell application "Finder"
  tell disk "$MOUNT_NAME"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {$DMG_WINDOW_LEFT, $DMG_WINDOW_TOP, $DMG_WINDOW_RIGHT, $DMG_WINDOW_BOTTOM}
    set iconOptions to icon view options of container window
    set arrangement of iconOptions to not arranged
    set icon size of iconOptions to $DMG_ICON_SIZE
    set text size of iconOptions to $DMG_TEXT_SIZE
    set background picture of iconOptions to file ".background:${DMG_BG_FILE}"
    set position of item "${APP_NAME}" of container window to {$APP_ICON_X, $ICON_Y}
    set position of item "Applications" of container window to {$APP_LINK_X, $ICON_Y}
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
  fi
fi

if [[ -n "$DEVICE" ]]; then
  # Finder should have written custom window metadata to .DS_Store.
  if [[ ! -f "$MOUNT_DIR/.DS_Store" ]]; then
    echo "DMG layout blev ikke gemt (.DS_Store mangler)." >&2
    hdiutil detach "$DEVICE" -quiet || hdiutil detach "$DEVICE" -force -quiet || true
    exit 1
  fi
  hdiutil detach "$DEVICE" -quiet || hdiutil detach "$DEVICE" -force -quiet || true
fi

hdiutil convert "$DMG_RW_PATH" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$DMG_RW_PATH"
rm -rf "$DMG_LAYOUT_DIR"

if [[ "$SKIP_DIST_APP" == "1" ]]; then
  echo "App bundle (staged): $STAGE_APP_BUNDLE"
else
  echo "App bundle: $APP_BUNDLE"
fi
echo "DMG: $DMG_PATH"
