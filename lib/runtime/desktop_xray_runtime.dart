import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/runtime_settings.dart';
import '../services/app_logger.dart';

class DesktopXrayRuntimeManager {
  DesktopXrayRuntimeManager._();

  static final DesktopXrayRuntimeManager instance = DesktopXrayRuntimeManager._();

  static const String _tag = 'DesktopXrayRuntime';

  final AppLogger _logger = AppLogger.instance;

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  File? _activeConfigFile;
  String? _activeConfigId;
  String? _activeDisplayName;
  String? _sessionId;
  String? _lastMessage;
  DateTime? _startedAt;
  bool _activeDeviceTunnelMode = false;

  bool get isSupportedDesktop => Platform.isWindows || Platform.isLinux;

  bool get isRunning => _process != null;

  Map<Object?, Object?> currentStatus() {
    if (!isSupportedDesktop) {
      return <Object?, Object?>{
        'success': false,
        'state': 'failed',
        'message': 'Desktop Xray runtime is unsupported on this platform.',
        'deviceVpnMode': _activeDeviceTunnelMode,
      };
    }

    if (_process == null) {
      return <Object?, Object?>{
        'success': true,
        'state': 'idle',
        'message': _lastMessage ?? 'Desktop Xray runtime is idle.',
        'deviceVpnMode': _activeDeviceTunnelMode,
      };
    }

    return <Object?, Object?>{
      'success': true,
      'state': 'running',
      'message': _lastMessage ?? 'Desktop Xray runtime is active.',
      'configId': _activeConfigId,
      'displayName': _activeDisplayName,
      'sessionId': _sessionId,
      'deviceVpnMode': _activeDeviceTunnelMode,
      'startedAt': _startedAt?.toIso8601String(),
    };
  }

  Future<String> ensureBinaryReady({bool deviceTunnelRequested = false}) async {
    if (!isSupportedDesktop) {
      throw UnsupportedError('Desktop Xray runtime is only supported on Windows and Linux.');
    }

    final Directory runtimeDirectory = await _runtimeDirectory();
    await runtimeDirectory.create(recursive: true);

    final String assetKey = Platform.isWindows
        ? 'assets/xray/desktop/xray.exe'
        : 'assets/xray/desktop/xray';
    final String binaryName = Platform.isWindows ? 'xray.exe' : 'xray';
    final File binaryFile = File('${runtimeDirectory.path}${Platform.pathSeparator}$binaryName');

    await _stageRequiredAsset(assetKey, binaryFile);
    if (Platform.isWindows && deviceTunnelRequested) {
      await _stageRequiredAsset(
        'assets/xray/desktop/wintun.dll',
        File('${runtimeDirectory.path}${Platform.pathSeparator}wintun.dll'),
      );
    } else if (Platform.isWindows) {
      await _stageOptionalAsset(
        'assets/xray/desktop/wintun.dll',
        File('${runtimeDirectory.path}${Platform.pathSeparator}wintun.dll'),
      );
    }
    await _stageOptionalAsset(
      'assets/xray/common/geoip.dat',
      File('${runtimeDirectory.path}${Platform.pathSeparator}geoip.dat'),
    );
    await _stageOptionalAsset(
      'assets/xray/common/geosite.dat',
      File('${runtimeDirectory.path}${Platform.pathSeparator}geosite.dat'),
    );

    if (!Platform.isWindows) {
      final ProcessResult chmodResult = await Process.run('chmod', <String>['755', binaryFile.path]);
      if (chmodResult.exitCode != 0) {
        throw ProcessException(
          'chmod',
          <String>['755', binaryFile.path],
          '${chmodResult.stdout}\n${chmodResult.stderr}',
          chmodResult.exitCode,
        );
      }
    }

    return binaryFile.path;
  }

