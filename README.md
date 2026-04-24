# AlphaWet

## Play Integrity verifier

Android secure integrity mode now expects a verdict decode endpoint.
Use the free-tier Cloudflare Worker guide in `docs/play-integrity-cloudflare-worker.md`.

A Flutter Material 3 app for importing `.aw` configs, building Xray JSON, and launching Xray runtimes for Android and desktop.

## What this build does

- opens a native file picker
- accepts only `.aw` files
- validates imports and builds Xray client JSON
- lets the user configure runtime ports from inside the app
- supports Android VPN mode
- exposes a Windows TUN mode in the same settings layout
- exports application logs
- stores Windows runtime/config state in opaque sealed files under AppData/Roaming instead of readable plain preferences

## Desktop runtime packaging

Desktop Xray source binaries now stay in these source folders:

- `assets/xray/windows/`
- `assets/xray/linux/`

But only this folder is bundled into the Flutter build:

- `assets/xray/desktop/`

Before each desktop build, activate exactly one runtime:

```bash
python tool/select_desktop_runtime.py windows
# or
python tool/select_desktop_runtime.py linux
```

You can also refresh both source runtimes and activate one target in one step:

```bash
python tool/fetch_desktop_xray.py . windows
# or
python tool/fetch_desktop_xray.py . linux
```

This keeps the opposite-platform Xray binary out of the final desktop build output.

## Android runtime

Download the Android Xray-core release that matches your target ABIs and place the extracted binaries at these exact paths before building:

- `assets/xray/android/arm64-v8a/xray`
- `assets/xray/android/x86_64/xray`

Then run:

```bash
bash tool/prepare_android_runtime.sh .
```

Optional resource files:

- `assets/xray/common/geoip.dat`
- `assets/xray/common/geosite.dat`

## How to prepare the Android project locally

If your repo does not have `android/` yet, generate it first:

```bash
flutter create --platforms=android --project-name alphawet --org ir.alphacraft.alphawet .
```

Then apply the native Android overlay:

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

## Secure import notes

Secure envelope import expects cryptographic material through `--dart-define`:

- `AW_TRANSPORT_KEY_BASE64`
- `AW_ED25519_PUBLIC_KEY_BASE64`
- `AW_ALLOW_LEGACY_PLAINTEXT_IMPORT`
