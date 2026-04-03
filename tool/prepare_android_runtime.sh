#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"
OVERLAY_SRC_DIR="${ROOT_DIR}/native_overlay/android/app/src/main/kotlin/com/awmanager/ui"
ANDROID_DIR="${ROOT_DIR}/android"
NATIVE_LIBS_DIR="${ANDROID_DIR}/app/src/main/jniLibs"

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
if [ -f "${MANIFEST_PATH}" ] && ! grep -q 'android.permission.INTERNET' "${MANIFEST_PATH}"; then
  python3 - <<'PY2' "${MANIFEST_PATH}"
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
needle = '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
replacement = needle + '\n    <uses-permission android:name="android.permission.INTERNET" />'
if needle in text:
    text = text.replace(needle, replacement, 1)
path.write_text(text)
PY2
fi

mkdir -p "${NATIVE_LIBS_DIR}"
copy_native_binary() {
  local abi="$1"
  local src="${ROOT_DIR}/assets/xray/android/${abi}/xray"
  local dest_dir="${NATIVE_LIBS_DIR}/${abi}"
  local dest="${dest_dir}/libxraycore.so"
  if [ ! -f "${src}" ]; then
    echo "[WARN] Missing ${src}; ${abi} runtime will not be embedded."
    return
  fi
  mkdir -p "${dest_dir}"
  cp "${src}" "${dest}"
  chmod 755 "${dest}"
  echo "[OK] Embedded $(realpath --relative-to="${ROOT_DIR}" "${src}") -> $(realpath --relative-to="${ROOT_DIR}" "${dest}")"
}

copy_native_binary "arm64-v8a"
copy_native_binary "x86_64"

echo "[OK] Applied Android runtime overlay to ${TARGET_DIR}"
echo "[OK] Android package detected as ${PACKAGE_NAME}"
echo "[OK] Xray runtime will be loaded from nativeLibraryDir at install time."
