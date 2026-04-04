enum VpnConnectionState {
  idle,
  validating,
  ready,
  connecting,
  connected,
  disconnecting,
  failed,
}

extension VpnConnectionStateX on VpnConnectionState {
  String get label {
    switch (this) {
      case VpnConnectionState.idle:
        return 'Disconnected';
      case VpnConnectionState.validating:
        return 'Validating';
      case VpnConnectionState.ready:
        return 'Ready';
      case VpnConnectionState.connecting:
        return 'Connecting';
      case VpnConnectionState.connected:
        return 'Connected';
      case VpnConnectionState.disconnecting:
        return 'Disconnecting';
      case VpnConnectionState.failed:
        return 'Failed';
    }
  }

  bool get isBusy =>
      this == VpnConnectionState.validating ||
      this == VpnConnectionState.connecting ||
      this == VpnConnectionState.disconnecting;

  bool get isTerminal =>
      this == VpnConnectionState.idle ||
      this == VpnConnectionState.ready ||
      this == VpnConnectionState.connected ||
      this == VpnConnectionState.failed;
}

class VpnEngineResult {
  const VpnEngineResult({
    required this.state,
    required this.success,
    required this.message,
    this.sessionId,
  });

  final VpnConnectionState state;
  final bool success;
  final String message;
  final String? sessionId;
}
