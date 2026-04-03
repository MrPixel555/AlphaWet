#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${1:-$PWD}"
BUILD_ROOT="${2:-/tmp/aw_manager_ui}"
PROJECT_NAME="aw_manager_ui"
ANDROID_ORG="com.awmanager"

rm -rf "${BUILD_ROOT}"
flutter create \
  --platforms=android \
  --project-name "${PROJECT_NAME}" \
  --org "${ANDROID_ORG}" \
  "${BUILD_ROOT}"

rsync -av \
  --exclude='.git' \
  --exclude='.github' \
  --exclude='android' \
  "${REPO_DIR}/" "${BUILD_ROOT}/"

bash "${BUILD_ROOT}/tool/prepare_android_runtime.sh" "${BUILD_ROOT}"
bash "${BUILD_ROOT}/tool/verify_xray_assets.sh" "${BUILD_ROOT}"

echo "[OK] Android project prepared at ${BUILD_ROOT}"
