class AwRealitySettings {
  const AwRealitySettings({
    this.serverName,
    this.publicKey,
    this.shortId,
    this.fingerprint,
    this.spiderX,
  });

  final String? serverName;
  final String? publicKey;
  final String? shortId;
  final String? fingerprint;
  final String? spiderX;

  bool get hasAnyField =>
      _hasValue(serverName) ||
      _hasValue(publicKey) ||
      _hasValue(shortId) ||
      _hasValue(fingerprint) ||
      _hasValue(spiderX);

  static bool _hasValue(String? value) => value != null && value.trim().isNotEmpty;
}

class AwTlsSettings {
  const AwTlsSettings({
    this.serverName,
    this.fingerprint,
    this.allowInsecure = false,
  });

  final String? serverName;
  final String? fingerprint;
  final bool allowInsecure;

  bool get hasAnyField =>
      _hasValue(serverName) || _hasValue(fingerprint) || allowInsecure;

  static bool _hasValue(String? value) => value != null && value.trim().isNotEmpty;
}

class AwTransportSettings {
  const AwTransportSettings({
    this.type = 'tcp',
    this.headerType,
    this.path,
    this.host,
    this.serviceName,
    this.authority,
    this.mode,
  });

  final String type;
  final String? headerType;
  final String? path;
  final String? host;
  final String? serviceName;
  final String? authority;
  final String? mode;
}

class AwConnectionProfile {
  const AwConnectionProfile({
    required this.displayName,
    required this.protocol,
    required this.host,
    this.port,
    this.userId,
    this.security = 'none',
    this.network = 'tcp',
    this.encryption = 'none',
    this.flow,
    this.fragment,
    this.queryParameters = const <String, String>{},
    this.reality,
    this.tls,
    this.transport = const AwTransportSettings(),
  });

  final String displayName;
  final String protocol;
  final String host;
  final int? port;
  final String? userId;
  final String security;
  final String network;
  final String encryption;
  final String? flow;
  final String? fragment;
  final Map<String, String> queryParameters;
  final AwRealitySettings? reality;
  final AwTlsSettings? tls;
  final AwTransportSettings transport;

  bool get isReality => security == 'reality' || (reality?.hasAnyField ?? false);
  bool get isTls => security == 'tls' || (tls?.hasAnyField ?? false);
  String? get serverName => reality?.serverName ?? tls?.serverName;

  String get endpoint => port == null ? host : '$host:$port';
}
