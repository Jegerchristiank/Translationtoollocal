#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAIN_NATIVE="$ROOT_DIR/Transkriptor-Installer.dmg"
MAIN_NATIVE_PKG="$ROOT_DIR/Transkriptor.pkg"
MAIN_NATIVE_PKG_DMG="$ROOT_DIR/Transkriptor-PKG-Installer.dmg"
MAIN_ELECTRON="$ROOT_DIR/Transkriptor-Electron-Installer.dmg"
UNINSTALLER="$ROOT_DIR/Transkriptor-Uninstaller.command"

NATIVE_CANDIDATE="$ROOT_DIR/native/Transkriptor/dist/Transkriptor-Installer.dmg"
NATIVE_PKG_CANDIDATE="$ROOT_DIR/native/Transkriptor/dist/Transkriptor.pkg"
NATIVE_PKG_DMG_CANDIDATE="$ROOT_DIR/native/Transkriptor/dist/Transkriptor-PKG-Installer.dmg"
ELECTRON_CANDIDATE="$ROOT_DIR/dist/Transkriptor-0.1.0-arm64.dmg"

if [[ -f "$NATIVE_CANDIDATE" ]]; then
  cp -f "$NATIVE_CANDIDATE" "$MAIN_NATIVE"
fi

if [[ -f "$NATIVE_PKG_CANDIDATE" ]]; then
  cp -f "$NATIVE_PKG_CANDIDATE" "$MAIN_NATIVE_PKG"
fi

if [[ -f "$NATIVE_PKG_DMG_CANDIDATE" ]]; then
  cp -f "$NATIVE_PKG_DMG_CANDIDATE" "$MAIN_NATIVE_PKG_DMG"
fi

if [[ -f "$ELECTRON_CANDIDATE" ]]; then
  cp -f "$ELECTRON_CANDIDATE" "$MAIN_ELECTRON"
fi

if [[ ! -f "$MAIN_NATIVE" ]]; then
  echo "Manglende native installer i hovedmappen: $MAIN_NATIVE" >&2
  exit 1
fi

if [[ ! -f "$MAIN_ELECTRON" ]]; then
  echo "Manglende electron installer i hovedmappen: $MAIN_ELECTRON" >&2
  exit 1
fi

# Ensure uninstaller exists.
if [[ ! -f "$UNINSTALLER" ]]; then
  bash "$ROOT_DIR/scripts/create-uninstaller.sh"
fi

# Keep only root installers.
rm -f "$ROOT_DIR"/dist/*.dmg "$ROOT_DIR"/dist/*.pkg "$ROOT_DIR"/dist/*.blockmap 2>/dev/null || true
rm -f "$ROOT_DIR"/native/Transkriptor/dist/*.dmg "$ROOT_DIR"/native/Transkriptor/dist/*.pkg "$ROOT_DIR"/native/Transkriptor/dist/*.blockmap 2>/dev/null || true
rm -rf "$ROOT_DIR/production-downloads"

(
  cd "$ROOT_DIR"
  files=(
    "Transkriptor-Electron-Installer.dmg"
    "Transkriptor-Installer.dmg"
  )
  if [[ -f "Transkriptor.pkg" ]]; then
    files+=("Transkriptor.pkg")
  fi
  if [[ -f "Transkriptor-PKG-Installer.dmg" ]]; then
    files+=("Transkriptor-PKG-Installer.dmg")
  fi
  files+=("Transkriptor-Uninstaller.command")

  shasum -a 256 "${files[@]}" > "SHA256SUMS.txt"
)

{
  echo "Brug kun disse filer fra hovedmappen:"
  echo
  line_no=1
  if [[ -f "$MAIN_NATIVE_PKG_DMG" ]]; then
    echo "$line_no) Transkriptor-PKG-Installer.dmg (Native PKG, anbefalet)"
    line_no=$((line_no + 1))
  fi
  if [[ -f "$MAIN_NATIVE_PKG" ]]; then
    echo "$line_no) Transkriptor.pkg (Direkte PKG)"
    line_no=$((line_no + 1))
  fi
  echo "$line_no) Transkriptor-Installer.dmg (Native drag-and-drop, kompatibilitet)"
  line_no=$((line_no + 1))
  echo "$line_no) Transkriptor-Electron-Installer.dmg (Electron fallback)"
  line_no=$((line_no + 1))
  echo "$line_no) Transkriptor-Uninstaller.command (afinstallerer app + data)"
  echo
  echo "Checksums: SHA256SUMS.txt"
} > "$ROOT_DIR/INSTALLERS-USE-THIS.txt"

echo "Standardisering færdig."
echo "Installere i hovedmappen:"
ls -lh "$MAIN_NATIVE" "$MAIN_ELECTRON"
echo
echo "SHA256:"
cat "$ROOT_DIR/SHA256SUMS.txt"
