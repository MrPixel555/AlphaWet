#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"
ARM64_BIN="${ROOT_DIR}/assets/xray/android/arm64-v8a/xray"
X86_64_BIN="${ROOT_DIR}/assets/xray/android/x86_64/xray"

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

if [ ${status} -ne 0 ]; then
  echo "[WARN] APK can still compile with placeholders, but runtime Xray launch will not work until the binaries are packaged."
fi
