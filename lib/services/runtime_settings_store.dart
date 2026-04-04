import 'package:shared_preferences/shared_preferences.dart';

import '../models/runtime_settings.dart';

class RuntimeSettingsStore {
  static const String _httpPortKey = 'runtime.http_port';
  static const String _socksPortKey = 'runtime.socks_port';
  static const String _modeKey = 'runtime.mode';
  static const String _enableDeviceVpnKey = 'runtime.enable_device_vpn';
  static const String _vpnPermissionGrantedKey = 'runtime.vpn_permission_granted';

  Future<RuntimeSettings> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? storedMode = prefs.getString(_modeKey)?.trim().toLowerCase();
    final bool legacyEnableVpn =
        prefs.getBool(_enableDeviceVpnKey) ?? RuntimeSettings.defaults.enableDeviceVpn;

    final RuntimeMode mode = switch (storedMode) {
      'vpn' => RuntimeMode.vpn,
      'proxy' => RuntimeMode.proxy,
      _ => legacyEnableVpn ? RuntimeMode.vpn : RuntimeMode.proxy,
    };

    return RuntimeSettings(
      httpPort: prefs.getInt(_httpPortKey) ?? RuntimeSettings.defaults.httpPort,
      socksPort: prefs.getInt(_socksPortKey) ?? RuntimeSettings.defaults.socksPort,
      mode: mode,
      vpnPermissionGranted:
          prefs.getBool(_vpnPermissionGrantedKey) ?? RuntimeSettings.defaults.vpnPermissionGranted,
    );
  }

  Future<void> save(RuntimeSettings settings) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_httpPortKey, settings.httpPort);
    await prefs.setInt(_socksPortKey, settings.socksPort);
    await prefs.setString(_modeKey, settings.mode.name);
    await prefs.setBool(_enableDeviceVpnKey, settings.enableDeviceVpn);
    await prefs.setBool(_vpnPermissionGrantedKey, settings.vpnPermissionGranted);
  }
}
