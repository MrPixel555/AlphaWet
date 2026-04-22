#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"
OVERLAY_KT_DIR="${ROOT_DIR}/native_overlay/android/app/src/main/kotlin/com/awmanager/ui"
OVERLAY_CPP_DIR="${ROOT_DIR}/native_overlay/android/app/src/main/cpp"
OVERLAY_APP_DIR="${ROOT_DIR}/native_overlay/android/app"
ANDROID_DIR="${ROOT_DIR}/android"
JNI_LIBS_DIR="${ANDROID_DIR}/app/src/main/jniLibs"
CPP_TARGET_DIR="${ANDROID_DIR}/app/src/main/cpp"
INCLUDE_X86_64="${AW_INCLUDE_X86_64:-0}"

if [ ! -d "${ANDROID_DIR}" ]; then
  echo "[ERROR] android/ directory was not found. Run flutter create --platforms=android first."
  exit 1
fi

if [ ! -d "${OVERLAY_KT_DIR}" ]; then
  echo "[ERROR] Native Kotlin overlay is missing: ${OVERLAY_KT_DIR}"
  exit 1
fi

MAIN_ACTIVITY_PATH="$(find "${ANDROID_DIR}/app/src/main" -type f -name 'MainActivity.kt' | head -n 1 || true)"
if [ -z "${MAIN_ACTIVITY_PATH}" ]; then
  echo "[ERROR] Could not locate generated MainActivity.kt under ${ANDROID_DIR}/app/src/main"
  exit 1
fi

TARGET_KT_DIR="$(dirname "${MAIN_ACTIVITY_PATH}")"
PACKAGE_NAME="$(sed -n 's/^package[[:space:]]\+//p' "${MAIN_ACTIVITY_PATH}" | head -n 1 | tr -d '\r')"
if [ -z "${PACKAGE_NAME}" ]; then
  echo "[ERROR] Could not determine Android package name from ${MAIN_ACTIVITY_PATH}"
  exit 1
fi
PACKAGE_PATH="$(printf '%s' "${PACKAGE_NAME}" | tr '.' '/')"

