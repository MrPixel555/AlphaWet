import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/runtime_settings.dart';
import 'opaque_windows_storage.dart';

class RuntimeSettingsStore {
  static const String _httpPortKey = 'runtime.http_port';
  static const String _socksPortKey = 'runtime.socks_port';
  static const String _modeKey = 'runtime.mode';
  static const String _enableDeviceVpnKey = 'runtime.enable_device_vpn';
  static const String _vpnPermissionGrantedKey = 'runtime.vpn_permission_granted';
  static const String _sealedSettingsKey = 'runtime.settings.v1';

  Future<RuntimeSettings> load() async {
    final String? sealed = await _readSealedSettings();
    if (sealed != null && sealed.trim().isNotEmpty) {
      final Object? decoded = jsonDecode(sealed);
      if (decoded is Map<String, dynamic>) {
        final String? storedMode = (decoded[_modeKey] as String?)?.trim().toLowerCase();
        final bool legacyEnableVpn =
            decoded[_enableDeviceVpnKey] as bool? ?? RuntimeSettings.defaults.enableDeviceVpn;

        final RuntimeMode mode = switch (storedMode) {
          'vpn' => RuntimeMode.vpn,
          'proxy' => RuntimeMode.proxy,
          _ => legacyEnableVpn ? RuntimeMode.vpn : RuntimeMode.proxy,
        };

        return RuntimeSettings(
          httpPort: decoded[_httpPortKey] as int? ?? RuntimeSettings.defaults.httpPort,
          socksPort: decoded[_socksPortKey] as int? ?? RuntimeSettings.defaults.socksPort,
          mode: mode,
          vpnPermissionGranted: decoded[_vpnPermissionGrantedKey] as bool? ??
              RuntimeSettings.defaults.vpnPermissionGranted,
        );
      }
    }

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? storedMode = prefs.getString(_modeKey)?.trim().toLowerCase();
    final bool legacyEnableVpn =
        prefs.getBool(_enableDeviceVpnKey) ?? RuntimeSettings.defaults.enableDeviceVpn;

    final RuntimeMode mode = switch (storedMode) {
      'vpn' => RuntimeMode.vpn,
      'proxy' => RuntimeMode.proxy,
      _ => legacyEnableVpn ? RuntimeMode.vpn : RuntimeMode.proxy,
    };

    final RuntimeSettings settings = RuntimeSettings(
      httpPort: prefs.getInt(_httpPortKey) ?? RuntimeSettings.defaults.httpPort,
      socksPort: prefs.getInt(_socksPortKey) ?? RuntimeSettings.defaults.socksPort,
      mode: mode,
      vpnPermissionGranted:
          prefs.getBool(_vpnPermissionGrantedKey) ?? RuntimeSettings.defaults.vpnPermissionGranted,
    );

    if (OpaqueWindowsStorage.instance.isAvailable) {
      await save(settings);
      await prefs.remove(_httpPortKey);
      await prefs.remove(_socksPortKey);
      await prefs.remove(_modeKey);
      await prefs.remove(_enableDeviceVpnKey);
      await prefs.remove(_vpnPermissionGrantedKey);
    }

    return settings;
  }

  Future<void> save(RuntimeSettings settings) async {
    if (OpaqueWindowsStorage.instance.isAvailable) {
      final Map<String, Object> payload = <String, Object>{
        _httpPortKey: settings.httpPort,
        _socksPortKey: settings.socksPort,
        _modeKey: settings.mode.name,
        _enableDeviceVpnKey: settings.enableDeviceVpn,
        _vpnPermissionGrantedKey: settings.vpnPermissionGranted,
      };
      await OpaqueWindowsStorage.instance.writeText(_sealedSettingsKey, jsonEncode(payload));
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_httpPortKey);
      await prefs.remove(_socksPortKey);
      await prefs.remove(_modeKey);
      await prefs.remove(_enableDeviceVpnKey);
      await prefs.remove(_vpnPermissionGrantedKey);
      return;
    }

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_httpPortKey, settings.httpPort);
    await prefs.setInt(_socksPortKey, settings.socksPort);
    await prefs.setString(_modeKey, settings.mode.name);
    await prefs.setBool(_enableDeviceVpnKey, settings.enableDeviceVpn);
    await prefs.setBool(_vpnPermissionGrantedKey, settings.vpnPermissionGranted);
  }

  Future<String?> _readSealedSettings() async {
    if (!OpaqueWindowsStorage.instance.isAvailable) {
      return null;
    }
    return OpaqueWindowsStorage.instance.readText(_sealedSettingsKey);
  }
}