  Future<Map<Object?, Object?>> pingWithTemporaryRuntime({
    required String configJson,
    required int httpPort,
    required int socksPort,
    required String url,
  }) async {
    if (!isSupportedDesktop) {
      return <Object?, Object?>{
        'success': false,
        'message': 'Desktop ping runtime is unsupported on this platform.',
      };
    }

    final String binaryPath;
    try {
      binaryPath = await ensureBinaryReady(deviceTunnelRequested: false);
    } on Object catch (error, stackTrace) {
      _logger.error(_tag, 'Failed to prepare desktop Xray binary for ping.', error: error, stackTrace: stackTrace);
      return <Object?, Object?>{
        'success': false,
        'message': '$error',
      };
    }

    final File tempConfigFile = await _writeConfigFile(
      configId: 'ping-${DateTime.now().microsecondsSinceEpoch}',
      configJson: configJson,
    );

    Process? process;
    try {
      process = await Process.start(
        binaryPath,
        <String>['run', '-config', tempConfigFile.path],
        runInShell: false,
        mode: ProcessStartMode.normal,
        workingDirectory: tempConfigFile.parent.path,
      );

      final StreamSubscription<String> stdoutSubscription = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((String line) => _logger.info(_tag, '[ping stdout] $line'));
      final StreamSubscription<String> stderrSubscription = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((String line) => _logger.warning(_tag, '[ping stderr] $line'));

      await Future<void>.delayed(const Duration(milliseconds: 1400));
      final int? earlyExitCode = await _tryReadExitCode(process, const Duration(milliseconds: 10));
      if (earlyExitCode != null) {
        await stdoutSubscription.cancel();
        await stderrSubscription.cancel();
        return <Object?, Object?>{
          'success': false,
          'message': 'Desktop Xray exited before the proxy listeners became ready (exit code $earlyExitCode).',
        };
      }

      final Map<Object?, Object?> pingResult = await _pingThroughHttpProxy(
        httpPort: httpPort,
        url: url,
      );

      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      return pingResult;
    } on Object catch (error, stackTrace) {
      _logger.error(_tag, 'Desktop ping runtime failed.', error: error, stackTrace: stackTrace);
      return <Object?, Object?>{
        'success': false,
        'message': '$error',
      };
    } finally {
      if (process != null) {
        process.kill();
        await _tryReadExitCode(process, const Duration(seconds: 2));
      }
      await _deleteIfExists(tempConfigFile);
    }
  }

  Future<void> stopActiveRuntime() async {
    final Process? process = _process;
    if (process == null) {
      _lastMessage = 'Desktop runtime is already stopped.';
      return;
    }

    _logger.info(_tag, 'Stopping desktop Xray runtime.');
    process.kill();
    await _tryReadExitCode(process, const Duration(seconds: 4));
    await _clearActiveRuntime('Desktop runtime stopped.');
  }

  Future<DesktopRuntimeStartResult> startPersistentRuntime({
    required String configId,
    required String displayName,
    required String configJson,
    required RuntimeSettings runtimeSettings,
  }) async {
    if (!isSupportedDesktop) {
      return const DesktopRuntimeStartResult(
        success: false,
        message: 'Desktop Xray runtime is unsupported on this platform.',
      );
    }

    final String binaryPath;
    try {
      binaryPath = await ensureBinaryReady(deviceTunnelRequested: runtimeSettings.enableDeviceVpn);
    } on Object catch (error, stackTrace) {
      _logger.error(_tag, 'Failed to prepare desktop Xray binary.', error: error, stackTrace: stackTrace);
      return DesktopRuntimeStartResult(success: false, message: '$error');
    }

    await stopActiveRuntime();

    final File configFile = await _writeConfigFile(configId: configId, configJson: configJson);

    try {
      final Process process = await Process.start(
        binaryPath,
        <String>['run', '-config', configFile.path],
        runInShell: false,
        mode: ProcessStartMode.normal,
        workingDirectory: configFile.parent.path,
      );

      final String sessionId = 'desktop-$configId-${DateTime.now().microsecondsSinceEpoch}';

      _process = process;
      _activeConfigFile = configFile;
      _activeConfigId = configId;
      _activeDisplayName = displayName;
      _sessionId = sessionId;
      _startedAt = DateTime.now();
      _activeDeviceTunnelMode = runtimeSettings.enableDeviceVpn;
      _lastMessage = runtimeSettings.enableDeviceVpn
          ? (Platform.isWindows
              ? 'Desktop runtime started in TUN mode. ${runtimeSettings.proxySummary}'
              : 'Desktop runtime started in VPN mode. ${runtimeSettings.proxySummary}')
          : 'Desktop runtime started. ${runtimeSettings.proxySummary}';

      _stdoutSubscription = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((String line) => _logger.info(_tag, '[stdout] $line'));
      _stderrSubscription = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((String line) => _logger.warning(_tag, '[stderr] $line'));

      unawaited(process.exitCode.then((int exitCode) async {
        _logger.warning(_tag, 'Desktop Xray process exited with code $exitCode.');
        if (identical(_process, process)) {
          await _clearActiveRuntime('Desktop runtime exited with code $exitCode.');
        }
      }));

      await Future<void>.delayed(const Duration(milliseconds: 1400));
      final int? earlyExitCode = await _tryReadExitCode(process, const Duration(milliseconds: 10));
      if (earlyExitCode != null) {
        await _clearActiveRuntime('Desktop runtime exited with code $earlyExitCode.');
        return DesktopRuntimeStartResult(
          success: false,
          message: 'Desktop Xray exited before the proxy listeners became ready (exit code $earlyExitCode).',
        );
      }

      return DesktopRuntimeStartResult(
        success: true,
        message: runtimeSettings.enableDeviceVpn
            ? (Platform.isWindows
                ? 'Desktop runtime started in TUN mode. ${runtimeSettings.proxySummary}'
                : 'Desktop runtime started in VPN mode. ${runtimeSettings.proxySummary}')
            : 'Desktop runtime started. ${runtimeSettings.proxySummary}',
        sessionId: sessionId,
      );
    } on Object catch (error, stackTrace) {
      _logger.error(_tag, 'Failed to start desktop Xray runtime.', error: error, stackTrace: stackTrace);
      await _deleteIfExists(configFile);
      return DesktopRuntimeStartResult(success: false, message: '$error');
    }
  }

