import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/aw_profile_models.dart';
import 'opaque_windows_storage.dart';

class PersistedConfigRecord {
  const PersistedConfigRecord({
    required this.id,
    required this.path,
    required this.importedAt,
    required this.profile,
    required this.importStatus,
    required this.payloadKind,
    required this.isSecureEnvelope,
    this.uploadBytes = 0,
    this.downloadBytes = 0,
  });

  final String id;
  final String path;
  final DateTime importedAt;
  final AwConnectionProfile profile;
  final String importStatus;
  final String payloadKind;
  final bool isSecureEnvelope;
  final int uploadBytes;
  final int downloadBytes;
}

class ConfigStore {
  static const String _configsKey = 'configs.persisted.v1';

  Future<List<PersistedConfigRecord>> load() async {
    final String? raw = await _readRaw();
    if (raw == null || raw.trim().isEmpty) {
      return const <PersistedConfigRecord>[];
    }

    final Object? decoded = jsonDecode(raw);
    if (decoded is! List<Object?>) {
      return const <PersistedConfigRecord>[];
    }

    final List<PersistedConfigRecord> items = <PersistedConfigRecord>[];
    for (final Object? item in decoded) {
      if (item is! Map<String, dynamic>) {
        continue;
      }
      items.add(_recordFromJson(item));
    }
    return items;
  }

