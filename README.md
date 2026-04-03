# AW Manager UI

A Flutter Material 3 mock UI that:

- opens a native file picker
- accepts only `.aw` files
- adds imported configs to a vertical list
- shows a per-config on/off switch
- shows a mock Ping button with fake latency

This repository is intentionally UI-only. It does **not** implement real VPN logic, parsing, import persistence, or real network ping.

## How to use this repo

1. Create an empty GitHub repository.
2. Upload the contents of this ZIP to that repository.
3. Push to `main` or run the workflow manually from the **Actions** tab.
4. Download the artifact named `aw-manager-ui-universal-apk`.

## What the workflow does

The workflow generates the Android scaffold from the currently installed Flutter SDK during CI, then copies this repo's Flutter source into that generated app before building a universal release APK.

That design keeps the Android/Gradle files aligned with the current Flutter version and reduces template drift.

## Output

The workflow uploads this artifact:

- `aw-manager-ui-universal-release.apk`

## Notes

- The APK is meant for testing and direct install.
- If you later want Play Store-ready signing, add a real keystore and signing secrets.
