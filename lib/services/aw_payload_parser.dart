import 'dart:convert';

import '../models/aw_import_models.dart';
import '../models/aw_profile_models.dart';
import 'app_logger.dart';
import 'aw_import_exception.dart';

class AwPayloadParser {
  AwPayloadParser({AppLogger? logger}) : _logger = logger ?? AppLogger.instance;

  final AppLogger _logger;
  static const String _tag = 'AwPayloadParser';

  ParsedAwPayload parse(
    String plaintext, {
    required bool isSecureEnvelope,
  }) {
    final String trimmed = plaintext.trim();
    final Object? decodedJson = _tryDecodeJson(trimmed);

    if (decodedJson is Map<String, dynamic>) {
      _logger.debug(_tag, 'Parsing plaintext payload as JSON.');
      return _parseJsonPayload(trimmed, decodedJson, isSecureEnvelope: isSecureEnvelope);
    }

    final Uri? uri = Uri.tryParse(trimmed);
    if (uri != null && uri.scheme.isNotEmpty) {
      _logger.debug(_tag, 'Parsing plaintext payload as URI.');
      return _parseUriPayload(trimmed, uri, isSecureEnvelope: isSecureEnvelope);
    }

    throw const AwImportException('Payload is not valid JSON and not a valid URI.');
  }

  ParsedAwPayload _parseUriPayload(
    String raw,
    Uri uri, {
    required bool isSecureEnvelope,
  }) {
    final Map<String, String> query = uri.queryParameters.map(
      (String key, String value) => MapEntry(key, value.trim()),
    );
    final String protocol = uri.scheme.trim().toLowerCase();
    final String network = _normalizeString(query['type']) ??
        _normalizeString(query['network']) ??
        'tcp';
    final String security = _normalizeString(query['security']) ??
        (_hasAny(query, <String>['pbk', 'sid', 'sni', 'fp']) ? 'reality' : 'none');
    final String encryption = _normalizeString(query['encryption']) ?? 'none';
    final String? flow = _normalizeString(query['flow']);
    final String? path = _normalizeString(query['path']) ?? _normalizeUriPath(uri.path);
    final String? serverName = _normalizeString(query['sni']) ?? _normalizeString(query['serverName']);
    final String? publicKey = _normalizeString(query['pbk']) ?? _normalizeString(query['publicKey']);
    final String? shortId = _normalizeString(query['sid']) ?? _normalizeString(query['shortId']);
    final String? fingerprint = _normalizeString(query['fp']) ?? _normalizeString(query['fingerprint']);
    final String? spiderX = _normalizeString(query['spx']) ?? _normalizeString(query['spiderX']);
    final String displayName = uri.fragment.isNotEmpty
        ? Uri.decodeComponent(uri.fragment)
        : '$protocol://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';

    final AwRealitySettings? reality = (security == 'reality' ||
            _hasText(serverName) ||
            _hasText(publicKey) ||
            _hasText(shortId) ||
            _hasText(fingerprint) ||
            _hasText(spiderX))
        ? AwRealitySettings(
            serverName: serverName,
            publicKey: publicKey,
            shortId: shortId,
            fingerprint: fingerprint,
            spiderX: spiderX,
          )
        : null;

    final AwTlsSettings? tls = security == 'tls'
        ? AwTlsSettings(
            serverName: serverName,
            fingerprint: fingerprint,
            allowInsecure: query['allowInsecure'] == '1' || query['allowInsecure'] == 'true',
          )
        : null;

    final AwTransportSettings transport = AwTransportSettings(
      type: network,
      headerType: _normalizeString(query['headerType']),
      path: path,
      host: _normalizeString(query['host']),
      serviceName: _normalizeString(query['serviceName']),
      authority: _normalizeString(query['authority']),
      mode: _normalizeString(query['mode']),
    );

    final AwConnectionProfile profile = AwConnectionProfile(
      displayName: displayName,
      protocol: protocol,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      userId: _normalizeString(uri.userInfo),
      security: security,
      network: network,
      encryption: encryption,
      flow: flow,
      fragment: uri.fragment.isEmpty ? null : Uri.decodeComponent(uri.fragment),
      queryParameters: query,
      reality: security == 'reality' ? reality : null,
      tls: tls,
      transport: transport,
    );

    _logger.info(
      _tag,
      'URI payload parsed. protocol=${profile.protocol}, security=${profile.security}, network=${profile.network}',
    );

    return ParsedAwPayload(
      raw: raw,
      isSecureEnvelope: isSecureEnvelope,
      payloadKind: 'uri',
      profile: profile,
    );
  }

