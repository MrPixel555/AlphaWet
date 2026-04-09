import 'package:alphawet/models/aw_profile_models.dart';
import 'package:alphawet/models/config_entry.dart';
import 'package:alphawet/models/vpn_runtime_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const profile = AwConnectionProfile(
    displayName: 'test',
    protocol: 'vless',
    host: 'example.com',
  );

  test('copyWith can clear nullable fields explicitly', () {
    final entry = ConfigEntry(
      id: '1',
      name: 'test',
      path: '/tmp/test.aw',
      importedAt: DateTime(2026, 1, 1),
      protocol: 'vless',
      host: 'example.com',
      importStatus: 'Legacy',
      profile: profile,
      security: 'tls',
      network: 'tcp',
      xrayBuildStatus: 'Ready',
      xrayBuildError: 'boom',
      engineMessage: 'running',
      engineSessionId: 'session-1',
      connectionState: VpnConnectionState.connected,
    );

    final updated = entry.copyWith(
      xrayBuildError: null,
      engineMessage: null,
      engineSessionId: null,
    );

    expect(updated.xrayBuildError, isNull);
    expect(updated.engineMessage, isNull);
    expect(updated.engineSessionId, isNull);
  });
}