import 'dart:io';

import 'package:flutter/services.dart';

class RuntimeBridge {
  RuntimeBridge._();

  static const MethodChannel _channel = MethodChannel('aw_manager_ui/xray_core');

  static Future<bool> ensureVpnPermission() async {
    if (!Platform.isAndroid) {
      return false;
    }
    final bool? granted = await _channel.invokeMethod<bool>('ensureVpnPermission');
    return granted ?? false;
  }

  static Future<bool> isVpnPermissionGranted() async {
    if (!Platform.isAndroid) {
      return false;
    }
    final bool? granted = await _channel.invokeMethod<bool>('isVpnPermissionGranted');
    return granted ?? false;
  }

  static Future<Map<Object?, Object?>?> pingProxy({
    required int httpPort,
    int socksPort = 10809,
    String url = 'https://www.google.com/generate_204',
    String? configId,
    String? displayName,
    String? configJson,
    String? targetHost,
    int? targetPort,
  }) async {
    if (!Platform.isAndroid) {
      return <Object?, Object?>{
        'success': false,
        'message': 'Real runtime-assisted ping is only implemented on Android builds.',
      };
    }
    return _channel.invokeMapMethod<Object?, Object?>(
      'pingProxy',
      <String, Object?>{
        'httpPort': httpPort,
        'socksPort': socksPort,
        'url': url,
        'configId': configId,
        'displayName': displayName,
        'configJson': configJson,
        'targetHost': targetHost,
        'targetPort': targetPort,
      },
    );
  }
}
