# AW Manager UI

A Flutter Material 3 app for importing `.aw` configs, building Xray JSON, and launching a **real Android Xray-core process** when the Xray binaries are packaged into the app assets.

## What this build does

- opens a native file picker
- accepts only `.aw` files
- validates imports and builds Xray client JSON
- lets the user configure local listener ports from inside the app
- defaults to:
  - HTTP: `127.0.0.1:10808`
  - SOCKS: `127.0.0.1:10809`
- starts and stops a real Android `xray` process through a Flutter `MethodChannel`
- exposes Android VPN permission as an app setting for future device-wide mode
- exports application logs

## Important limitation

This repository now includes a **device-VPN settings toggle and Android VPN permission flow**, but it still **does not implement a native TUN bridge**.

That means:
- the app launches **real Xray-core**, not a fake mock runtime
- custom HTTP/SOCKS listener ports are applied to the generated Xray config and native runtime checks
- the **device-wide VPN switch is experimental scaffolding**, not a finished full-device tunnel
- the proven runtime path is still the local HTTP/SOCKS proxy listeners

## Where to place the Xray binaries

Download the Android Xray-core release that matches your target ABIs and place the extracted binaries at these exact paths **before building**:

- `assets/xray/android/arm64-v8a/xray`
- `assets/xray/android/x86_64/xray`

Optional resource files:

- `assets/xray/common/geoip.dat`
- `assets/xray/common/geosite.dat`

## How to prepare the Android project locally

If your repo does not have `android/` yet, generate it first:

```bash
flutter create --platforms=android --project-name aw_manager_ui --org com.awmanager .
```

Then apply the native Android overlay. The script automatically detects the generated Android package and rewrites the Kotlin overlay to match it:

```bash
bash tool/prepare_android_runtime.sh .
```

Then fetch packages and build:

```bash
flutter pub get
flutter test
flutter analyze
flutter build apk --release
```

## GitHub Actions build

The workflow in `.github/workflows/android-universal.yml`:
- generates a fresh Android scaffold through `tool/ci_prepare_android_project.sh`
- overlays this repository's Flutter source
- rewrites the Kotlin package name to match the generated Android project
- verifies whether real Xray binaries are packaged or only placeholders are present
- runs tests and analysis
- builds a universal release APK
- uploads the prepared project snapshot if the CI job fails

## Secure import notes

Secure envelope import now expects cryptographic material to be supplied via `--dart-define`:

- `AW_TRANSPORT_KEY_BASE64`
- `AW_ED25519_PUBLIC_KEY_BASE64`
- `AW_ALLOW_LEGACY_PLAINTEXT_IMPORT`

Legacy plaintext import is disabled by default.
