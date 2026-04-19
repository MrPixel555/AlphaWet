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
  int? _windowsTunInterfaceIndex;
  String? _windowsPrimaryGateway;
  String? _windowsTunObservedIpv4;
  final Set<String> _windowsTunBypassAddresses = <String>{};

  static String get _windowsSystemRoot =>
      Platform.environment['SystemRoot'] ?? r'C:\Windows';

  static String get _windowsPowerShellPath =>
      '$_windowsSystemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';

  static String get _windowsRoutePath =>
      '$_windowsSystemRoot\\System32\\route.exe';

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
      await _teardownWindowsTunRouting();
      return;
    }

    _logger.info(_tag, 'Stopping desktop Xray runtime.');
    await _teardownWindowsTunRouting();
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
          .listen((String line) {
        _captureWindowsTunTelemetry(line);
        _logger.info(_tag, '[stdout] $line');
      });
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

      if (Platform.isWindows && runtimeSettings.enableDeviceVpn) {
        try {
          await _configureWindowsTunRouting(configJson);
        } on Object catch (error, stackTrace) {
          _logger.error(
            _tag,
            'Failed to configure temporary Windows TUN routing.',
            error: error,
            stackTrace: stackTrace,
          );
          process.kill();
          await _tryReadExitCode(process, const Duration(seconds: 2));
          await _clearActiveRuntime('Desktop runtime failed to install the Windows TUN routes.');
          return DesktopRuntimeStartResult(
            success: false,
            message: '$error',
          );
        }
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
    await _teardownWindowsTunRouting();
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

  Future<void> _configureWindowsTunRouting(String configJson) async {
    if (!Platform.isWindows) {
      return;
    }

    if (!await _isWindowsAdministrator()) {
      throw const ProcessException(
        'route',
        <String>[],
        'Windows TUN mode needs Administrator privileges so AlphaWet can install temporary routes.',
        5,
      );
    }

    const String tunAdapterName = 'alphawet';

    await _teardownWindowsTunRouting();
    _windowsTunObservedIpv4 = null;

    final Map<String, dynamic> decodedConfig =
        Map<String, dynamic>.from(jsonDecode(configJson) as Map<Object?, Object?>);
    final Set<String> upstreamHosts = _extractUpstreamHosts(decodedConfig);
    final Set<String> upstreamAddresses = await _resolveIpv4Addresses(upstreamHosts);
    if (upstreamAddresses.isEmpty) {
      throw const FormatException(
        'Could not resolve the upstream server address for Windows TUN mode.',
      );
    }

    final _WindowsRouteInfo primaryRoute = await _readWindowsPrimaryRoute();

    await _runWindowsTunDefaultRouteDeleteByName(tunAdapterName);

    for (final String address in upstreamAddresses) {
      await _runWindowsRouteDelete(
        <String>[
          'DELETE',
          address,
          'MASK',
          '255.255.255.255',
          primaryRoute.nextHop,
        ],
      );
      await _runWindowsRoute(
        <String>[
          'ADD',
          address,
          'MASK',
          '255.255.255.255',
          primaryRoute.nextHop,
          'METRIC',
          '1',
        ],
      );
      _windowsTunBypassAddresses.add(address);
    }

    await _runWindowsTunDefaultRouteAddByName(tunAdapterName);

    try {
      _windowsTunInterfaceIndex = await _waitForWindowsTunInterfaceIndex(tunAdapterName);
    } on Object catch (error, stackTrace) {
      _logger.warning(
        _tag,
        'Windows TUN interface index could not be resolved after route installation. Continuing with alias-based cleanup only.',
        error: error,
        stackTrace: stackTrace,
      );
      _windowsTunInterfaceIndex = null;
    }

    _windowsPrimaryGateway = primaryRoute.nextHop;

    _logger.info(
      _tag,
      'Installed Windows TUN routes. tunAlias=$tunAdapterName, tunIf=${_windowsTunInterfaceIndex ?? 'unknown'}, upstreamBypass=${upstreamAddresses.join(', ')}',
    );
  }

  Future<void> _teardownWindowsTunRouting() async {
    if (!Platform.isWindows) {
      return;
    }

    const String tunAdapterName = 'alphawet';

    final int? tunInterfaceIndex = _windowsTunInterfaceIndex;
    if (tunInterfaceIndex != null) {
      await _runWindowsRouteDelete(
        <String>['DELETE', '0.0.0.0', 'MASK', '0.0.0.0', '0.0.0.0', 'IF', '$tunInterfaceIndex'],
      );
    }
    await _runWindowsTunDefaultRouteDeleteByName(tunAdapterName);

    final String? primaryGateway = _windowsPrimaryGateway;
    if (primaryGateway != null) {
      for (final String address in _windowsTunBypassAddresses) {
        await _runWindowsRouteDelete(
          <String>[
            'DELETE',
            address,
            'MASK',
            '255.255.255.255',
            primaryGateway,
          ],
        );
      }
    }

    _windowsTunInterfaceIndex = null;
    _windowsPrimaryGateway = null;
    _windowsTunObservedIpv4 = null;
    _windowsTunBypassAddresses.clear();
  }

  void _captureWindowsTunTelemetry(String line) {
    if (!Platform.isWindows || !_activeDeviceTunnelMode) {
      return;
    }

    final RegExpMatch? match = RegExp(
      r'from (?:udp|tcp):((?:\d{1,3}\.){3}\d{1,3})(?::\d+)? .*\[tun-in ->',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) {
      return;
    }

    final String candidate = match.group(1)?.trim() ?? '';
    if (candidate.isEmpty ||
        !candidate.startsWith('169.254.') ||
        candidate == '169.254.255.255') {
      return;
    }

    if (_windowsTunObservedIpv4 == candidate) {
      return;
    }

    _windowsTunObservedIpv4 = candidate;
    _logger.info(_tag, 'Observed Windows TUN IPv4 address from runtime traffic: $candidate');
  }

  Set<String> _extractUpstreamHosts(Map<String, dynamic> config) {
    final Set<String> hosts = <String>{};
    final Object? outboundsObject = config['outbounds'];
    if (outboundsObject is! List) {
      return hosts;
    }

    for (final Object? outboundObject in outboundsObject) {
      if (outboundObject is! Map) {
        continue;
      }
      final Map<String, dynamic> outbound = Map<String, dynamic>.from(outboundObject);
      final Object? settingsObject = outbound['settings'];
      if (settingsObject is! Map) {
        continue;
      }
      final Map<String, dynamic> settings = Map<String, dynamic>.from(settingsObject);

      final Object? vnextObject = settings['vnext'];
      if (vnextObject is List) {
        for (final Object? serverObject in vnextObject) {
          if (serverObject is! Map) {
            continue;
          }
          final Map<String, dynamic> server = Map<String, dynamic>.from(serverObject);
          final String? address = server['address'] as String?;
          if (address != null && address.trim().isNotEmpty) {
            hosts.add(address.trim());
          }
        }
      }

      final Object? serversObject = settings['servers'];
      if (serversObject is List) {
        for (final Object? serverObject in serversObject) {
          if (serverObject is! Map) {
            continue;
          }
          final Map<String, dynamic> server = Map<String, dynamic>.from(serverObject);
          final String? address = server['address'] as String?;
          if (address != null && address.trim().isNotEmpty) {
            hosts.add(address.trim());
          }
        }
      }
    }

    return hosts;
  }

  Future<Set<String>> _resolveIpv4Addresses(Set<String> hosts) async {
    final Set<String> addresses = <String>{};
    for (final String host in hosts) {
      final String trimmedHost = host.trim();
      if (trimmedHost.isEmpty) {
        continue;
      }

      final InternetAddress? parsed = InternetAddress.tryParse(trimmedHost);
      if (parsed != null) {
        if (parsed.type == InternetAddressType.IPv4) {
          addresses.add(parsed.address);
        }
        continue;
      }

      try {
        final List<InternetAddress> lookupResult = await InternetAddress.lookup(trimmedHost);
        for (final InternetAddress address in lookupResult) {
          if (address.type == InternetAddressType.IPv4) {
            addresses.add(address.address);
          }
        }
      } on SocketException catch (error, stackTrace) {
        _logger.warning(
          _tag,
          'Failed to resolve Windows TUN upstream host "$trimmedHost".',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return addresses;
  }

  Future<_WindowsRouteInfo> _readWindowsPrimaryRoute() async {
    const String cimRouteScript = r'''$ErrorActionPreference = 'Stop'
$route = Get-CimInstance -Namespace 'root/CIMV2' -ClassName Win32_IP4RouteTable -ErrorAction Stop |
  Where-Object {
    $_.Destination -eq '0.0.0.0' -and
    $_.Mask -eq '0.0.0.0' -and
    $_.NextHop -ne '0.0.0.0' -and
    $_.NextHop -ne $null
  } |
  Sort-Object Metric1 |
  Select-Object -First 1 InterfaceIndex, NextHop

if ($null -eq $route -or [string]::IsNullOrWhiteSpace([string]$route.NextHop)) {
  exit 2
}

Write-Output ("{0}|{1}" -f ([int]$route.InterfaceIndex), ([string]$route.NextHop))
''';

    final ProcessResult cimResult = await Process.run(
      _windowsPowerShellPath,
      <String>['-NoProfile', '-Command', cimRouteScript],
      runInShell: false,
    );

    final String cimPayload = _extractWindowsScriptPayload('${cimResult.stdout}');
    if (cimResult.exitCode == 0 && cimPayload.contains('|')) {
      final _WindowsRouteInfo? parsed = _parseWindowsRouteLine(cimPayload);
      if (parsed != null) {
        return parsed;
      }
    }

    final ProcessResult routePrintResult = await Process.run(
      _windowsRoutePath,
      <String>['print', '-4'],
      runInShell: false,
    );
    if (routePrintResult.exitCode != 0) {
      throw ProcessException(
        _windowsRoutePath,
        <String>['print', '-4'],
        '${routePrintResult.stdout}\n${routePrintResult.stderr}',
        routePrintResult.exitCode,
      );
    }

    final _WindowsRouteInfo? parsedRoute = _parseWindowsPrimaryRouteFromRoutePrint(
      '${routePrintResult.stdout}',
    );
    if (parsedRoute != null) {
      return parsedRoute;
    }

    throw const FormatException(
      'Failed to detect the active Windows default route from route print output.',
    );
  }

  _WindowsRouteInfo? _parseWindowsRouteLine(String payload) {
    final List<String> parts = payload.split('|');
    if (parts.length < 2) {
      return null;
    }

    final int? interfaceIndex = int.tryParse(parts.first.trim());
    final String nextHop = parts.sublist(1).join('|').trim();
    if (interfaceIndex == null || nextHop.isEmpty) {
      return null;
    }

    return _WindowsRouteInfo(interfaceIndex: interfaceIndex, nextHop: nextHop);
  }

  String _extractWindowsScriptPayload(String stdout) {
    for (final String line in stdout.split(RegExp(r'\r?\n'))) {
      final String trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return '';
  }

  _WindowsRouteInfo? _parseWindowsPrimaryRouteFromRoutePrint(String output) {
    final RegExp routeLinePattern = RegExp(
      r'^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\S+)\s+(\S+)\s+(\d+)\s*$');
    final List<_WindowsRouteCandidate> candidates = <_WindowsRouteCandidate>[];

    bool inActiveRoutes = false;

    for (final String rawLine in output.split(RegExp(r'\r?\n'))) {
      final String trimmed = rawLine.trim();
      if (trimmed.isEmpty) {
        continue;
      }

      if (trimmed == 'Active Routes:') {
        inActiveRoutes = true;
        continue;
      }
      if (trimmed == 'Persistent Routes:') {
        break;
      }
      if (!inActiveRoutes) {
        continue;
      }

      final RegExpMatch? routeMatch = routeLinePattern.firstMatch(trimmed);
      if (routeMatch == null) {
        continue;
      }

      final String nextHop = routeMatch.group(1)!.trim();
      final int? metric = int.tryParse(routeMatch.group(3)!);
      if (metric == null || nextHop == 'On-link' || nextHop == '0.0.0.0') {
        continue;
      }

      candidates.add(
        _WindowsRouteCandidate(
          interfaceIndex: 0,
          nextHop: nextHop,
          metric: metric,
        ),
      );
    }

    if (candidates.isEmpty) {
      return null;
    }

    candidates.sort((a, b) => a.metric.compareTo(b.metric));
    final _WindowsRouteCandidate best = candidates.first;
    return _WindowsRouteInfo(
      interfaceIndex: best.interfaceIndex,
      nextHop: best.nextHop,
    );
  }

  Future<int> _waitForWindowsTunInterfaceIndex(String adapterName) async {
    final String escapedAdapterName = adapterName.replaceAll("'", "''");
    String adapterLookupScript = r'''$ErrorActionPreference = 'Stop'
$AdapterName = '__ADAPTER_NAME__'
$ObservedIp = '__OBSERVED_IP__'

function Emit-AdapterLine($adapter) {
  if ($null -eq $adapter) {
    return $false
  }

  $interfaceIndex = $adapter.InterfaceIndex
  if ($null -eq $interfaceIndex -and $null -ne $adapter.ifIndex) {
    $interfaceIndex = $adapter.ifIndex
  }
  if ($null -eq $interfaceIndex) {
    return $false
  }

  Write-Output ([string]([int]$interfaceIndex))
  return $true
}

try {
  $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop |
    Select-Object -First 1 @{Name='InterfaceIndex';Expression={$_.ifIndex}}
  if (Emit-AdapterLine $adapter) {
    exit 0
  }
} catch {
}

try {
  $adapter = Get-CimInstance -Namespace 'root/CIMV2' -ClassName Win32_NetworkAdapter -ErrorAction Stop |
    Where-Object {
      $_.NetConnectionID -eq $AdapterName -or
      $_.Name -eq $AdapterName -or
      ($_.NetConnectionID -and $_.NetConnectionID -like "*$AdapterName*") -or
      ($_.Name -and $_.Name -like "*$AdapterName*")
    } |
    Select-Object -First 1 InterfaceIndex
  if (Emit-AdapterLine $adapter) {
    exit 0
  }
} catch {
}

if (-not [string]::IsNullOrWhiteSpace($ObservedIp)) {
  try {
    $ipEntry = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ObservedIp -ErrorAction Stop |
      Select-Object -First 1 InterfaceIndex
    if (Emit-AdapterLine $ipEntry) {
      exit 0
    }
  } catch {
  }

  try {
    $ipEntry = Get-CimInstance -Namespace 'root/CIMV2' -ClassName Win32_NetworkAdapterConfiguration -ErrorAction Stop |
      Where-Object {
        $_.IPAddress -contains $ObservedIp
      } |
      Select-Object -First 1 InterfaceIndex
    if (Emit-AdapterLine $ipEntry) {
      exit 0
    }
  } catch {
  }
}

exit 1
''';
    adapterLookupScript = adapterLookupScript.replaceAll('__ADAPTER_NAME__', escapedAdapterName);

    for (int attempt = 0; attempt < 30; attempt += 1) {
      final String observedIp = (_windowsTunObservedIpv4 ?? '').replaceAll("'", "''");
      final String command = adapterLookupScript.replaceAll('__OBSERVED_IP__', observedIp);
      final ProcessResult result = await Process.run(
        _windowsPowerShellPath,
        <String>[
          '-NoProfile',
          '-Command',
          command,
        ],
        runInShell: false,
      );
      if (result.exitCode == 0) {
        final String payload = '${result.stdout}'
            .split(RegExp(r'\r?\n'))
            .map((String line) => line.trim())
            .firstWhere((String line) => line.isNotEmpty, orElse: () => '');
        final int? interfaceIndex = int.tryParse(payload);
        if (interfaceIndex != null) {
          return interfaceIndex;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }

    final String observedIpDetails = _windowsTunObservedIpv4 == null
        ? ' No TUN IPv4 address was observed from the Xray runtime logs.'
        : ' Observed TUN IPv4: ${_windowsTunObservedIpv4!}.';
    throw ProcessException(
      _windowsPowerShellPath,
      <String>[],
      'Timed out while waiting for the Windows TUN adapter "$adapterName" to appear.$observedIpDetails',
      1,
    );
  }

  Future<bool> _isWindowsAdministrator() async {
    if (!Platform.isWindows) {
      return true;
    }

    final ProcessResult result = await Process.run(
      _windowsPowerShellPath,
      <String>[
        '-NoProfile',
        '-Command',
        '[bool](([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))',
      ],
      runInShell: false,
    );
    return result.exitCode == 0 && '${result.stdout}'.trim().toLowerCase() == 'true';
  }

  Future<void> _runWindowsRoute(List<String> arguments) async {
    final ProcessResult result = await Process.run(_windowsRoutePath, arguments, runInShell: false);
    if (result.exitCode == 0) {
      return;
    }

    final String details = '${result.stdout}\n${result.stderr}'.trim();
    final String normalized = details.toLowerCase();
    if (normalized.contains('requires elevation') || normalized.contains('access is denied')) {
      throw ProcessException(
        _windowsRoutePath,
        arguments,
        'Windows TUN mode needs Administrator privileges so AlphaWet can install temporary routes.\n$details',
        result.exitCode,
      );
    }

    throw ProcessException(_windowsRoutePath, arguments, details, result.exitCode);
  }

  Future<void> _runWindowsRouteDelete(List<String> arguments) async {
    final ProcessResult result = await Process.run(_windowsRoutePath, arguments, runInShell: false);
    if (result.exitCode == 0) {
      return;
    }

    final String details = '${result.stdout}\n${result.stderr}'.trim().toLowerCase();
    if (details.contains('not found') ||
        details.contains('cannot find') ||
        details.contains('the route specified was not found')) {
      return;
    }

    _logger.warning(_tag, 'Failed to delete temporary Windows route: ${arguments.join(' ')}');
  }

  Future<void> _runWindowsTunDefaultRouteAddByName(String adapterName) async {
    ProcessException? lastError;
    for (int attempt = 0; attempt < 30; attempt += 1) {
      final ProcessResult result = await Process.run(
        'netsh',
        <String>[
          'interface',
          'ipv4',
          'add',
          'route',
          'prefix=0.0.0.0/0',
          'interface=$adapterName',
          'nexthop=0.0.0.0',
          'metric=1',
          'store=active',
        ],
        runInShell: false,
      );
      if (result.exitCode == 0) {
        return;
      }

      lastError = ProcessException(
        'netsh',
        <String>[
          'interface',
          'ipv4',
          'add',
          'route',
          'prefix=0.0.0.0/0',
          'interface=$adapterName',
          'nexthop=0.0.0.0',
          'metric=1',
          'store=active',
        ],
        '${result.stdout}\n${result.stderr}'.trim(),
        result.exitCode,
      );

      await Future<void>.delayed(const Duration(milliseconds: 350));
    }

    throw lastError ??
        ProcessException(
          'netsh',
          <String>[],
          'Failed to add the temporary Windows TUN default route for interface "$adapterName".',
          1,
        );
  }

  Future<void> _runWindowsTunDefaultRouteDeleteByName(String adapterName) async {
    final ProcessResult result = await Process.run(
      'netsh',
      <String>[
        'interface',
        'ipv4',
        'delete',
        'route',
        'prefix=0.0.0.0/0',
        'interface=$adapterName',
        'store=active',
      ],
      runInShell: false,
    );
    if (result.exitCode == 0) {
      return;
    }

    final String details = '${result.stdout}\n${result.stderr}'.toLowerCase();
    if (details.contains('not found') ||
        details.contains('no route was found') ||
        details.contains('the system cannot find the file specified') ||
        details.contains('element not found')) {
      return;
    }
  }

  Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) {
      await file.delete();
    }
  }
}

class _WindowsRouteCandidate {
  const _WindowsRouteCandidate({
    required this.interfaceIndex,
    required this.nextHop,
    required this.metric,
  });

  final int interfaceIndex;
  final String nextHop;
  final int metric;
}

class _WindowsRouteInfo {
  const _WindowsRouteInfo({
    required this.interfaceIndex,
    required this.nextHop,
  });

  final int interfaceIndex;
  final String nextHop;
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
