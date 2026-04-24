import 'dart:io';

import 'package:flutter/services.dart';

import 'runtime_bridge.dart';

import '../models/config_entry.dart';
import '../models/runtime_settings.dart';
import '../models/vpn_runtime_models.dart';
import '../services/app_logger.dart';
import 'vpn_engine.dart';

class XrayCoreVpnEngine implements VpnEngine {
  XrayCoreVpnEngine({AppLogger? logger}) : _logger = logger ?? AppLogger.instance;

  static const MethodChannel _channel = MethodChannel('alphawet/xray_core');
  static const String _tag = 'XrayCoreVpnEngine';
  final AppLogger _logger;

  @override
  Future<VpnEngineResult> validate(ConfigEntry entry, RuntimeSettings runtimeSettings) async {
    if (!Platform.isAndroid) {
      return const VpnEngineResult(
        state: VpnConnectionState.failed,
        success: false,
        message: 'Real Xray runtime is only wired on Android builds.',
      );
    }
    if (!entry.isXrayReady || entry.xrayConfigJson == null) {
      return const VpnEngineResult(
        state: VpnConnectionState.failed,
        success: false,
        message: 'Xray JSON is not ready for runtime validation.',
      );
    }
    try {
      _logger.info(_tag, 'Validating config through Android post-connect security policy.');
      final Map<Object?, Object?>? raw = await RuntimeBridge.performPostConnectSecurityCheck(
        configId: entry.id,
        displayName: entry.name,
        enableDeviceVpn: runtimeSettings.enableDeviceVpn,
        vpnPermissionGranted: runtimeSettings.vpnPermissionGranted,
        configJson: entry.xrayConfigJson,
        httpPort: runtimeSettings.httpPort,
        socksPort: runtimeSettings.socksPort,
      );
      final VpnEngineResult result = _fromChannel(raw);
      if (result.success) {
        _logger.info(_tag, 'Android post-connect security policy passed. ${result.message}');
      } else {
        _logger.error(_tag, 'Android post-connect security policy failed: ${result.message}');
      }
      return result;
    } on MissingPluginException {
      return const VpnEngineResult(
        state: VpnConnectionState.failed,
        success: false,
        message: 'Android runtime bridge is missing. Apply the native overlay before building.',
      );
    } on PlatformException catch (error, stackTrace) {
      _logger.error(_tag, 'validateConfig failed.', error: error, stackTrace: stackTrace);
      return VpnEngineResult(
        state: VpnConnectionState.failed,
        success: false,
        message: error.message ?? 'Android runtime validation failed.',
      );
    }
  }

  @override
  Future<VpnEngineResult> connect(ConfigEntry entry, RuntimeSettings runtimeSettings) async {
    if (!Platform.isAndroid) {
      return const VpnEngineResult(
        state: VpnConnectionState.failed,
        success: false,
        message: 'Real Xray runtime is only wired on Android builds.',
      );
    }
    if (!entry.isXrayReady || entry.xrayConfigJson == null) {
      return const VpnEngineResult(
        state: VpnConnectionState.failed,
        success: false,
        message: 'Connect blocked because Xray JSON is unavailable.',
      );
    }
    if (runtimeSettings.enableDeviceVpn && !runtimeSettings.vpnPermissionGranted) {
      return const VpnEngineResult(
        state: VpnConnectionState.failed,
        success: false,
        message: 'Whole-device tunnel is enabled, but Android VPN permission is not granted yet.',
      );
    }
    try {
      _logger.info(_tag, 'Starting AlphaWet Android runtime.');
      final Map<Object?, Object?>? raw = await _channel.invokeMapMethod<Object?, Object?>(
        'startCore',
        <String, Object?>{
          'configId': entry.id,
          'displayName': entry.name,
          'configJson': entry.xrayConfigJson,
          'httpPort': runtimeSettings.httpPort,
          'socksPort': runtimeSettings.socksPort,
          'enableDeviceVpn': runtimeSettings.enableDeviceVpn,
        },
      );
      final VpnEngineResult result = _fromChannel(raw);
      if (result.success) {
        _logger.info(_tag, 'Android runtime started. ${result.message}');
      } else {
        _logger.error(_tag, 'Android runtime start failed: ${result.message}');
      }
      return result;
    } on MissingPluginException {
      return const VpnEngineResult(
        state: VpnConnectionState.failed,
        success: false,
        message: 'Android runtime bridge is missing. Apply the native overlay before building.',
      );
    } on PlatformException catch (error, stackTrace) {
      _logger.error(_tag, 'startCore failed.', error: error, stackTrace: stackTrace);
      return VpnEngineResult(
        state: VpnConnectionState.failed,
        success: false,
        message: error.message ?? 'Failed to start Android Xray runtime.',
      );
    }
  }

  @override
  Future<VpnEngineResult> disconnect(ConfigEntry entry) async {
    if (!Platform.isAndroid) {
      return const VpnEngineResult(
        state: VpnConnectionState.idle,
        success: true,
        message: 'Mock runtime stopped on this non-Android platform.',
      );
    }
    try {
      _logger.info(_tag, 'Stopping Android Xray core process.');
      final Map<Object?, Object?>? raw = await _channel.invokeMapMethod<Object?, Object?>(
        'stopCore',
        <String, Object?>{
          'configId': entry.id,
        },
      );
      return _fromChannel(raw);
    } on MissingPluginException {
      return const VpnEngineResult(
        state: VpnConnectionState.failed,
        success: false,
        message: 'Android runtime bridge is missing. Apply the native overlay before building.',
      );
    } on PlatformException catch (error, stackTrace) {
      _logger.error(_tag, 'stopCore failed.', error: error, stackTrace: stackTrace);
      return VpnEngineResult(
        state: VpnConnectionState.failed,
        success: false,
        message: error.message ?? 'Failed to stop Android Xray runtime.',
      );
    }
  }

  VpnEngineResult _fromChannel(Map<Object?, Object?>? payload) {
    final Map<Object?, Object?> safePayload = payload ?? const <Object?, Object?>{};
    final String rawState = (safePayload['state'] as String? ?? 'failed').trim().toLowerCase();
    final bool success = safePayload['success'] == true;
    final String message =
        (safePayload['message'] as String? ?? 'Android runtime returned no message.').trim();
    final String? sessionId = (safePayload['sessionId'] as String?)?.trim();

    return VpnEngineResult(
      state: switch (rawState) {
        'idle' => VpnConnectionState.idle,
        'validating' => VpnConnectionState.validating,
        'ready' => VpnConnectionState.ready,
        'connecting' => VpnConnectionState.connecting,
        'running' => VpnConnectionState.connecting,
        'connected' => VpnConnectionState.connected,
        'disconnecting' => VpnConnectionState.disconnecting,
        _ => VpnConnectionState.failed,
      },
      success: success,
      message: message,
      sessionId: sessionId == null || sessionId.isEmpty ? null : sessionId,
    );
  }
}
