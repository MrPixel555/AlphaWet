#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"
OVERLAY_SRC_DIR="${ROOT_DIR}/native_overlay/android/app/src/main/kotlin/com/awmanager/ui"
ANDROID_DIR="${ROOT_DIR}/android"

if [ ! -d "${ANDROID_DIR}" ]; then
  echo "[ERROR] android/ directory was not found. Run flutter create --platforms=android first."
  exit 1
fi

if [ ! -d "${OVERLAY_SRC_DIR}" ]; then
  echo "[ERROR] Native overlay source directory is missing: ${OVERLAY_SRC_DIR}"
  exit 1
fi

MAIN_ACTIVITY_PATH="$(find "${ANDROID_DIR}/app/src/main" -type f -name 'MainActivity.kt' | head -n 1 || true)"
if [ -z "${MAIN_ACTIVITY_PATH}" ]; then
  echo "[ERROR] Could not locate generated MainActivity.kt under ${ANDROID_DIR}/app/src/main"
  exit 1
fi

TARGET_DIR="$(dirname "${MAIN_ACTIVITY_PATH}")"
PACKAGE_NAME="$(sed -n 's/^package[[:space:]]\+//p' "${MAIN_ACTIVITY_PATH}" | head -n 1 | tr -d '\r')"
if [ -z "${PACKAGE_NAME}" ]; then
  echo "[ERROR] Could not determine Android package name from ${MAIN_ACTIVITY_PATH}"
  exit 1
fi

mkdir -p "${TARGET_DIR}"
for src in "${OVERLAY_SRC_DIR}"/*.kt; do
  dest="${TARGET_DIR}/$(basename "${src}")"
  sed "s/^package com\.awmanager\.ui$/package ${PACKAGE_NAME}/" "${src}" > "${dest}"
done

MANIFEST_PATH="${ANDROID_DIR}/app/src/main/AndroidManifest.xml"
if [ -f "${MANIFEST_PATH}" ]; then
  python3 - <<'PY2' "${MANIFEST_PATH}"
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
manifest_open = '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
if 'android.permission.INTERNET' not in text and manifest_open in text:
    text = text.replace(
        manifest_open,
        manifest_open + '\n    <uses-permission android:name="android.permission.INTERNET" />',
        1,
    )
path.write_text(text)
PY2
fi

echo "[OK] Applied Android runtime overlay to ${TARGET_DIR}"
echo "[OK] Android package detected as ${PACKAGE_NAME}"
echo "[OK] Xray will be loaded from Flutter assets at runtime; nothing is copied into jniLibs."