  ParsedAwPayload _parseJsonPayload(
    String raw,
    Map<String, dynamic> json, {
    required bool isSecureEnvelope,
  }) {
    final Map<String, dynamic> settings = _mapOf(json['settings']);
    final Map<String, dynamic> streamSettings = _mapOf(json['streamSettings']);
    final Map<String, dynamic> realitySettings = _firstNonEmptyMap(<Map<String, dynamic>>[
      _mapOf(json['reality']),
      _mapOf(json['realitySettings']),
      _mapOf(streamSettings['realitySettings']),
    ]);
    final Map<String, dynamic> tlsSettings = _firstNonEmptyMap(<Map<String, dynamic>>[
      _mapOf(json['tls']),
      _mapOf(json['tlsSettings']),
      _mapOf(streamSettings['tlsSettings']),
    ]);

    final Map<String, dynamic> firstVnext = _firstMapFromList(settings['vnext']);
    final Map<String, dynamic> firstUser = _firstMapFromList(firstVnext['users']);
    final Map<String, dynamic> firstServer = _firstMapFromList(settings['servers']);

    final String protocol = _normalizeString(json['protocol']) ??
        _normalizeString(json['type']) ??
        _normalizeString(json['scheme']) ??
        (firstVnext.isNotEmpty ? 'vless' : 'unknown');

    final String host = _normalizeString(json['address']) ??
        _normalizeString(json['host']) ??
        _normalizeString(json['server']) ??
        _normalizeString(firstVnext['address']) ??
        _normalizeString(firstServer['address']) ??
        _normalizeString(firstServer['server']) ??
        '-';

    final int? port = _toInt(json['port']) ??
        _toInt(firstVnext['port']) ??
        _toInt(firstServer['port']);

    final String security = _normalizeString(json['security']) ??
        _normalizeString(streamSettings['security']) ??
        (realitySettings.isNotEmpty
            ? 'reality'
            : (tlsSettings.isNotEmpty ? 'tls' : 'none'));

    final String network = _normalizeString(streamSettings['network']) ??
        _normalizeString(json['network']) ??
        _normalizeString(json['transport']) ??
        'tcp';

    final String encryption = _normalizeString(json['encryption']) ??
        _normalizeString(firstUser['encryption']) ??
        'none';

    final String? flow = _normalizeString(json['flow']) ?? _normalizeString(firstUser['flow']);
    final String? userId = _normalizeString(json['uuid']) ??
        _normalizeString(json['id']) ??
        _normalizeString(json['userId']) ??
        _normalizeString(firstUser['id']);

    final String displayName = _normalizeString(json['name']) ??
        _normalizeString(json['remark']) ??
        _normalizeString(json['ps']) ??
        _normalizeString(json['tag']) ??
        '$protocol://$host${port == null ? '' : ':$port'}';

    final Map<String, dynamic> wsSettings = _firstNonEmptyMap(<Map<String, dynamic>>[
      _mapOf(json['wsSettings']),
      _mapOf(streamSettings['wsSettings']),
    ]);
    final Map<String, dynamic> grpcSettings = _firstNonEmptyMap(<Map<String, dynamic>>[
      _mapOf(json['grpcSettings']),
      _mapOf(streamSettings['grpcSettings']),
    ]);
    final Map<String, dynamic> tcpSettings = _firstNonEmptyMap(<Map<String, dynamic>>[
      _mapOf(json['tcpSettings']),
      _mapOf(streamSettings['tcpSettings']),
    ]);
    final Map<String, dynamic> httpSettings = _firstNonEmptyMap(<Map<String, dynamic>>[
      _mapOf(json['httpSettings']),
      _mapOf(streamSettings['httpSettings']),
    ]);

    final Map<String, dynamic> tcpHeader = _mapOf(tcpSettings['header']);
    final Map<String, dynamic> wsHeaders = _mapOf(wsSettings['headers']);

    final AwRealitySettings? reality = realitySettings.isEmpty
        ? null
        : AwRealitySettings(
            serverName: _normalizeString(realitySettings['serverName']) ??
                _normalizeString(realitySettings['sni']),
            publicKey: _normalizeString(realitySettings['publicKey']) ??
                _normalizeString(realitySettings['pbk']),
            shortId: _normalizeString(realitySettings['shortId']) ??
                _normalizeString(realitySettings['sid']),
            fingerprint: _normalizeString(realitySettings['fingerprint']) ??
                _normalizeString(realitySettings['fp']),
            spiderX: _normalizeString(realitySettings['spiderX']) ??
                _normalizeString(realitySettings['spx']),
          );

    final AwTlsSettings? tls = tlsSettings.isEmpty
        ? null
        : AwTlsSettings(
            serverName: _normalizeString(tlsSettings['serverName']) ??
                _normalizeString(tlsSettings['sni']),
            fingerprint: _normalizeString(tlsSettings['fingerprint']) ??
                _normalizeString(tlsSettings['fp']),
            allowInsecure: tlsSettings['allowInsecure'] == true,
          );

    final String? transportHost = _normalizeString(wsHeaders['Host']) ??
        _normalizeString(_firstStringFromList(httpSettings['host'])) ??
        _normalizeString(httpSettings['host']);

    final AwTransportSettings transport = AwTransportSettings(
      type: network,
      headerType: _normalizeString(tcpHeader['type']) ?? _normalizeString(json['headerType']),
      path: _normalizeString(wsSettings['path']) ?? _normalizeString(httpSettings['path']),
      host: transportHost,
      serviceName: _normalizeString(grpcSettings['serviceName']),
      authority: _normalizeString(grpcSettings['authority']),
      mode: grpcSettings['multiMode'] == true ? 'multi' : _normalizeString(grpcSettings['mode']),
    );

    final AwConnectionProfile profile = AwConnectionProfile(
      displayName: displayName,
      protocol: protocol.toLowerCase(),
      host: host,
      port: port,
      userId: userId,
      security: security.toLowerCase(),
      network: network.toLowerCase(),
      encryption: encryption,
      flow: flow,
      queryParameters: const <String, String>{},
      reality: security.toLowerCase() == 'reality' ? reality : null,
      tls: security.toLowerCase() == 'tls' ? tls : null,
      transport: transport,
    );

    _logger.info(
      _tag,
      'JSON payload parsed. protocol=${profile.protocol}, security=${profile.security}, network=${profile.network}',
    );

    return ParsedAwPayload(
      raw: raw,
      isSecureEnvelope: isSecureEnvelope,
      payloadKind: 'json',
      profile: profile,
      json: json,
    );
  }

