import '../models/config_entry.dart';
import '../models/runtime_settings.dart';
import '../models/vpn_runtime_models.dart';
import '../services/app_logger.dart';
import 'desktop_xray_runtime.dart';
import 'vpn_engine.dart';

class DesktopXrayVpnEngine implements VpnEngine {
  DesktopXrayVpnEngine({AppLogger? logger}) : _logger = logger ?? AppLogger.instance;

  static const String _tag = 'DesktopXrayVpnEngine';

  final AppLogger _logger;
  final DesktopXrayRuntimeManager _runtimeManager = DesktopXrayRuntimeManager.instance;

  @override
  Future<VpnEngineResult> validate(ConfigEntry entry, RuntimeSettings runtimeSettings) async {
    if (!entry.isXrayReady || entry.xrayConfigJson == null) {
      return const VpnEngineResult(
        state: VpnConnectionState.failed,
        success: false,
        message: 'Xray JSON is not ready for desktop runtime validation.',
      );
    }

    try {
      await _runtimeManager.ensureBinaryReady();
      return VpnEngineResult(
        state: VpnConnectionState.ready,
        success: true,
        message: runtimeSettings.enableDeviceVpn
            ? 'Desktop runtime validated. Desktop builds keep the same UI but run in proxy mode only.'
            : 'Desktop runtime validated. ${runtimeSettings.proxySummary}',
      );
    } on Object catch (error, stackTrace) {
      _logger.error(_tag, 'Desktop runtime validation failed.', error: error, stackTrace: stackTrace);
      return VpnEngineResult(
        state: VpnConnectionState.failed,
        success: false,
        message: '$error',
      );
    }
  }

  @override
  Future<VpnEngineResult> connect(ConfigEntry entry, RuntimeSettings runtimeSettings) async {
    if (!entry.isXrayReady || entry.xrayConfigJson == null) {
      return const VpnEngineResult(
        state: VpnConnectionState.failed,
        success: false,
        message: 'Connect blocked because Xray JSON is unavailable.',
      );
    }

    final DesktopRuntimeStartResult result = await _runtimeManager.startPersistentRuntime(
      configId: entry.id,
      displayName: entry.name,
      configJson: entry.xrayConfigJson!,
      runtimeSettings: runtimeSettings,
    );

    return VpnEngineResult(
      state: result.success ? VpnConnectionState.connected : VpnConnectionState.failed,
      success: result.success,
      message: result.message,
      sessionId: result.sessionId,
    );
  }

  @override
  Future<VpnEngineResult> disconnect(ConfigEntry entry) async {
    await _runtimeManager.stopActiveRuntime();
    return const VpnEngineResult(
      state: VpnConnectionState.idle,
      success: true,
      message: 'Desktop runtime stopped.',
    );
  }
}
