#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build-assets"
VENV_DIR="$BUILD_DIR/worker-build-venv"
DIST_DIR="$BUILD_DIR/worker"
WORK_DIR="$BUILD_DIR/.pyinstaller-work"
SPEC_DIR="$BUILD_DIR/.pyinstaller-spec"
REQ_FILE="$ROOT/python/requirements-core.txt"
HASH_FILE="$DIST_DIR/.worker-input-hash"

mkdir -p "$BUILD_DIR" "$DIST_DIR"

if [[ ! -f "$REQ_FILE" ]]; then
  echo "Mangler requirements file: $REQ_FILE" >&2
  exit 1
fi

INPUT_HASH="$(
  (
    shasum "$REQ_FILE"
    find "$ROOT/python" -type f -name "*.py" | sort | while IFS= read -r file; do
      shasum "$file"
    done
  ) | shasum | awk '{print $1}'
)"
CURRENT_HASH=""
if [[ -f "$HASH_FILE" ]]; then
  CURRENT_HASH="$(cat "$HASH_FILE")"
fi

if [[ -x "$DIST_DIR/transkriptor-worker" && "$CURRENT_HASH" == "$INPUT_HASH" ]]; then
  echo "Worker binær er allerede opdateret. Springer rebuild over."
  exit 0
fi

rm -rf "$VENV_DIR" "$WORK_DIR" "$SPEC_DIR" "$DIST_DIR"
mkdir -p "$DIST_DIR"

python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

pip install --upgrade pip setuptools wheel
pip install -r "$REQ_FILE"
pip install pyinstaller

pyinstaller \
  --noconfirm \
  --clean \
  --onefile \
  --name transkriptor-worker \
  --distpath "$DIST_DIR" \
  --workpath "$WORK_DIR" \
  --specpath "$SPEC_DIR" \
  "$ROOT/python/worker.py"

chmod +x "$DIST_DIR/transkriptor-worker"
echo "$INPUT_HASH" > "$HASH_FILE"

deactivate

echo "Worker binær bygget: $DIST_DIR/transkriptor-worker"