  Object? _tryDecodeJson(String input) {
    try {
      return jsonDecode(input);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _mapOf(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((Object? key, Object? value) => MapEntry(key.toString(), value));
    }
    return const <String, dynamic>{};
  }

  Map<String, dynamic> _firstMapFromList(Object? value) {
    if (value is List) {
      for (final Object? item in value) {
        final Map<String, dynamic> map = _mapOf(item);
        if (map.isNotEmpty) {
          return map;
        }
      }
    }
    return const <String, dynamic>{};
  }

  String? _firstStringFromList(Object? value) {
    if (value is List) {
      for (final Object? item in value) {
        final String? text = _normalizeString(item);
        if (text != null) {
          return text;
        }
      }
    }
    return null;
  }

  Map<String, dynamic> _firstNonEmptyMap(List<Map<String, dynamic>> maps) {
    for (final Map<String, dynamic> map in maps) {
      if (map.isNotEmpty) {
        return map;
      }
    }
    return const <String, dynamic>{};
  }

  String? _normalizeString(Object? value) {
    if (value == null) {
      return null;
    }
    final String text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  bool _hasAny(Map<String, String> source, List<String> keys) {
    for (final String key in keys) {
      if (_hasText(source[key])) {
        return true;
      }
    }
    return false;
  }

  bool _hasText(String? value) => value != null && value.trim().isNotEmpty;

  String? _normalizeUriPath(String path) {
    final String normalized = path.trim();
    if (normalized.isEmpty || normalized == '/') {
      return null;
    }
    return normalized;
  }

  int? _toInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim());
    }
    return null;
  }
}