mkdir -p "${TARGET_KT_DIR}"
for src in "${OVERLAY_KT_DIR}"/*.kt; do
  dest="${TARGET_KT_DIR}/$(basename "${src}")"
  sed "s/^package com\.awmanager\.ui$/package ${PACKAGE_NAME}/" "${src}" > "${dest}"
done

echo "[OK] Applied Kotlin overlay to ${TARGET_KT_DIR}"

if [ -f "${OVERLAY_APP_DIR}/proguard-rules.pro" ]; then
  cp -f "${OVERLAY_APP_DIR}/proguard-rules.pro" "${ANDROID_DIR}/app/proguard-rules.pro"
  echo "[OK] Applied Android obfuscation rules to ${ANDROID_DIR}/app/proguard-rules.pro"
fi

mkdir -p "${CPP_TARGET_DIR}"
for src in "${OVERLAY_CPP_DIR}"/*; do
  dest="${CPP_TARGET_DIR}/$(basename "${src}")"
  if [ "$(basename "${src}")" = "xray_jni.cpp" ]; then
    sed "s#com/awmanager/ui#${PACKAGE_PATH}#g" "${src}" > "${dest}"
  else
    cp -f "${src}" "${dest}"
  fi
done

echo "[OK] Applied C++ JNI overlay to ${CPP_TARGET_DIR}"

MANIFEST_PATH="${ANDROID_DIR}/app/src/main/AndroidManifest.xml"
if [ -f "${MANIFEST_PATH}" ]; then
  python3 - <<'PY' "${MANIFEST_PATH}"
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
permissions = [
    'android.permission.INTERNET',
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_SPECIAL_USE',
    'android.permission.FOREGROUND_SERVICE_SYSTEM_EXEMPTED',
]
for permission in permissions:
    marker = f'<uses-permission android:name="{permission}" />'
    if marker not in text:
        needle = '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
        text = text.replace(needle, needle + '\n    ' + marker, 1)

if 'android:extractNativeLibs=' not in text:
    text = re.sub(r'<application\b', '<application android:extractNativeLibs="true"', text, count=1)

if 'AlphaWetProxyService' not in text:
    proxy_service_block = '''
        <service
            android:name=".AlphaWetProxyService"
            android:exported="false"
            android:foregroundServiceType="specialUse">
            <property
                android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
                android:value="Keeps the user-started AlphaWet local proxy tunnel alive while the app is backgrounded." />
        </service>
'''
    text = text.replace('</application>', proxy_service_block + '    </application>', 1)

if 'AlphaWetVpnService' not in text:
    vpn_service_block = '''
        <service
            android:name=".AlphaWetVpnService"
            android:exported="false"
            android:permission="android.permission.BIND_VPN_SERVICE"
            android:foregroundServiceType="systemExempted">
            <intent-filter>
                <action android:name="android.net.VpnService" />
            </intent-filter>
        </service>
'''
    text = text.replace('</application>', vpn_service_block + '    </application>', 1)

path.write_text(text)
PY
  echo "[OK] Patched AndroidManifest.xml permissions/service/extraction flags"
fi

BUILD_KTS="${ANDROID_DIR}/app/build.gradle.kts"
BUILD_GROOVY="${ANDROID_DIR}/app/build.gradle"
if [ -f "${BUILD_KTS}" ]; then
  python3 - <<'PY' "${BUILD_KTS}"
from pathlib import Path
import re
import sys
path = Path(sys.argv[1])
text = path.read_text()
if 'externalNativeBuild {' not in text:
    text = text.replace(
        'android {\n',
        'android {\n    externalNativeBuild {\n        cmake {\n            path = file("src/main/cpp/CMakeLists.txt")\n        }\n    }\n    packaging {\n        jniLibs {\n            useLegacyPackaging = true\n        }\n    }\n',
        1,
    )
if 'isMinifyEnabled = true' not in text and 'buildTypes {' in text:
    text = text.replace(
        'buildTypes {\n',
        'buildTypes {\n        getByName("release") {\n            isMinifyEnabled = true\n            isShrinkResources = true\n            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")\n        }\n',
        1,
    )
if 'buildConfigField("long", "PLAY_CLOUD_PROJECT_NUMBER"' not in text and 'defaultConfig {' in text:
    text = text.replace(
        'defaultConfig {\n',
        'defaultConfig {\n        val playCloudProjectNumber = (project.findProperty("PLAY_CLOUD_PROJECT_NUMBER") as String?) ?: "0"\n        buildConfigField("long", "PLAY_CLOUD_PROJECT_NUMBER", "${playCloudProjectNumber}L")\n',
        1,
    )
if 'buildFeatures {' in text and 'buildConfig = true' not in text:
    text = text.replace('buildFeatures {\n', 'buildFeatures {\n        buildConfig = true\n', 1)
elif 'buildFeatures {' not in text:
    text = text.replace('android {\n', 'android {\n    buildFeatures {\n        buildConfig = true\n    }\n', 1)
if 'com.google.android.play:integrity' not in text:
    text += '\n\ndependencies {\n    implementation("com.google.android.play:integrity:1.4.0")\n}\n'
if 'com.google.android.play:core:' not in text:
    text += '\n\ndependencies {\n    implementation("com.google.android.play:core:1.10.3")\n}\n'
path.write_text(text)
PY
  echo "[OK] Patched build.gradle.kts for JNI/CMake packaging + obfuscation + Play Integrity"
elif [ -f "${BUILD_GROOVY}" ]; then
  python3 - <<'PY' "${BUILD_GROOVY}"
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
if 'externalNativeBuild {' not in text:
    text = text.replace(
        'android {\n',
        'android {\n    externalNativeBuild {\n        cmake {\n            path file("src/main/cpp/CMakeLists.txt")\n        }\n    }\n    packagingOptions {\n        jniLibs {\n            useLegacyPackaging true\n        }\n    }\n',
        1,
    )
if 'minifyEnabled true' not in text and 'buildTypes {' in text:
    text = text.replace(
        'buildTypes {\n',
        'buildTypes {\n        release {\n            minifyEnabled true\n            shrinkResources true\n            proguardFiles getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro"\n        }\n',
        1,
    )
if 'buildConfigField "long", "PLAY_CLOUD_PROJECT_NUMBER"' not in text and 'defaultConfig {' in text:
    text = text.replace(
        'defaultConfig {\n',
        'defaultConfig {\n        def playCloudProjectNumber = project.findProperty("PLAY_CLOUD_PROJECT_NUMBER") ?: "0"\n        buildConfigField "long", "PLAY_CLOUD_PROJECT_NUMBER", "${playCloudProjectNumber}L"\n',
        1,
    )
if 'com.google.android.play:integrity' not in text:
    text += '\n\ndependencies {\n    implementation "com.google.android.play:integrity:1.4.0"\n}\n'
if 'com.google.android.play:core:' not in text:
    text += '\n\ndependencies {\n    implementation "com.google.android.play:core:1.10.3"\n}\n'
path.write_text(text)
PY
  echo "[OK] Patched build.gradle for JNI/CMake packaging + obfuscation + Play Integrity"
else
  echo "[WARN] No build.gradle(.kts) found to patch automatically."
fi

mkdir -p "${JNI_LIBS_DIR}"
find "${JNI_LIBS_DIR}" -type f \( -name 'geoip.dat' -o -name 'geosite.dat' -o -name 'xray' -o -name 'libxraycore.so' \) -delete || true

copy_abi() {
  local abi="$1"
  local src="${ROOT_DIR}/assets/xray/android/${abi}/xray"
  local dest_dir="${JNI_LIBS_DIR}/${abi}"
  local dest="${dest_dir}/libxraycore.so"
  if [ ! -f "${src}" ]; then
    echo "[WARN] Missing Xray binary for ${abi}: ${src}"
    return 0
  fi
  mkdir -p "${dest_dir}"
  cp -f "${src}" "${dest}"
  chmod 755 "${dest}"
  echo "[OK] Copied ${src} -> ${dest}"
}

rm -rf "${JNI_LIBS_DIR}/x86_64"
copy_abi arm64-v8a
if [ "${INCLUDE_X86_64}" = "1" ]; then
  copy_abi x86_64
  echo "[OK] Included x86_64 runtime because AW_INCLUDE_X86_64=1"
else
  echo "[INFO] Skipping x86_64 runtime to keep APK size down. Set AW_INCLUDE_X86_64=1 if you need emulator support."
fi

echo "[OK] Android package detected as ${PACKAGE_NAME}"
echo "[OK] JNI-backed Xray runtime overlay applied"
