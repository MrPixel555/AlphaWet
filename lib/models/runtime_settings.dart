class RuntimeSettings {
  const RuntimeSettings({
    this.httpPort = 10808,
    this.socksPort = 10809,
    this.enableDeviceVpn = true,
    this.vpnPermissionGranted = false,
  });

  final int httpPort;
  final int socksPort;
  final bool enableDeviceVpn;
  final bool vpnPermissionGranted;

  static const RuntimeSettings defaults = RuntimeSettings();

  RuntimeSettings copyWith({
    int? httpPort,
    int? socksPort,
    bool? enableDeviceVpn,
    bool? vpnPermissionGranted,
  }) {
    return RuntimeSettings(
      httpPort: httpPort ?? this.httpPort,
      socksPort: socksPort ?? this.socksPort,
      enableDeviceVpn: enableDeviceVpn ?? this.enableDeviceVpn,
      vpnPermissionGranted: vpnPermissionGranted ?? this.vpnPermissionGranted,
    );
  }

  bool get portsAreDistinct => httpPort != socksPort;

  String get proxySummary => 'HTTP 127.0.0.1:$httpPort • SOCKS 127.0.0.1:$socksPort';

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
