import 'package:aw_manager_ui/models/aw_profile_models.dart';
import 'package:aw_manager_ui/models/config_entry.dart';
import 'package:aw_manager_ui/models/runtime_settings.dart';
import 'package:aw_manager_ui/models/vpn_runtime_models.dart';
import 'package:aw_manager_ui/runtime/mock_vpn_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final profile = AwConnectionProfile(
    displayName: 'test',
    protocol: 'vless',
    host: 'example.com',
  );

  group('MockVpnEngine', () {
    test('validate fails when xray json is missing', () async {
      final engine = MockVpnEngine();
      final entry = ConfigEntry(
        id: '1',
        name: 'test',
        path: '/tmp/test.aw',
        importedAt: DateTime(2026, 1, 1),
        protocol: 'vless',
        host: 'example.com',
        importStatus: 'Legacy',
        profile: profile,
        security: 'reality',
        network: 'tcp',
      );

      final result = await engine.validate(entry, RuntimeSettings.defaults);
      expect(result.success, isFalse);
      expect(result.state, VpnConnectionState.failed);
    });

    test('connect succeeds when xray json exists', () async {
      final engine = MockVpnEngine();
      final entry = ConfigEntry(
        id: '1',
        name: 'test',
        path: '/tmp/test.aw',
        importedAt: DateTime(2026, 1, 1),
        protocol: 'vless',
        host: 'example.com',
        importStatus: 'Legacy',
        profile: profile,
        security: 'reality',
        network: 'tcp',
        xrayBuildStatus: 'Ready',
        xrayConfigJson: '{"ok":true}',
      );

      final validate = await engine.validate(entry, RuntimeSettings.defaults);
      expect(validate.success, isTrue);
      expect(validate.state, VpnConnectionState.ready);

      final connect = await engine.connect(entry, RuntimeSettings.defaults);
      expect(connect.success, isTrue);
      expect(connect.state, VpnConnectionState.connected);
      expect(connect.sessionId, isNotNull);
    });
  });
}
