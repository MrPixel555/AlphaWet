# Device VPN Status

What is implemented in this revision:
- settings UI for custom HTTP and SOCKS listener ports
- persisted runtime settings
- Android VPN permission request flow wired through the native bridge
- generated Xray JSON rebuilt when runtime settings change
- runtime bridge receives the selected HTTP/SOCKS ports

What is **not** fully implemented yet:
- native TUN packet forwarding for true whole-device capture
- a finished foreground `VpnService` pipeline that forwards device traffic into Xray

So the new device-VPN switch is intentionally marked **experimental**.
