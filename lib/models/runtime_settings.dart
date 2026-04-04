enum RuntimeMode { vpn, proxy }

class RuntimeSettings {
  const RuntimeSettings({
    this.httpPort = 10808,
    this.socksPort = 10809,
    RuntimeMode? mode,
    bool? enableDeviceVpn,
    this.vpnPermissionGranted = false,
  }) : mode = mode ?? ((enableDeviceVpn ?? false) ? RuntimeMode.vpn : RuntimeMode.proxy);

  final int httpPort;
  final int socksPort;
  final RuntimeMode mode;
  final bool vpnPermissionGranted;

  static const RuntimeSettings defaults = RuntimeSettings(mode: RuntimeMode.vpn);

  bool get enableDeviceVpn => mode == RuntimeMode.vpn;
  bool get isProxyMode => mode == RuntimeMode.proxy;

  RuntimeSettings copyWith({
    int? httpPort,
    int? socksPort,
    RuntimeMode? mode,
    bool? enableDeviceVpn,
    bool? vpnPermissionGranted,
  }) {
    final RuntimeMode resolvedMode = mode ??
        (enableDeviceVpn != null
            ? (enableDeviceVpn ? RuntimeMode.vpn : RuntimeMode.proxy)
            : this.mode);

    return RuntimeSettings(
      httpPort: httpPort ?? this.httpPort,
      socksPort: socksPort ?? this.socksPort,
      mode: resolvedMode,
      vpnPermissionGranted: vpnPermissionGranted ?? this.vpnPermissionGranted,
    );
  }

  bool get portsAreDistinct => httpPort != socksPort;

  String get proxySummary => 'HTTP 127.0.0.1:$httpPort • SOCKS 127.0.0.1:$socksPort';

  String get modeLabel => enableDeviceVpn ? 'VPN' : 'Proxy';

  String? validate() {
    if (!_isValidPort(httpPort)) {
      return 'HTTP port must be between 1 and 65535.';
    }
    if (!_isValidPort(socksPort)) {
      return 'SOCKS port must be between 1 and 65535.';
    }
    if (httpPort == socksPort) {
      return 'HTTP and SOCKS ports must be different.';
    }
    return null;
  }

  static bool _isValidPort(int value) => value >= 1 && value <= 65535;
}
