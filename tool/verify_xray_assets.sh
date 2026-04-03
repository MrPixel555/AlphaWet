#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"
ARM64_BIN="${ROOT_DIR}/assets/xray/android/arm64-v8a/xray"
X86_64_BIN="${ROOT_DIR}/assets/xray/android/x86_64/xray"
ARM64_ZIP="${ROOT_DIR}/Xray-android-arm64-v8a.zip"
AMD64_ZIP="${ROOT_DIR}/Xray-android-amd64.zip"

status=0
for path in "${ARM64_BIN}" "${X86_64_BIN}"; do
  if [ -f "${path}" ]; then
    size="$(wc -c < "${path}" | tr -d ' ')"
    sha="$(sha256sum "${path}" | awk '{print $1}')"
    echo "[OK] Found $(realpath --relative-to="${ROOT_DIR}" "${path}") (${size} bytes, sha256=${sha})"
  else
    echo "[WARN] Missing $(realpath --relative-to="${ROOT_DIR}" "${path}")"
    status=1
  fi
done

if [ -f "${ARM64_ZIP}" ]; then
  echo "[OK] Found release archive $(basename "${ARM64_ZIP}")"
fi
if [ -f "${AMD64_ZIP}" ]; then
  echo "[OK] Found release archive $(basename "${AMD64_ZIP}")"
fi

if [ ${status} -ne 0 ]; then
  echo "[WARN] APK can still compile, but Xray validate/start will not work until real Android binaries are added."
  echo "[WARN] Either place real binaries at assets/xray/android/arm64-v8a/xray and assets/xray/android/x86_64/xray,"
  echo "[WARN] or drop the official release zips into the project root as:"
  echo "[WARN]   Xray-android-arm64-v8a.zip"
  echo "[WARN]   Xray-android-amd64.zip"
  echo "[WARN] then run tool/prepare_android_runtime.sh before building."
fi
