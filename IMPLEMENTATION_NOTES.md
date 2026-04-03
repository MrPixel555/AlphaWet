# Implementation Notes

This version replaces the in-app mock runtime path with an Android `MethodChannel` bridge that can:

- validate generated Xray JSON by executing `xray run -test -c <config>`
- launch the packaged `xray` binary as a real Android process
- stop the process
- surface runtime messages and a session id back into Flutter
- request Android VPN permission from inside the app settings
- rebuild generated Xray JSON when the user changes HTTP/SOCKS listener ports

## Current scope

Implemented:
- real Xray-core start/stop/validate on Android
- asset-based binary packaging for `arm64-v8a` and `x86_64`
- secure import keys moved to `--dart-define`
- TLS parsing/build fixes
- nullable state reset fixes
- CI test step and Android overlay step
- in-app runtime settings with persisted HTTP/SOCKS ports
- Android VPN permission flow exposed as an experimental setting

Not yet implemented:
- native TUN bridge for full-device packet capture
- finished device-wide VPN routing
- foreground persistent service / reconnect logic
- proxy traffic statistics / bandwidth counters
- real ping through the launched proxy

## Binary placement

Put the extracted Xray binaries here before building:
- `assets/xray/android/arm64-v8a/xray`
- `assets/xray/android/x86_64/xray`

Optional:
- `assets/xray/common/geoip.dat`
- `assets/xray/common/geosite.dat`
