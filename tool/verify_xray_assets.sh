#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"
fail=0

check_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo "[ERROR] Missing required file: $path"
    fail=1
  else
    echo "[OK] Found $path ($(wc -c < "$path") bytes)"
  fi
}

check_file "${ROOT_DIR}/assets/xray/android/arm64-v8a/xray"
check_file "${ROOT_DIR}/assets/xray/common/geoip.dat"
check_file "${ROOT_DIR}/assets/xray/common/geosite.dat"

if grep -q 'assets/xray/android/arm64-v8a/' "${ROOT_DIR}/pubspec.yaml" || grep -q 'assets/xray/android/x86_64/' "${ROOT_DIR}/pubspec.yaml"; then
  echo "[ERROR] pubspec.yaml still packages Android Xray binaries as Flutter assets. This duplicates them and inflates APK size."
  fail=1
else
  echo "[OK] pubspec.yaml does not duplicate Android Xray binaries into Flutter assets."
fi

if [ -d "${ROOT_DIR}/android/app/src/main/jniLibs" ]; then
  extra_files="$(find "${ROOT_DIR}/android/app/src/main/jniLibs" -type f ! -name '*.so' | sed -n '1,20p')"
  if [ -n "${extra_files}" ]; then
    echo "[ERROR] Non-.so files were found under android/app/src/main/jniLibs. Remove them to avoid APK bloat:"
    echo "${extra_files}"
    fail=1
  else
    echo "[OK] android/app/src/main/jniLibs contains only .so files."
  fi
fi

exit "$fail"
