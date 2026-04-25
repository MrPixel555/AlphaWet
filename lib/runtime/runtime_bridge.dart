import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'desktop_xray_runtime.dart';

class RuntimeBridge {
  RuntimeBridge._();

  static const MethodChannel _channel = MethodChannel('alphawet/xray_core');

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


  static Future<bool> ensureManageStoragePermission() async {
    if (!Platform.isAndroid) {
      return true;
    }
    final bool? granted = await _channel.invokeMethod<bool>('ensureManageStoragePermission');
    return granted ?? false;
  }

  static Future<Map<Object?, Object?>?> performPostConnectSecurityCheck({
    required String configId,
    required String displayName,
    required bool enableDeviceVpn,
    required bool vpnPermissionGranted,
    required String? configJson,
    required int httpPort,
    required int socksPort,
  }) async {
    if (!Platform.isAndroid) {
      return <Object?, Object?>{
        'success': true,
        'state': 'connected',
        'message': 'Post-connect security check is only active on Android.',
      };
    }
    try {
      return await _channel.invokeMapMethod<Object?, Object?>(
        'performPostConnectSecurityCheck',
        <String, Object?>{
          'configId': configId,
          'displayName': displayName,
          'enableDeviceVpn': enableDeviceVpn,
          'vpnPermissionGranted': vpnPermissionGranted,
          'configJson': configJson,
          'httpPort': httpPort,
          'socksPort': socksPort,
        },
      ).timeout(
        const Duration(seconds: 18),
        onTimeout: () => <Object?, Object?>{
          'success': false,
          'state': 'failed',
          'message': 'Authentication timed out before AlphaWet could mark the connection active.',
        },
      );
    } on MissingPluginException {
      return <Object?, Object?>{'success': false, 'state': 'failed', 'message': 'Android runtime bridge is missing.'};
    } on PlatformException catch (error) {
      return <Object?, Object?>{'success': false, 'state': 'failed', 'message': error.message ?? 'Post-connect security check failed.'};
    }
  }

  static Future<Map<Object?, Object?>?> getCoreStatus() async {
    if (Platform.isWindows || Platform.isLinux) {
      return DesktopXrayRuntimeManager.instance.currentStatus();
    }
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
    if (Platform.isWindows || Platform.isLinux) {
      if (configJson == null || configJson.trim().isEmpty) {
        return <Object?, Object?>{
          'success': false,
          'message': 'Ping is unavailable because the desktop runtime config is empty.',
        };
      }

      try {
        final List<int> pingPorts = await _allocateTransientPingPorts(
          preferredHttpPort: httpPort,
          preferredSocksPort: socksPort,
        );
        final String? normalizedConfigJson = _buildGooglePingConfigJson(
          configJson: configJson,
          httpPort: pingPorts[0],
          socksPort: pingPorts[1],
        );

        if (normalizedConfigJson == null) {
          return <Object?, Object?>{
            'success': false,
            'message': 'Ping is unavailable because the runtime config could not be normalized.',
          };
        }

        return DesktopXrayRuntimeManager.instance.pingWithTemporaryRuntime(
          configJson: normalizedConfigJson,
          httpPort: pingPorts[0],
          socksPort: pingPorts[1],
          url: url,
        );
      } on SocketException catch (error) {
        return <Object?, Object?>{
          'success': false,
          'message': error.message,
        };
      }
    }

    try {
      final List<int> pingPorts = await _allocateTransientPingPorts(
        preferredHttpPort: httpPort,
        preferredSocksPort: socksPort,
      );
      final String? normalizedConfigJson = _buildGooglePingConfigJson(
        configJson: configJson,
        httpPort: pingPorts[0],
        socksPort: pingPorts[1],
      );

      return await _channel.invokeMapMethod<Object?, Object?>(
        'pingProxy',
        <String, Object?>{
          'httpPort': pingPorts[0],
          'socksPort': pingPorts[1],
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
    } on SocketException catch (error) {
      return <Object?, Object?>{
        'success': false,
        'message': error.message,
      };
    }
  }

  static Future<List<int>> _allocateTransientPingPorts({
    required int preferredHttpPort,
    required int preferredSocksPort,
  }) async {
    Future<int> reserve(int preferred, {int? avoid}) async {
      final List<int> candidates = <int>[
        if (preferred > 0 && preferred <= 65535) preferred,
        0,
      ];
      for (final int candidate in candidates) {
        ServerSocket? socket;
        try {
          socket = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            candidate,
            shared: false,
          );
          final int port = socket.port;
          if (avoid != null && port == avoid) {
            await socket.close();
            continue;
          }
          await socket.close();
          return port;
        } catch (_) {
          await socket?.close();
        }
      }
      throw const SocketException('Failed to reserve transient loopback port for ping.');
    }

    final int http = await reserve(preferredHttpPort);
    final int socks = await reserve(preferredSocksPort, avoid: http);
    return <int>[http, socks];
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
