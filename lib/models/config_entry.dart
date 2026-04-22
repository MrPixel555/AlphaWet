import 'aw_profile_models.dart';
import 'vpn_runtime_models.dart';

const Object _unset = Object();

class ConfigEntry {
  const ConfigEntry({
    required this.id,
    required this.name,
    required this.path,
    required this.importedAt,
    required this.protocol,
    required this.host,
    required this.importStatus,
    required this.profile,
    required this.security,
    required this.network,
    this.port,
    this.flow,
    this.serverName,
    this.shortId,
    this.payloadKind = 'unknown',
    this.isSecureEnvelope = false,
    this.xrayBuildStatus = 'Pending',
    this.xrayConfigJson,
    this.xrayPrimaryOutboundTag,
    this.xrayBuildError,
    this.isEnabled = false,
    this.isPinging = false,
    this.pingLabel = 'Not tested',
    this.connectionState = VpnConnectionState.idle,
    this.engineMessage,
    this.engineSessionId,
    this.lastValidatedAt,
    this.lastConnectedAt,
    this.uploadBytes = 0,
    this.downloadBytes = 0,
  });

  final String id;
  final String name;
  final String path;
  final DateTime importedAt;
  final String protocol;
  final String host;
  final int? port;
  final String importStatus;
  final AwConnectionProfile profile;
  final String security;
  final String network;
  final String? flow;
  final String? serverName;
  final String? shortId;
  final String payloadKind;
  final bool isSecureEnvelope;
  final String xrayBuildStatus;
  final String? xrayConfigJson;
  final String? xrayPrimaryOutboundTag;
  final String? xrayBuildError;
  final bool isEnabled;
  final bool isPinging;
  final String pingLabel;
  final VpnConnectionState connectionState;
  final String? engineMessage;
  final String? engineSessionId;
  final DateTime? lastValidatedAt;
  final DateTime? lastConnectedAt;
  final int uploadBytes;
  final int downloadBytes;

  bool get isXrayReady => xrayConfigJson != null && xrayBuildError == null;
  bool get isBusy => connectionState.isBusy;

  ConfigEntry copyWith({
    String? id,
    String? name,
    String? path,
    DateTime? importedAt,
    String? protocol,
    String? host,
    Object? port = _unset,
    String? importStatus,
    AwConnectionProfile? profile,
    String? security,
    String? network,
    Object? flow = _unset,
    Object? serverName = _unset,
    Object? shortId = _unset,
    String? payloadKind,
    bool? isSecureEnvelope,
    String? xrayBuildStatus,
    Object? xrayConfigJson = _unset,
    Object? xrayPrimaryOutboundTag = _unset,
    Object? xrayBuildError = _unset,
    bool? isEnabled,
    bool? isPinging,
    String? pingLabel,
    VpnConnectionState? connectionState,
    Object? engineMessage = _unset,
    Object? engineSessionId = _unset,
    Object? lastValidatedAt = _unset,
    Object? lastConnectedAt = _unset,
    int? uploadBytes,
    int? downloadBytes,
  }) {
    return ConfigEntry(
      id: id ?? this.id,
      name: name ?? this.name,
      path: path ?? this.path,
      importedAt: importedAt ?? this.importedAt,
      protocol: protocol ?? this.protocol,
      host: host ?? this.host,
      port: identical(port, _unset) ? this.port : port as int?,
      importStatus: importStatus ?? this.importStatus,
      profile: profile ?? this.profile,
      security: security ?? this.security,
      network: network ?? this.network,
      flow: identical(flow, _unset) ? this.flow : flow as String?,
      serverName: identical(serverName, _unset) ? this.serverName : serverName as String?,
      shortId: identical(shortId, _unset) ? this.shortId : shortId as String?,
      payloadKind: payloadKind ?? this.payloadKind,
      isSecureEnvelope: isSecureEnvelope ?? this.isSecureEnvelope,
      xrayBuildStatus: xrayBuildStatus ?? this.xrayBuildStatus,
      xrayConfigJson: identical(xrayConfigJson, _unset)
          ? this.xrayConfigJson
          : xrayConfigJson as String?,
      xrayPrimaryOutboundTag: identical(xrayPrimaryOutboundTag, _unset)
          ? this.xrayPrimaryOutboundTag
          : xrayPrimaryOutboundTag as String?,
      xrayBuildError: identical(xrayBuildError, _unset)
          ? this.xrayBuildError
          : xrayBuildError as String?,
      isEnabled: isEnabled ?? this.isEnabled,
      isPinging: isPinging ?? this.isPinging,
      pingLabel: pingLabel ?? this.pingLabel,
      connectionState: connectionState ?? this.connectionState,
      engineMessage: identical(engineMessage, _unset)
          ? this.engineMessage
          : engineMessage as String?,
      engineSessionId: identical(engineSessionId, _unset)
          ? this.engineSessionId
          : engineSessionId as String?,
      lastValidatedAt: identical(lastValidatedAt, _unset)
          ? this.lastValidatedAt
          : lastValidatedAt as DateTime?,
      lastConnectedAt: identical(lastConnectedAt, _unset)
          ? this.lastConnectedAt
          : lastConnectedAt as DateTime?,
      uploadBytes: uploadBytes ?? this.uploadBytes,
      downloadBytes: downloadBytes ?? this.downloadBytes,
    );
  }
}
