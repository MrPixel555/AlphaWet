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
    final bool proxyAvailable = await _isLocalTcpPortOpen(httpPort);

    if (proxyAvailable) {
      try {
        return await _probeThroughHttpProxy(httpPort: httpPort, url: url);
      } catch (error) {
        if (targetHost != null && targetPort != null) {
          final Map<Object?, Object?> direct = await _probeDirectTcp(
            host: targetHost,
            port: targetPort,
          );
          return <Object?, Object?>{
            ...direct,
            'message': '${direct['message']} Proxy probe via 127.0.0.1:$httpPort failed first: $error',
          };
        }
        return <Object?, Object?>{
          'success': false,
          'message': 'Proxy probe via 127.0.0.1:$httpPort failed: $error',
        };
      }
    }

    if (targetHost != null && targetPort != null) {
      final Map<Object?, Object?> direct = await _probeDirectTcp(
        host: targetHost,
        port: targetPort,
      );
      return <Object?, Object?>{
        ...direct,
        'message': '${direct['message']} (Direct server probe used because the local Xray proxy is not active yet.)',
      };
    }

    try {
      return await _channel.invokeMapMethod<Object?, Object?>(
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
    } on MissingPluginException {
      return <Object?, Object?>{
        'success': false,
        'message': 'Ping is unavailable because no local proxy is active and the Android runtime bridge is missing.',
      };
    } on PlatformException catch (error) {
      return <Object?, Object?>{
        'success': false,
        'message': error.message ?? 'Ping is unavailable because no local proxy is active.',
      };
    }
  }

  static Future<bool> _isLocalTcpPortOpen(int port) async {
    try {
      final Socket socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 600),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<Object?, Object?>> _probeThroughHttpProxy({
    required int httpPort,
    required String url,
  }) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = (_) => 'PROXY 127.0.0.1:$httpPort';

    try {
      final Uri uri = Uri.parse(url);
      final HttpClientRequest request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'AW-Manager-UI/1.0');
      final HttpClientResponse response = await request.close();
      await response.drain<void>();
      stopwatch.stop();
      final int elapsedMs = stopwatch.elapsedMilliseconds <= 0 ? 1 : stopwatch.elapsedMilliseconds;
      final int code = response.statusCode;
      final bool success = (code >= 200 && code < 400) || code == 204;
      return <Object?, Object?>{
        'success': success,
        'latencyMs': elapsedMs,
        'message': success
            ? 'Proxy path to google.com is reachable in ${elapsedMs} ms (HTTP $code).'
            : 'Proxy reached the remote endpoint, but google.com returned HTTP $code.',
      };
    } finally {
      client.close(force: true);
    }
  }

  static Future<Map<Object?, Object?>> _probeDirectTcp({
    required String host,
    required int port,
  }) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    try {
      final Socket socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      socket.destroy();
      stopwatch.stop();
      final int elapsedMs = stopwatch.elapsedMilliseconds <= 0 ? 1 : stopwatch.elapsedMilliseconds;
      return <Object?, Object?>{
        'success': true,
        'latencyMs': elapsedMs,
        'message': 'TCP reachability to $host:$port succeeded in ${elapsedMs} ms.',
      };
    } catch (error) {
      return <Object?, Object?>{
        'success': false,
        'message': 'TCP reachability to $host:$port failed: $error',
      };
    }
  }
}