  Future<File> _writeConfigFile({
    required String configId,
    required String configJson,
  }) async {
    final Directory runtimeDirectory = await _runtimeDirectory();
    await runtimeDirectory.create(recursive: true);

    jsonDecode(configJson);

    final String safeConfigId = configId.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
    final File configFile = File(
      '${runtimeDirectory.path}${Platform.pathSeparator}$safeConfigId.json',
    );
    await configFile.writeAsString(configJson, flush: true);
    return configFile;
  }

  Future<Directory> _runtimeDirectory() async {
    final Directory appSupportDirectory = await getApplicationSupportDirectory();
    return Directory('${appSupportDirectory.path}${Platform.pathSeparator}xray-runtime');
  }

  Future<void> _stageRequiredAsset(String assetKey, File outputFile) async {
    try {
      final ByteData assetData = await rootBundle.load(assetKey);
      final Uint8List bytes = assetData.buffer.asUint8List(
        assetData.offsetInBytes,
        assetData.lengthInBytes,
      );
      await _writeBytesIfChanged(outputFile, bytes);
    } on FlutterError catch (error, stackTrace) {
      _logger.error(_tag, 'Missing required desktop asset: $assetKey', error: error, stackTrace: stackTrace);
      throw StateError(
        'Required runtime asset "$assetKey" is missing. Refresh the desktop runtimes and activate the target bundle before building.',
      );
    }
  }

  Future<void> _stageOptionalAsset(String assetKey, File outputFile) async {
    try {
      final ByteData assetData = await rootBundle.load(assetKey);
      final Uint8List bytes = assetData.buffer.asUint8List(
        assetData.offsetInBytes,
        assetData.lengthInBytes,
      );
      await _writeBytesIfChanged(outputFile, bytes);
    } on FlutterError {
      // Optional desktop asset.
    }
  }

  Future<void> _writeBytesIfChanged(File outputFile, Uint8List bytes) async {
    await outputFile.parent.create(recursive: true);
    if (await outputFile.exists()) {
      final Uint8List existingBytes = await outputFile.readAsBytes();
      if (existingBytes.length == bytes.length) {
        bool identicalContent = true;
        for (int index = 0; index < bytes.length; index += 1) {
          if (existingBytes[index] != bytes[index]) {
            identicalContent = false;
            break;
          }
        }
        if (identicalContent) {
          return;
        }
      }
    }
    await outputFile.writeAsBytes(bytes, flush: true);
  }

  Future<Map<Object?, Object?>> _pingThroughHttpProxy({
    required int httpPort,
    required String url,
  }) async {
    final HttpClient client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    client.findProxy = (Uri _) => 'PROXY 127.0.0.1:$httpPort';

    final Stopwatch stopwatch = Stopwatch()..start();
    try {
      final HttpClientRequest request = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 10));
      final HttpClientResponse response = await request.close().timeout(const Duration(seconds: 10));
      await response.drain();
      stopwatch.stop();

      final int latencyMs = stopwatch.elapsedMilliseconds;
      if (response.statusCode >= 200 && response.statusCode < 500) {
        return <Object?, Object?>{
          'success': true,
          'latencyMs': latencyMs,
          'message': 'Proxy ping succeeded in $latencyMs ms.',
        };
      }

      return <Object?, Object?>{
        'success': false,
        'latencyMs': latencyMs,
        'message': 'Proxy responded with HTTP ${response.statusCode}.',
      };
    } on Object catch (error) {
      stopwatch.stop();
      return <Object?, Object?>{
        'success': false,
        'message': '$error',
      };
    } finally {
      client.close(force: true);
    }
  }

  Future<int?> _tryReadExitCode(Process process, Duration timeout) async {
    try {
      return await process.exitCode.timeout(timeout);
    } on TimeoutException {
      return null;
    }
  }

  Future<void> _clearActiveRuntime(String message) async {
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;

    final File? configFile = _activeConfigFile;
    _process = null;
    _activeConfigFile = null;
    _activeConfigId = null;
    _activeDisplayName = null;
    _sessionId = null;
    _startedAt = null;
    _activeDeviceTunnelMode = false;
    _lastMessage = message;

    if (configFile != null) {
      await _deleteIfExists(configFile);
    }
  }

  Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) {
      await file.delete();
    }
  }
}

class DesktopRuntimeStartResult {
  const DesktopRuntimeStartResult({
    required this.success,
    required this.message,
    this.sessionId,
  });

  final bool success;
  final String message;
  final String? sessionId;
}
