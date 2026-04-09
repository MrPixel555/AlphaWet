import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'opaque_windows_storage.dart';

import '../models/aw_profile_models.dart';
import '../models/config_entry.dart';

class ConfigEntriesStore {
  static const String _configsKey = 'alphawet.config_entries';

  Future<List<StoredConfigEntry>> load() async {
    if (OpaqueWindowsStorage.instance.isAvailable) {
      final String? raw = await OpaqueWindowsStorage.instance.readText(_configsKey);
      if (raw == null || raw.trim().isEmpty) {
        return const <StoredConfigEntry>[];
      }
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List<Object?>) {
        return const <StoredConfigEntry>[];
      }
      return decoded
          .whereType<String>()
          .map((String item) => StoredConfigEntry.fromJson(jsonDecode(item) as Map<String, dynamic>))
          .toList(growable: false);
    }

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String> rawEntries = prefs.getStringList(_configsKey) ?? const <String>[];
    return rawEntries
        .map((String raw) => StoredConfigEntry.fromJson(jsonDecode(raw) as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<void> save(List<ConfigEntry> entries) async {
    final List<String> payload = entries
        .map((ConfigEntry entry) => jsonEncode(StoredConfigEntry.fromRuntimeEntry(entry).toJson()))
        .toList(growable: false);

    if (OpaqueWindowsStorage.instance.isAvailable) {
      await OpaqueWindowsStorage.instance.writeText(_configsKey, jsonEncode(payload));
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_configsKey);
      return;
    }

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_configsKey, payload);
  }
}

class StoredConfigEntry {
  const StoredConfigEntry({
    required this.id,
    required this.path,
    required this.importedAt,
    required this.importStatus,
    required this.payloadKind,
    required this.isSecureEnvelope,
    required this.profile,
  });

  final String id;
  final String path;
  final DateTime importedAt;
  final String importStatus;
  final String payloadKind;
  final bool isSecureEnvelope;
  final AwConnectionProfile profile;

  factory StoredConfigEntry.fromRuntimeEntry(ConfigEntry entry) {
    return StoredConfigEntry(
      id: entry.id,
      path: entry.path,
      importedAt: entry.importedAt,
      importStatus: entry.importStatus,
      payloadKind: entry.payloadKind,
      isSecureEnvelope: entry.isSecureEnvelope,
      profile: entry.profile,
    );
  }

  factory StoredConfigEntry.fromJson(Map<String, dynamic> json) {
    final Object? rawProfile = json['profile'];
    final Map<String, dynamic> profileJson = rawProfile is Map<String, dynamic>
        ? rawProfile
        : (rawProfile as Map<dynamic, dynamic>).map(
            (dynamic key, dynamic value) => MapEntry(key.toString(), value),
          );

    return StoredConfigEntry(
      id: (json['id'] as String?) ?? DateTime.now().microsecondsSinceEpoch.toString(),
      path: (json['path'] as String?) ?? '',
      importedAt: DateTime.tryParse((json['importedAt'] as String?) ?? '') ?? DateTime.now(),
      importStatus: (json['importStatus'] as String?) ?? 'Imported',
      payloadKind: (json['payloadKind'] as String?) ?? 'unknown',
      isSecureEnvelope: json['isSecureEnvelope'] == true,
      profile: AwConnectionProfile.fromJson(profileJson),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'path': path,
      'importedAt': importedAt.toIso8601String(),
      'importStatus': importStatus,
      'payloadKind': payloadKind,
      'isSecureEnvelope': isSecureEnvelope,
      'profile': profile.toJson(),
    };
  }
}
