#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DMG_PATH="$ROOT_DIR/dist/Transkriptor-Installer.dmg"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG ikke fundet: $DMG_PATH" >&2
  exit 1
fi

: "${NOTARY_PROFILE:?Sæt NOTARY_PROFILE til et notarytool keychain profile navn.}"

xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"

spctl -a -vv "$DMG_PATH" || true

echo "Notarization færdig: $DMG_PATH"