  Future<void> save(List<PersistedConfigRecord> records) async {
    final List<Map<String, dynamic>> payload =
        records.map(_recordToJson).toList(growable: false);
    final String encoded = jsonEncode(payload);

    if (OpaqueWindowsStorage.instance.isAvailable) {
      await OpaqueWindowsStorage.instance.writeText(_configsKey, encoded);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_configsKey);
      return;
    }

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_configsKey, encoded);
  }

  Future<String?> _readRaw() async {
    if (OpaqueWindowsStorage.instance.isAvailable) {
      final String? sealed = await OpaqueWindowsStorage.instance.readText(_configsKey);
      if (sealed != null && sealed.trim().isNotEmpty) {
        return sealed;
      }

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? legacy = prefs.getString(_configsKey);
      if (legacy != null && legacy.trim().isNotEmpty) {
        await OpaqueWindowsStorage.instance.writeText(_configsKey, legacy);
        await prefs.remove(_configsKey);
      }
      return legacy;
    }

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString(_configsKey);
  }

  PersistedConfigRecord _recordFromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> profileJson =
        (json['profile'] as Map<Object?, Object?>?)?.map<String, dynamic>(
              (Object? key, Object? value) => MapEntry(key.toString(), value),
            ) ??
            const <String, dynamic>{};

    return PersistedConfigRecord(
      id: (json['id'] as String? ?? '').trim(),
      path: (json['path'] as String? ?? '').trim(),
      importedAt: DateTime.tryParse(json['importedAt'] as String? ?? '') ?? DateTime.now(),
      profile: _profileFromJson(profileJson),
      importStatus: (json['importStatus'] as String? ?? 'Imported').trim(),
      payloadKind: (json['payloadKind'] as String? ?? 'unknown').trim(),
      isSecureEnvelope: json['isSecureEnvelope'] == true,
      uploadBytes: (json['uploadBytes'] as num?)?.toInt() ?? 0,
      downloadBytes: (json['downloadBytes'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> _recordToJson(PersistedConfigRecord record) {
    return <String, dynamic>{
      'id': record.id,
      'path': record.path,
      'importedAt': record.importedAt.toIso8601String(),
      'profile': _profileToJson(record.profile),
      'importStatus': record.importStatus,
      'payloadKind': record.payloadKind,
      'isSecureEnvelope': record.isSecureEnvelope,
      'uploadBytes': record.uploadBytes,
      'downloadBytes': record.downloadBytes,
    };
  }

  AwConnectionProfile _profileFromJson(Map<String, dynamic> json) {
    final Map<String, String> queryParameters =
        (json['queryParameters'] as Map<Object?, Object?>?)?.map<String, String>(
              (Object? key, Object? value) => MapEntry(key.toString(), value?.toString() ?? ''),
            ) ??
            const <String, String>{};

    final Map<String, dynamic>? realityJson =
        (json['reality'] as Map<Object?, Object?>?)?.map<String, dynamic>(
      (Object? key, Object? value) => MapEntry(key.toString(), value),
    );
    final Map<String, dynamic>? tlsJson =
        (json['tls'] as Map<Object?, Object?>?)?.map<String, dynamic>(
      (Object? key, Object? value) => MapEntry(key.toString(), value),
    );
    final Map<String, dynamic>? transportJson =
        (json['transport'] as Map<Object?, Object?>?)?.map<String, dynamic>(
      (Object? key, Object? value) => MapEntry(key.toString(), value),
    );

    return AwConnectionProfile(
      displayName: (json['displayName'] as String? ?? 'Imported config').trim(),
      protocol: (json['protocol'] as String? ?? 'vless').trim(),
      host: (json['host'] as String? ?? '').trim(),
      port: json['port'] as int?,
      userId: (json['userId'] as String?)?.trim(),
      security: (json['security'] as String? ?? 'none').trim(),
      network: (json['network'] as String? ?? 'tcp').trim(),
      encryption: (json['encryption'] as String? ?? 'none').trim(),
      flow: (json['flow'] as String?)?.trim(),
      fragment: (json['fragment'] as String?)?.trim(),
      queryParameters: queryParameters,
      reality: realityJson == null
          ? null
          : AwRealitySettings(
              serverName: (realityJson['serverName'] as String?)?.trim(),
              publicKey: (realityJson['publicKey'] as String?)?.trim(),
              shortId: (realityJson['shortId'] as String?)?.trim(),
              fingerprint: (realityJson['fingerprint'] as String?)?.trim(),
              spiderX: (realityJson['spiderX'] as String?)?.trim(),
            ),
      tls: tlsJson == null
          ? null
          : AwTlsSettings(
              serverName: (tlsJson['serverName'] as String?)?.trim(),
              fingerprint: (tlsJson['fingerprint'] as String?)?.trim(),
              allowInsecure: tlsJson['allowInsecure'] == true,
            ),
      transport: transportJson == null
          ? const AwTransportSettings()
          : AwTransportSettings(
              type: (transportJson['type'] as String? ?? 'tcp').trim(),
              headerType: (transportJson['headerType'] as String?)?.trim(),
              path: (transportJson['path'] as String?)?.trim(),
              host: (transportJson['host'] as String?)?.trim(),
              serviceName: (transportJson['serviceName'] as String?)?.trim(),
              authority: (transportJson['authority'] as String?)?.trim(),
              mode: (transportJson['mode'] as String?)?.trim(),
            ),
    );
  }

  Map<String, dynamic> _profileToJson(AwConnectionProfile profile) {
    return <String, dynamic>{
      'displayName': profile.displayName,
      'protocol': profile.protocol,
      'host': profile.host,
      'port': profile.port,
      'userId': profile.userId,
      'security': profile.security,
      'network': profile.network,
      'encryption': profile.encryption,
      'flow': profile.flow,
      'fragment': profile.fragment,
      'queryParameters': profile.queryParameters,
      'reality': profile.reality == null
          ? null
          : <String, dynamic>{
              'serverName': profile.reality!.serverName,
              'publicKey': profile.reality!.publicKey,
              'shortId': profile.reality!.shortId,
              'fingerprint': profile.reality!.fingerprint,
              'spiderX': profile.reality!.spiderX,
            },
      'tls': profile.tls == null
          ? null
          : <String, dynamic>{
              'serverName': profile.tls!.serverName,
              'fingerprint': profile.tls!.fingerprint,
              'allowInsecure': profile.tls!.allowInsecure,
            },
      'transport': <String, dynamic>{
        'type': profile.transport.type,
        'headerType': profile.transport.headerType,
        'path': profile.transport.path,
        'host': profile.transport.host,
        'serviceName': profile.transport.serviceName,
        'authority': profile.transport.authority,
        'mode': profile.transport.mode,
      },
    };
  }
}
