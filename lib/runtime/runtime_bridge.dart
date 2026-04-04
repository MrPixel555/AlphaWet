import 'dart:convert';
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

  static Future<Map<Object?, Object?>?> getCoreStatus() async {
    if (!Platform.isAndroid) {
      return <Object?, Object?>{
        'success': true,
        'state': 'idle',
        'message': 'Android runtime bridge is not active on this platform.',
      };
    }
    try {
      return await _channel.invokeMapMethod<Object?, Object?>('getCoreStatus');
    } on MissingPluginException {
      return <Object?, Object?>{
        'success': false,
        'state': 'failed',
        'message': 'Android runtime bridge is missing.',
      };
    } on PlatformException catch (error) {
      return <Object?, Object?>{
        'success': false,
        'state': 'failed',
        'message': error.message ?? 'Failed to query runtime state.',
      };
    }
  }

  static Future<List<int>> findOccupiedLocalPorts(Iterable<int> ports) async {
    final List<int> occupied = <int>[];
    final List<int> uniquePorts = ports.toSet().toList(growable: false)..sort();

    for (final int port in uniquePorts) {
      if (port <= 0 || port > 65535) {
        occupied.add(port);
        continue;
      }
      ServerSocket? server;
      try {
        server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
          shared: false,
        );
      } catch (_) {
        occupied.add(port);
      } finally {
        await server?.close();
      }
    }

    return occupied;
  }

  static Future<Map<Object?, Object?>?> pingProxy({
    required int httpPort,
    int socksPort = 10809,
    String url = 'https://www.google.com/generate_204',
    String? configId,
    String? displayName,
    String? configJson,
  }) async {
    final String? normalizedConfigJson = _buildGooglePingConfigJson(
      configJson: configJson,
      httpPort: httpPort,
      socksPort: socksPort,
    );

    try {
      return await _channel.invokeMapMethod<Object?, Object?>(
        'pingProxy',
        <String, Object?>{
          'httpPort': httpPort,
          'socksPort': socksPort,
          'url': url,
          'configId': configId,
          'displayName': displayName,
          'configJson': normalizedConfigJson,
        },
      );
    } on MissingPluginException {
      return <Object?, Object?>{
        'success': false,
        'message': 'Ping is unavailable because the Android runtime bridge is missing.',
      };
    } on PlatformException catch (error) {
      return <Object?, Object?>{
        'success': false,
        'message': error.message ?? 'Ping is unavailable right now.',
      };
    }
  }

  static String? _buildGooglePingConfigJson({
    required String? configJson,
    required int httpPort,
    required int socksPort,
  }) {
    if (configJson == null || configJson.trim().isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(configJson);
      if (decoded is! Map<String, dynamic>) {
        return configJson;
      }
      final Map<String, dynamic> root = Map<String, dynamic>.from(decoded);
      root['awManagerRuntime'] = <String, dynamic>{
        'httpPort': httpPort,
        'socksPort': socksPort,
        'deviceVpnRequested': false,
        'pingOnly': true,
      };
      root['inbounds'] = <Object>[
        <String, dynamic>{
          'tag': 'socks-in',
          'listen': '127.0.0.1',
          'port': socksPort,
          'protocol': 'socks',
          'settings': <String, dynamic>{
            'udp': true,
            'auth': 'noauth',
          },
          'sniffing': <String, dynamic>{
            'enabled': true,
            'destOverride': <String>['http', 'tls', 'quic'],
          },
        },
        <String, dynamic>{
          'tag': 'http-in',
          'listen': '127.0.0.1',
          'port': httpPort,
          'protocol': 'http',
          'settings': <String, dynamic>{},
          'sniffing': <String, dynamic>{
            'enabled': true,
            'destOverride': <String>['http', 'tls'],
          },
        },
      ];
      return const JsonEncoder.withIndent('  ').convert(root);
    } catch (_) {
      return configJson;
    }
  }
}
