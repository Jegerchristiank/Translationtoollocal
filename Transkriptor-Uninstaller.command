#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Transkriptor"
SERVICE_NAME="dk.transkriptor.desktop"
KEYCHAIN_ACCOUNT="openai_api_key"

echo "=================================================="
echo "Transkriptor Uninstaller"
echo "=================================================="
echo
echo "Dette vil slette:"
echo "- App-bundle (hvis fundet)"
echo "- Interviews, jobs og cache"
echo "- Gemt OpenAI API-nøgle i Keychain"
echo
read -r -p "Fortsæt? (skriv JA): " CONFIRM
if [[ "$CONFIRM" != "JA" ]]; then
  echo "Annulleret."
  exit 0
fi

echo
echo "Stopper app (hvis den kører)..."
osascript -e 'tell application "Transkriptor" to quit' >/dev/null 2>&1 || true
sleep 1

remove_path() {
  local target="$1"
  if [[ -e "$target" ]]; then
    rm -rf "$target"
    echo "Slettet: $target"
  else
    echo "Ikke fundet: $target"
  fi
}

echo
echo "Sletter app-bundles..."
remove_path "/Applications/Transkriptor.app"
remove_path "$HOME/Applications/Transkriptor.app"

echo
echo "Sletter app-data..."
remove_path "$HOME/Library/Application Support/Transkriptor"
remove_path "$HOME/Library/Application Support/dk.transkriptor.desktop"
remove_path "$HOME/Library/Caches/Transkriptor"
remove_path "$HOME/Library/Caches/dk.transkriptor.desktop"
remove_path "$HOME/Library/Logs/Transkriptor"
remove_path "$HOME/Library/Logs/dk.transkriptor.desktop"
remove_path "$HOME/Library/Preferences/dk.transkriptor.desktop.plist"
remove_path "$HOME/Library/Saved Application State/dk.transkriptor.desktop.savedState"
remove_path "$HOME/Library/WebKit/dk.transkriptor.desktop"

echo
echo "Fjerner Keychain API-nøgle..."
security delete-generic-password -s "$SERVICE_NAME" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true
echo "Keychain-entry fjernet (hvis den fandtes)."

echo
echo "Uninstall færdig."
echo
read -r -p "Tryk Enter for at lukke..."
