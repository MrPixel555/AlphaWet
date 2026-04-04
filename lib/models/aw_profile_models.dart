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

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'serverName': serverName,
      'publicKey': publicKey,
      'shortId': shortId,
      'fingerprint': fingerprint,
      'spiderX': spiderX,
    };
  }

  factory AwRealitySettings.fromJson(Map<String, dynamic> json) {
    return AwRealitySettings(
      serverName: json['serverName'] as String?,
      publicKey: json['publicKey'] as String?,
      shortId: json['shortId'] as String?,
      fingerprint: json['fingerprint'] as String?,
      spiderX: json['spiderX'] as String?,
    );
  }

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

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'serverName': serverName,
      'fingerprint': fingerprint,
      'allowInsecure': allowInsecure,
    };
  }

  factory AwTlsSettings.fromJson(Map<String, dynamic> json) {
    return AwTlsSettings(
      serverName: json['serverName'] as String?,
      fingerprint: json['fingerprint'] as String?,
      allowInsecure: json['allowInsecure'] == true,
    );
  }

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

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': type,
      'headerType': headerType,
      'path': path,
      'host': host,
      'serviceName': serviceName,
      'authority': authority,
      'mode': mode,
    };
  }

  factory AwTransportSettings.fromJson(Map<String, dynamic> json) {
    return AwTransportSettings(
      type: (json['type'] as String?) ?? 'tcp',
      headerType: json['headerType'] as String?,
      path: json['path'] as String?,
      host: json['host'] as String?,
      serviceName: json['serviceName'] as String?,
      authority: json['authority'] as String?,
      mode: json['mode'] as String?,
    );
  }
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

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'displayName': displayName,
      'protocol': protocol,
      'host': host,
      'port': port,
      'userId': userId,
      'security': security,
      'network': network,
      'encryption': encryption,
      'flow': flow,
      'fragment': fragment,
      'queryParameters': queryParameters,
      'reality': reality?.toJson(),
      'tls': tls?.toJson(),
      'transport': transport.toJson(),
    };
  }

  factory AwConnectionProfile.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> query = (json['queryParameters'] as Map<dynamic, dynamic>? ?? const <dynamic, dynamic>{})
        .map((dynamic key, dynamic value) => MapEntry(key.toString(), value.toString()));

    return AwConnectionProfile(
      displayName: (json['displayName'] as String?) ?? 'Imported config',
      protocol: (json['protocol'] as String?) ?? 'vless',
      host: (json['host'] as String?) ?? '-',
      port: (json['port'] as num?)?.toInt(),
      userId: json['userId'] as String?,
      security: (json['security'] as String?) ?? 'none',
      network: (json['network'] as String?) ?? 'tcp',
      encryption: (json['encryption'] as String?) ?? 'none',
      flow: json['flow'] as String?,
      fragment: json['fragment'] as String?,
      queryParameters: query,
      reality: json['reality'] is Map<String, dynamic>
          ? AwRealitySettings.fromJson(json['reality'] as Map<String, dynamic>)
          : json['reality'] is Map
              ? AwRealitySettings.fromJson((json['reality'] as Map<dynamic, dynamic>)
                  .map((dynamic key, dynamic value) => MapEntry(key.toString(), value)))
              : null,
      tls: json['tls'] is Map<String, dynamic>
          ? AwTlsSettings.fromJson(json['tls'] as Map<String, dynamic>)
          : json['tls'] is Map
              ? AwTlsSettings.fromJson((json['tls'] as Map<dynamic, dynamic>)
                  .map((dynamic key, dynamic value) => MapEntry(key.toString(), value)))
              : null,
      transport: json['transport'] is Map<String, dynamic>
          ? AwTransportSettings.fromJson(json['transport'] as Map<String, dynamic>)
          : json['transport'] is Map
              ? AwTransportSettings.fromJson((json['transport'] as Map<dynamic, dynamic>)
                  .map((dynamic key, dynamic value) => MapEntry(key.toString(), value)))
              : const AwTransportSettings(),
    );
  }
}
