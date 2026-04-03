#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"
status=0

check_one() {
  local abi="$1"
  local path="${ROOT_DIR}/assets/xray/android/${abi}/xray"
  if [ -f "${path}" ]; then
    size="$(wc -c < "${path}" | tr -d ' ')"
    sha="$(sha256sum "${path}" | awk '{print $1}')"
    echo "[OK] Found assets/xray/android/${abi}/xray (${size} bytes, sha256=${sha})"
  else
    echo "[WARN] Missing assets/xray/android/${abi}/xray"
    status=1
  fi
}

check_one arm64-v8a
if [ -f "${ROOT_DIR}/assets/xray/android/x86_64/xray" ]; then
  check_one x86_64
else
  echo "[INFO] Optional asset assets/xray/android/x86_64/xray is absent. This is fine for physical arm64 devices."
fi

if [ ${status} -ne 0 ]; then
  echo "[WARN] Start/validate will not work until the required Xray asset binaries are present."
fi
