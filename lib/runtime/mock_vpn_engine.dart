import '../models/config_entry.dart';
import '../models/runtime_settings.dart';
import '../models/vpn_runtime_models.dart';
import '../services/app_logger.dart';
import 'vpn_engine.dart';

class MockVpnEngine implements VpnEngine {
  MockVpnEngine({AppLogger? logger}) : _logger = logger ?? AppLogger.instance;

  static const String _tag = 'MockVpnEngine';
  final AppLogger _logger;

  @override
  Future<VpnEngineResult> validate(ConfigEntry entry, RuntimeSettings runtimeSettings) async {
    _logger.info(_tag, 'Mock validate requested for ${entry.name}.');
    if (!entry.isXrayReady || entry.xrayConfigJson == null) {
      return const VpnEngineResult(
        state: VpnConnectionState.failed,
        success: false,
        message: 'Xray JSON is not ready, so runtime validation cannot proceed.',
      );
    }
    return VpnEngineResult(
      state: VpnConnectionState.ready,
      success: true,
      message: 'Preview runtime validation succeeded. ${runtimeSettings.proxySummary}',
    );
  }

  @override
  Future<VpnEngineResult> connect(ConfigEntry entry, RuntimeSettings runtimeSettings) async {
    _logger.info(_tag, 'Mock connect requested for ${entry.name}.');
    if (!entry.isXrayReady || entry.xrayConfigJson == null) {
      return const VpnEngineResult(
        state: VpnConnectionState.failed,
        success: false,
        message: 'Connect blocked because Xray JSON is unavailable.',
      );
    }
    final bool vpnRequested = runtimeSettings.enableDeviceVpn;
    return VpnEngineResult(
      state: VpnConnectionState.connected,
      success: true,
      message: vpnRequested
          ? 'Preview runtime started in full-device mode. ${runtimeSettings.proxySummary}'
          : 'Preview runtime started. ${runtimeSettings.proxySummary}',
      sessionId: 'alphawet-preview-${entry.id}',
    );
  }

  @override
  Future<VpnEngineResult> disconnect(ConfigEntry entry) async {
    _logger.info(_tag, 'Mock disconnect requested for ${entry.name}.');
    return const VpnEngineResult(
      state: VpnConnectionState.idle,
      success: true,
      message: 'Preview runtime stopped.',
    );
  }
}
