#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${1:-$PWD}"
BUILD_ROOT="${2:-/tmp/alphawet}"
PROJECT_NAME="alphawet"
ANDROID_ORG="com.alphawet"

rm -rf "${BUILD_ROOT}"
flutter create \
  --platforms=android \
  --project-name "${PROJECT_NAME}" \
  --org "${ANDROID_ORG}" \
  "${BUILD_ROOT}"

rsync -av \
  --exclude='.git' \
  --exclude='.github' \
  --exclude='/android/' \
  --exclude='README.md' \
  --exclude='crash.sh' \
  --exclude='git' \
  --exclude='tool/fetch_desktop_xray.py' \
  --exclude='tool/patch_windows_manifest.py' \
  --exclude='tool/select_desktop_runtime.py' \
  "${REPO_DIR}/" "${BUILD_ROOT}/"

if [ -f "${BUILD_ROOT}/pubspec.yaml" ]; then
  python3 - <<'PY' "${BUILD_ROOT}/pubspec.yaml"
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace('    - assets/xray/desktop/\n', '')
path.write_text(text)
PY
fi

bash "${BUILD_ROOT}/tool/prepare_android_runtime.sh" "${BUILD_ROOT}"
bash "${BUILD_ROOT}/tool/verify_xray_assets.sh" "${BUILD_ROOT}"

echo "[OK] Android project prepared at ${BUILD_ROOT}"
