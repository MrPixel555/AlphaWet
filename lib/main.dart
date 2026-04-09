import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'models/aw_profile_models.dart';
import 'models/config_entry.dart';
import 'models/runtime_settings.dart';
import 'models/vpn_runtime_models.dart';
import 'runtime/platform_vpn_engine_factory.dart';
import 'runtime/runtime_bridge.dart';
import 'runtime/vpn_engine.dart';
import 'services/app_log_export_service.dart';
import 'services/config_store.dart';
import 'services/app_logger.dart';
import 'services/aw_import_exception.dart';
import 'services/aw_import_service.dart';
import 'services/aw_xray_builder_exception.dart';
import 'services/aw_xray_config_builder.dart';
import 'services/runtime_settings_store.dart';
import 'widgets/config_card.dart';

void main() {
  runApp(const AwManagerApp());
}

class AwManagerApp extends StatelessWidget {
  const AwManagerApp({super.key, this.disableStartupSideEffects = false});

  final bool disableStartupSideEffects;

  @override
  Widget build(BuildContext context) {
    final Color seed = const Color(0xFF3569F6);

    return MaterialApp(
      title: 'AlphaWet',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        scaffoldBackgroundColor: const Color(0xFFF6F8FC),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(disableStartupSideEffects: disableStartupSideEffects),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.disableStartupSideEffects = false});

  final bool disableStartupSideEffects;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final List<ConfigEntry> _configs = <ConfigEntry>[];
  final AppLogger _logger = AppLogger.instance;
  late final AwImportService _awImportService;
  late final AwXrayConfigBuilder _xrayConfigBuilder;
  late final AppLogExportService _logExportService;
  late final RuntimeSettingsStore _runtimeSettingsStore;
  late final VpnEngine _vpnEngine;
  late final ConfigStore _configStore;
  Timer? _runtimeWatchdog;
  bool _isRecoveringRuntime = false;
  bool _isImporting = false;
  bool _isExportingLogs = false;
  bool _isLoadingRuntimeSettings = true;
  bool _configsLoaded = false;
  bool _isRestoringRuntimeState = false;
  RuntimeSettings _runtimeSettings =
      Platform.isAndroid ? RuntimeSettings.defaults : const RuntimeSettings(mode: RuntimeMode.proxy);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _awImportService = AwImportService(logger: _logger);
    _xrayConfigBuilder = AwXrayConfigBuilder(logger: _logger);
    _logExportService = AppLogExportService(logger: _logger);
    _runtimeSettingsStore = RuntimeSettingsStore();
    _configStore = ConfigStore();
    _vpnEngine = createVpnEngine(logger: _logger);

    if (widget.disableStartupSideEffects) {
      _configsLoaded = true;
      _isLoadingRuntimeSettings = false;
      return;
    }

    _loadPersistedConfigs();
    _loadRuntimeSettings();
    _runtimeWatchdog = Timer.periodic(const Duration(seconds: 8), (_) => _pollRuntimeHealth());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _runtimeWatchdog?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_restoreRuntimeStateFromNative());
    }
  }

  Future<void> _loadRuntimeSettings() async {
    try {
      final RuntimeSettings loaded = await _runtimeSettingsStore.load();
      final bool permissionGranted = await RuntimeBridge.isVpnPermissionGranted();
      RuntimeSettings merged = loaded.copyWith(
        vpnPermissionGranted: permissionGranted || loaded.vpnPermissionGranted,
      );
      if (!Platform.isAndroid && merged.enableDeviceVpn) {
        merged = merged.copyWith(mode: RuntimeMode.proxy, vpnPermissionGranted: false);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _runtimeSettings = merged;
        _isLoadingRuntimeSettings = false;
      });
      if (_configs.isNotEmpty) {
        _rebuildAllConfigsForRuntimeSettings();
      }
      await _restoreRuntimeStateFromNative();
    } catch (error, stackTrace) {
      _logger.error('HomeScreen', 'Failed to load runtime settings.', error: error, stackTrace: stackTrace);
      if (!mounted) {
        return;
      }
      setState(() {
        _runtimeSettings = Platform.isAndroid
            ? RuntimeSettings.defaults
            : const RuntimeSettings(mode: RuntimeMode.proxy);
        _isLoadingRuntimeSettings = false;
      });
      await _restoreRuntimeStateFromNative();
    }
  }

  Future<void> _importConfig() async {
    if (_isImporting) {
      return;
    }

    setState(() {
      _isImporting = true;
    });

    try {
      _logger.info('HomeScreen', 'Opening file picker for .aw import.');
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['aw'],
        allowMultiple: false,
        withData: false,
      );

      if (!mounted) {
        return;
      }

      if (result == null || result.files.isEmpty) {
        _logger.info('HomeScreen', 'User closed picker without selecting a file.');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No file selected.')),
        );
        return;
      }

      final PlatformFile file = result.files.single;
      final String lowerName = file.name.toLowerCase();

      if (!lowerName.endsWith('.aw')) {
        _logger.warning('HomeScreen', 'Rejected non-.aw file: ${file.name}');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Only .aw files are allowed.')),
        );
        return;
      }

      if (file.path == null || file.path!.trim().isEmpty) {
        _logger.warning('HomeScreen', 'Picker returned a file without a local path.');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This platform did not expose a readable file path.')),
        );
        return;
      }

      final resultModel = await _awImportService.importFromPath(
        path: file.path!,
        fileName: file.name,
      );

      if (!mounted) {
        return;
      }

      final ConfigEntry entry = _buildEntryFromProfile(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        path: file.path!,
        importedAt: DateTime.now(),
        profile: resultModel.payload.profile,
        importStatus: resultModel.signatureVerified ? 'Verified' : 'Legacy',
        payloadKind: resultModel.payload.payloadKind,
        isSecureEnvelope: resultModel.payload.isSecureEnvelope,
      );

      setState(() {
        _configs.insert(0, entry);
      });
      await _persistConfigs();
      if (!mounted) {
        return;
      }

      final String message = entry.isXrayReady
          ? '${file.name} imported. ${_runtimeSettings.proxySummary} is now embedded into the generated Xray config.'
          : '${file.name} imported, but Xray JSON build failed.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } on AwImportException catch (error, stackTrace) {
      _logger.warning(
        'HomeScreen',
        'Import rejected: ${error.message}',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } catch (error, stackTrace) {
      _logger.error(
        'HomeScreen',
        'Unexpected import failure.',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Import failed unexpectedly. Check logs.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
        });
      }
    }
  }

  ConfigEntry _buildEntryFromProfile({
    required String id,
    required String path,
    required DateTime importedAt,
    required AwConnectionProfile profile,
    required String importStatus,
    required String payloadKind,
    required bool isSecureEnvelope,
  }) {
    String xrayBuildStatus = 'Ready';
    String? xrayConfigJson;
    String? xrayPrimaryOutboundTag;
    String? xrayBuildError;

    try {
      final xrayResult = _xrayConfigBuilder.build(
        profile,
        runtimeSettings: _runtimeSettings,
      );
      xrayConfigJson = xrayResult.prettyJson;
      xrayPrimaryOutboundTag = xrayResult.primaryOutboundTag;
    } on AwXrayBuilderException catch (error, stackTrace) {
      xrayBuildStatus = 'Build failed';
      xrayBuildError = error.message;
      _logger.warning(
        'HomeScreen',
        'Xray build rejected for ${profile.displayName}: ${error.message}',
        error: error,
        stackTrace: stackTrace,
      );
    } catch (error, stackTrace) {
      xrayBuildStatus = 'Build failed';
      xrayBuildError = 'Unexpected Xray build failure.';
      _logger.error(
        'HomeScreen',
        'Unexpected Xray build failure for ${profile.displayName}.',
        error: error,
        stackTrace: stackTrace,
      );
    }

    return ConfigEntry(
      id: id,
      name: profile.displayName,
      path: path,
      importedAt: importedAt,
      protocol: profile.protocol,
      host: profile.host,
      port: profile.port,
      importStatus: importStatus,
      profile: profile,
      security: profile.security,
      network: profile.network,
      flow: profile.flow,
      serverName: profile.serverName,
      shortId: profile.reality?.shortId,
      payloadKind: payloadKind,
      isSecureEnvelope: isSecureEnvelope,
      xrayBuildStatus: xrayBuildStatus,
      xrayConfigJson: xrayConfigJson,
      xrayPrimaryOutboundTag: xrayPrimaryOutboundTag,
      xrayBuildError: xrayBuildError,
      connectionState: xrayConfigJson != null ? VpnConnectionState.ready : VpnConnectionState.failed,
      engineMessage: xrayConfigJson != null
          ? 'Xray JSON built with ${_runtimeSettings.proxySummary}.'
          : (xrayBuildError ?? 'Xray build failed.'),
    );
  }

  Future<void> _loadPersistedConfigs() async {
    try {
      final List<PersistedConfigRecord> stored = await _configStore.load();
      if (!mounted) {
        return;
      }
      if (stored.isEmpty) {
        setState(() {
          _configsLoaded = true;
        });
        return;
      }
      final List<ConfigEntry> rebuilt = stored
          .where((PersistedConfigRecord item) => item.id.trim().isNotEmpty)
          .map(
            (PersistedConfigRecord item) => _buildEntryFromProfile(
              id: item.id,
              path: item.path,
              importedAt: item.importedAt,
              profile: item.profile,
              importStatus: item.importStatus,
              payloadKind: item.payloadKind,
              isSecureEnvelope: item.isSecureEnvelope,
            ),
          )
          .toList(growable: false);
      setState(() {
        _configs
          ..clear()
          ..addAll(rebuilt);
        _configsLoaded = true;
      });
      await _restoreRuntimeStateFromNative();
    } catch (error, stackTrace) {
      _logger.error('HomeScreen', 'Failed to restore saved configs.', error: error, stackTrace: stackTrace);
    }
  }

  Future<void> _restoreRuntimeStateFromNative() async {
    if (!mounted || _isRestoringRuntimeState || !_configsLoaded) {
      return;
    }
    _isRestoringRuntimeState = true;
    try {
      final Map<Object?, Object?>? status = await RuntimeBridge.getCoreStatus();
      final String state = (status?['state'] as String? ?? 'idle').trim().toLowerCase();
      final bool running = state == 'running' && status?['success'] == true;
      final String? activeConfigId = (status?['configId'] as String?)?.trim();
      final String? sessionId = (status?['sessionId'] as String?)?.trim();
      final String message = (status?['message'] as String? ?? '').trim();
      final bool deviceVpnMode = status?['deviceVpnMode'] == true;

      if (!mounted) {
        return;
      }

      bool configsChanged = false;
      final List<ConfigEntry> updated = <ConfigEntry>[];
      for (final ConfigEntry item in _configs) {
        final bool isActive = running && activeConfigId != null && item.id == activeConfigId;
        final ConfigEntry next = item.copyWith(
          isEnabled: isActive,
          connectionState: isActive
              ? VpnConnectionState.connected
              : (item.isXrayReady ? VpnConnectionState.ready : VpnConnectionState.failed),
          engineSessionId: isActive ? sessionId : null,
          engineMessage: isActive
              ? (message.isNotEmpty
                  ? message
                  : (deviceVpnMode
                      ? 'AlphaWet VPN session is already active.'
                      : 'AlphaWet proxy session is already active.'))
              : (item.isXrayReady
                  ? 'Xray JSON built with ${_runtimeSettings.proxySummary}.'
                  : (item.xrayBuildError ?? 'Xray build failed.')),
          lastConnectedAt: isActive ? (item.lastConnectedAt ?? DateTime.now()) : item.lastConnectedAt,
        );
        if (next.isEnabled != item.isEnabled ||
            next.connectionState != item.connectionState ||
            next.engineSessionId != item.engineSessionId ||
            next.engineMessage != item.engineMessage ||
            next.lastConnectedAt != item.lastConnectedAt) {
          configsChanged = true;
        }
        updated.add(next);
      }

      final bool settingsChanged = running && _runtimeSettings.enableDeviceVpn != deviceVpnMode;
      final RuntimeSettings resolvedSettings = settingsChanged
          ? _runtimeSettings.copyWith(mode: deviceVpnMode ? RuntimeMode.vpn : RuntimeMode.proxy)
          : _runtimeSettings;

      if (!configsChanged && !settingsChanged) {
        return;
      }

      setState(() {
        _configs
          ..clear()
          ..addAll(updated);
        _runtimeSettings = resolvedSettings;
      });
      if (configsChanged) {
        await _persistConfigs();
      }
      if (settingsChanged) {
        await _runtimeSettingsStore.save(resolvedSettings);
      }
    } catch (error, stackTrace) {
      _logger.warning(
        'HomeScreen',
        'Failed to synchronize runtime state from native bridge.',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _isRestoringRuntimeState = false;
    }
  }

  Future<void> _persistConfigs() async {
    final List<PersistedConfigRecord> payload = _configs
        .map(
          (ConfigEntry item) => PersistedConfigRecord(
            id: item.id,
            path: item.path,
            importedAt: item.importedAt,
            profile: item.profile,
            importStatus: item.importStatus,
            payloadKind: item.payloadKind,
            isSecureEnvelope: item.isSecureEnvelope,
          ),
        )
        .toList(growable: false);
    await _configStore.save(payload);
  }

  Future<void> _pollRuntimeHealth() async {
    if (!mounted || _isRecoveringRuntime) {
      return;
    }
    ConfigEntry? active;
    for (final ConfigEntry item in _configs) {
      if (item.isEnabled) {
        active = item;
        break;
      }
    }
    if (active == null) {
      await _restoreRuntimeStateFromNative();
      return;
    }
    if (active.isBusy) {
      return;
    }
    final Map<Object?, Object?>? status = await RuntimeBridge.getCoreStatus();
    final String state = (status?['state'] as String? ?? 'idle').trim().toLowerCase();
    if (state == 'running') {
      return;
    }
    _isRecoveringRuntime = true;
    try {
      _logger.warning('HomeScreen', 'Runtime dropped unexpectedly. Attempting automatic recovery.');
      final ConfigEntry latest = _findEntryById(active.id) ?? active;
      _setEntry(
        active.id,
        latest.copyWith(
          isEnabled: false,
          connectionState: VpnConnectionState.failed,
          engineSessionId: null,
          engineMessage: 'Connection dropped. AlphaWet is reconnecting automatically...',
        ),
      );
      await _toggleConfig(active.id, true);
    } finally {
      _isRecoveringRuntime = false;
    }
  }

  Future<void> _disconnectOtherConfigs(String currentId) async {
    final List<ConfigEntry> others = _configs
        .where((ConfigEntry item) => item.id != currentId && item.isEnabled)
        .toList(growable: false);
    for (final ConfigEntry other in others) {
      _setEntry(
        other.id,
        other.copyWith(
          connectionState: VpnConnectionState.disconnecting,
          engineMessage: 'Stopping previous connection...',
        ),
      );
      final VpnEngineResult result = await _vpnEngine.disconnect(other);
      final ConfigEntry latest = _findEntryById(other.id) ?? other;
      _setEntry(
        other.id,
        latest.copyWith(
          isEnabled: false,
          connectionState: result.state,
          engineMessage: result.message,
          engineSessionId: null,
        ),
      );
    }
  }

  Future<void> _deleteConfig(String id) async {
    final ConfigEntry? entry = _findEntryById(id);
    if (entry == null) {
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Delete config?'),
          content: Text('Remove "${entry.name}" from AlphaWet?'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) {
      return;
    }
    if (entry.isEnabled) {
      await _toggleConfig(id, false);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _configs.removeWhere((ConfigEntry item) => item.id == id);
    });
    await _persistConfigs();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${entry.name} was deleted.')),
    );
  }

  void _rebuildAllConfigsForRuntimeSettings() {
    setState(() {
      for (int index = 0; index < _configs.length; index += 1) {
        final ConfigEntry current = _configs[index];
        final ConfigEntry rebuilt = _buildEntryFromProfile(
          id: current.id,
          path: current.path,
          importedAt: current.importedAt,
          profile: current.profile,
          importStatus: current.importStatus,
          payloadKind: current.payloadKind,
          isSecureEnvelope: current.isSecureEnvelope,
        );
        _configs[index] = rebuilt.copyWith(
          pingLabel: current.pingLabel,
          isPinging: false,
          isEnabled: false,
          connectionState: rebuilt.isXrayReady ? VpnConnectionState.ready : VpnConnectionState.failed,
          engineSessionId: null,
          engineMessage: rebuilt.isXrayReady
              ? 'Runtime settings changed. Rebuilt with ${_runtimeSettings.proxySummary}.'
              : rebuilt.xrayBuildError,
        );
      }
    });
  }

  Future<void> _openRuntimeSettings() async {
    final RuntimeSettings? updated = await showModalBottomSheet<RuntimeSettings>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext context) {
        return _RuntimeSettingsSheet(initialSettings: _runtimeSettings);
      },
    );

    if (updated == null) {
      return;
    }

    RuntimeSettings nextSettings = updated;
    if (!Platform.isAndroid) {
      nextSettings = nextSettings.copyWith(mode: RuntimeMode.proxy, vpnPermissionGranted: false);
    } else if (nextSettings.enableDeviceVpn) {
      final bool granted = await RuntimeBridge.ensureVpnPermission();
      nextSettings = nextSettings.copyWith(
        mode: granted ? RuntimeMode.vpn : RuntimeMode.proxy,
        vpnPermissionGranted: granted,
      );
      if (!granted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Android VPN permission was not granted. AlphaWet stayed in Proxy mode.'),
          ),
        );
      }
    } else {
      nextSettings = nextSettings.copyWith(vpnPermissionGranted: false, mode: RuntimeMode.proxy);
    }

    await _runtimeSettingsStore.save(nextSettings);
    if (!mounted) {
      return;
    }

    setState(() {
      _runtimeSettings = nextSettings;
    });
    _rebuildAllConfigsForRuntimeSettings();

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          nextSettings.enableDeviceVpn
              ? 'Settings saved. Mode is VPN.'
              : 'Settings saved. ${nextSettings.proxySummary}',
        ),
      ),
    );
  }

  Future<List<int>> _findBusyProxyPorts(RuntimeSettings settings) async {
    if (settings.enableDeviceVpn) {
      return <int>[];
    }
    return RuntimeBridge.findOccupiedLocalPorts(
      <int>[settings.httpPort, settings.socksPort],
    );
  }

  Future<void> _toggleConfig(String id, bool value) async {
    final ConfigEntry? current = _findEntryById(id);
    if (current == null || current.isBusy) {
      return;
    }

    if (!value) {
      _setEntry(
        id,
        current.copyWith(
          connectionState: VpnConnectionState.disconnecting,
          engineMessage: 'Stopping Xray core...',
        ),
      );
      final VpnEngineResult result = await _vpnEngine.disconnect(current);
      final ConfigEntry latest = _findEntryById(id) ?? current;
      _setEntry(
        id,
        latest.copyWith(
          isEnabled: false,
          connectionState: result.state,
          engineMessage: result.message,
          engineSessionId: null,
        ),
      );
      await _persistConfigs();
      return;
    }

    if (_runtimeSettings.enableDeviceVpn && !_runtimeSettings.vpnPermissionGranted) {
      final bool granted = await RuntimeBridge.ensureVpnPermission();
      if (!mounted) {
        return;
      }
      if (!granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Android VPN permission is required for VPN mode.')),
        );
        return;
      }
      final RuntimeSettings updatedSettings = _runtimeSettings.copyWith(
        mode: RuntimeMode.vpn,
        vpnPermissionGranted: true,
      );
      await _runtimeSettingsStore.save(updatedSettings);
      if (!mounted) {
        return;
      }
      setState(() {
        _runtimeSettings = updatedSettings;
      });
      _rebuildAllConfigsForRuntimeSettings();
    }

    await _disconnectOtherConfigs(id);

    final List<int> busyPorts = await _findBusyProxyPorts(_runtimeSettings);
    if (busyPorts.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'AlphaWet could not start because these local ports are busy: ${busyPorts.join(', ')}',
            ),
          ),
        );
      }
      final ConfigEntry latest = _findEntryById(id) ?? current;
      _setEntry(
        id,
        latest.copyWith(
          isEnabled: false,
          connectionState: VpnConnectionState.failed,
          engineMessage: 'Busy local ports: ${busyPorts.join(', ')}',
          engineSessionId: null,
        ),
      );
      return;
    }

    final ConfigEntry? refreshedCurrent = _findEntryById(id);
    if (refreshedCurrent == null) {
      return;
    }

    _setEntry(
      id,
      refreshedCurrent.copyWith(
        connectionState: VpnConnectionState.validating,
        engineMessage: _runtimeSettings.enableDeviceVpn
            ? 'Validating generated Xray config for VPN mode...'
            : 'Validating generated Xray config for Proxy mode...',
      ),
    );
    final ConfigEntry validateTarget = _findEntryById(id) ?? current;
    final VpnEngineResult validateResult = await _vpnEngine.validate(validateTarget, _runtimeSettings);
    final ConfigEntry afterValidate = _findEntryById(id) ?? current;
    _setEntry(
      id,
      afterValidate.copyWith(
        connectionState: validateResult.state,
        engineMessage: validateResult.message,
        lastValidatedAt: DateTime.now(),
      ),
    );

    if (!validateResult.success) {
      return;
    }

    final ConfigEntry readyToConnect = _findEntryById(id) ?? current;
    _setEntry(
      id,
      readyToConnect.copyWith(
        isEnabled: true,
        connectionState: VpnConnectionState.connecting,
        engineMessage: _runtimeSettings.enableDeviceVpn
            ? 'Starting AlphaWet in VPN mode...'
            : 'Starting AlphaWet in Proxy mode...',
        lastValidatedAt: DateTime.now(),
      ),
    );
    final ConfigEntry connectTarget = _findEntryById(id) ?? readyToConnect;
    final VpnEngineResult connectResult = await _vpnEngine.connect(connectTarget, _runtimeSettings);
    final ConfigEntry afterConnect = _findEntryById(id) ?? readyToConnect;
    _setEntry(
      id,
      afterConnect.copyWith(
        isEnabled: connectResult.success,
        connectionState: connectResult.state,
        engineMessage: connectResult.message,
        engineSessionId: connectResult.sessionId,
        lastValidatedAt: DateTime.now(),
        lastConnectedAt: connectResult.success ? DateTime.now() : afterConnect.lastConnectedAt,
      ),
    );
    await _persistConfigs();
  }

  ConfigEntry? _findEntryById(String id) {
    final int index = _configs.indexWhere((ConfigEntry item) => item.id == id);
    if (index == -1) {
      return null;
    }
    return _configs[index];
  }

  void _setEntry(String id, ConfigEntry updated) {
    if (!mounted) {
      return;
    }
    setState(() {
      final int idx = _configs.indexWhere((ConfigEntry item) => item.id == id);
      if (idx != -1) {
        _configs[idx] = updated;
      }
    });
  }

  Future<void> _pingConfig(String id) async {
    final int index = _configs.indexWhere((ConfigEntry item) => item.id == id);
    if (index == -1) {
      return;
    }

    final ConfigEntry current = _configs[index];
    setState(() {
      _configs[index] = current.copyWith(
        isPinging: true,
        pingLabel: 'Pinging...',
      );
    });

    try {
      final Map<Object?, Object?>? result = await RuntimeBridge.pingProxy(
        httpPort: _runtimeSettings.httpPort,
        socksPort: _runtimeSettings.socksPort,
        configId: current.id,
        displayName: current.name,
        configJson: current.xrayConfigJson,
      );
      if (!mounted) {
        return;
      }
      final int refreshedIndex = _configs.indexWhere((ConfigEntry item) => item.id == id);
      if (refreshedIndex == -1) {
        return;
      }

      final bool success = result?['success'] == true;
      final int? latencyMs = result?['latencyMs'] as int?;
      final String message = (result?['message'] as String? ?? 'Ping failed.').trim();

      setState(() {
        _configs[refreshedIndex] = _configs[refreshedIndex].copyWith(
          isPinging: false,
          pingLabel: success && latencyMs != null ? '$latencyMs ms' : 'Ping failed',
        );
      });

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } catch (error, stackTrace) {
      _logger.error('HomeScreen', 'Runtime ping failed.', error: error, stackTrace: stackTrace);
      if (!mounted) {
        return;
      }
      final int refreshedIndex = _configs.indexWhere((ConfigEntry item) => item.id == id);
      if (refreshedIndex == -1) {
        return;
      }
      setState(() {
        _configs[refreshedIndex] = _configs[refreshedIndex].copyWith(
          isPinging: false,
          pingLabel: 'Ping failed',
        );
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ping failed. Check the runtime log for details.')),
      );
    }
  }

  Future<void> _exportLogs() async {
    if (_isExportingLogs) {
      return;
    }
    setState(() {
      _isExportingLogs = true;
    });
    try {
      final file = await _logExportService.exportLogs();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Logs exported to: ${file.path}')),
      );
    } catch (error, stackTrace) {
      _logger.error('HomeScreen', 'Failed to export logs.', error: error, stackTrace: stackTrace);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to export logs.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isExportingLogs = false;
        });
      }
    }
  }

  void _previewLogs() {
    _showTextSheet(
      title: 'Application logs',
      subtitle: 'Newest records are shown last.',
      content: _logger.dumpAsText(),
    );
  }

  void _showTextSheet({
    required String title,
    required String subtitle,
    required String content,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.86,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          builder: (BuildContext context, ScrollController scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Center(
                      child: Container(
                        width: 44,
                        height: 5,
                        decoration: BoxDecoration(
                          color: colors.outlineVariant,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: colors.outlineVariant),
                        ),
                        child: SingleChildScrollView(
                          controller: scrollController,
                          child: SelectableText(
                            content,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontFamily: 'monospace',
                              height: 1.45,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AlphaWet'),
        centerTitle: false,
        actions: <Widget>[
          IconButton(
            tooltip: 'Import config',
            onPressed: _isImporting ? null : _importConfig,
            icon: const Icon(Icons.add_link_rounded),
          ),
          IconButton(
            tooltip: 'Runtime settings',
            onPressed: _isLoadingRuntimeSettings ? null : _openRuntimeSettings,
            icon: const Icon(Icons.tune_rounded),
          ),
          IconButton(
            tooltip: 'Preview logs',
            onPressed: _previewLogs,
            icon: const Icon(Icons.article_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: BottomAppBar(
        height: 108,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _previewLogs,
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: const Text('Preview Logs'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isExportingLogs ? null : _exportLogs,
                    icon: _isExportingLogs
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_alt_rounded),
                    label: Text(_isExportingLogs ? 'Exporting...' : 'Export Logs'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('made by AlphaCraft', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
      body: SafeArea(
        child: CustomScrollView(
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: colors.outlineVariant),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            blurRadius: 20,
                            offset: const Offset(0, 8),
                            color: colors.shadow.withValues(alpha: 0.06),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: colors.primaryContainer,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Icon(
                                    Icons.settings_ethernet_rounded,
                                    color: colors.onPrimaryContainer,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        'Runtime diagnostics',
                                        style: theme.textTheme.titleLarge?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _isLoadingRuntimeSettings
                                            ? 'Loading runtime settings...'
                                            : _runtimeSettings.enableDeviceVpn
                                            ? 'Current mode: VPN'
                                            : 'Current listener profile: ${_runtimeSettings.proxySummary}',
                                        style: theme.textTheme.bodyMedium?.copyWith(
                                          color: colors.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: <Widget>[
                                _MetricChip(
                                  icon: Icons.inventory_2_outlined,
                                  label: 'Imported',
                                  value: '${_configs.length}',
                                ),
                                _MetricChip(
                                  icon: Icons.http_rounded,
                                  label: 'HTTP',
                                  value: '${_runtimeSettings.httpPort}',
                                ),
                                _MetricChip(
                                  icon: Icons.route_rounded,
                                  label: 'SOCKS',
                                  value: '${_runtimeSettings.socksPort}',
                                ),
                                _MetricChip(
                                  icon: Icons.vpn_lock_outlined,
                                  label: 'Tunnel',
                                  value: _runtimeSettings.modeLabel,
                                ),
                              ],
                            ),
                            if (_runtimeSettings.enableDeviceVpn) ...<Widget>[
                              const SizedBox(height: 16),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: colors.secondaryContainer.withValues(alpha: 0.55),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  _runtimeSettings.enableDeviceVpn
                                      ? 'VPN mode is active. AlphaWet requests an Android VPN session and also keeps the local HTTP and SOCKS listeners available for diagnostics such as Google real-delay ping.'
                                      : 'Proxy mode is active. AlphaWet keeps the local HTTP and SOCKS listeners on the ports shown above.',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: colors.onSecondaryContainer,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 18),
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: <Widget>[
                                FilledButton.icon(
                                  onPressed: _isImporting ? null : _importConfig,
                                  icon: _isImporting
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(strokeWidth: 2),
                                        )
                                      : const Icon(Icons.upload_file_rounded),
                                  label: Text(
                                    _isImporting ? 'Opening picker...' : 'Import Config',
                                  ),
                                ),
                                FilledButton.tonalIcon(
                                  onPressed: _isLoadingRuntimeSettings ? null : _openRuntimeSettings,
                                  icon: const Icon(Icons.tune_rounded),
                                  label: const Text('Runtime Settings'),
                                ),
                                FilledButton.tonalIcon(
                                  onPressed: _previewLogs,
                                  icon: const Icon(Icons.article_outlined),
                                  label: const Text('Preview Logs'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Imported configs',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Imported configs stay saved on this device. AlphaWet rebuilds each one with the current Mode and port profile before starting it.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_configs.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: colors.primaryContainer,
                            borderRadius: BorderRadius.circular(28),
                          ),
                          child: Icon(
                            Icons.folder_open_rounded,
                            size: 44,
                            color: colors.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'No configs imported yet',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Import a .aw file to validate it, build the runtime config, and connect with AlphaWet.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (BuildContext context, int index) {
                      if (index.isOdd) {
                        return const SizedBox(height: 14);
                      }
                      final ConfigEntry entry = _configs[index ~/ 2];
                      return ConfigCard(
                        entry: entry,
                        runtimeSettings: _runtimeSettings,
                        onToggle: (bool value) => _toggleConfig(entry.id, value),
                        onPing: () => _pingConfig(entry.id),
                        onDelete: () => _deleteConfig(entry.id),
                      );
                    },
                    childCount: _configs.isEmpty ? 0 : (_configs.length * 2) - 1,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 18, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            '$label: $value',
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _RuntimeSettingsSheet extends StatefulWidget {
  const _RuntimeSettingsSheet({required this.initialSettings});

  final RuntimeSettings initialSettings;

  @override
  State<_RuntimeSettingsSheet> createState() => _RuntimeSettingsSheetState();
}

class _RuntimeSettingsSheetState extends State<_RuntimeSettingsSheet> {
  late final TextEditingController _httpController;
  late final TextEditingController _socksController;
  late RuntimeMode _mode;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _httpController = TextEditingController(text: '${widget.initialSettings.httpPort}');
    _socksController = TextEditingController(text: '${widget.initialSettings.socksPort}');
    _mode = widget.initialSettings.mode;
  }

  @override
  void dispose() {
    _httpController.dispose();
    _socksController.dispose();
    super.dispose();
  }

  void _submit() {
    final int? httpPort = int.tryParse(_httpController.text.trim());
    final int? socksPort = int.tryParse(_socksController.text.trim());
    if (httpPort == null || socksPort == null) {
      setState(() {
        _errorText = 'HTTP and SOCKS ports must be valid integers.';
      });
      return;
    }

    final RuntimeSettings next = widget.initialSettings.copyWith(
      httpPort: httpPort,
      socksPort: socksPort,
      mode: _mode,
      vpnPermissionGranted: _mode == RuntimeMode.vpn
          ? widget.initialSettings.vpnPermissionGranted
          : false,
    );
    final String? validationError = next.validate();
    if (validationError != null) {
      setState(() {
        _errorText = validationError;
      });
      return;
    }

    Navigator.of(context).pop(next);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final EdgeInsets viewInsets = MediaQuery.of(context).viewInsets;
    final bool proxyMode = _mode == RuntimeMode.proxy;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Center(
            child: Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: colors.outlineVariant,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'Settings',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            Platform.isAndroid
                ? 'Choose exactly one mode. VPN is the default. Proxy mode unlocks the local HTTP and SOCKS ports below.'
                : 'Desktop builds keep the same UI, but the runtime works in Proxy mode only. HTTP and SOCKS ports stay configurable below.',
            style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Mode',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 10),
                if (Platform.isAndroid)
                  SegmentedButton<RuntimeMode>(
                    segments: const <ButtonSegment<RuntimeMode>>[
                    ButtonSegment<RuntimeMode>(
                      value: RuntimeMode.vpn,
                      label: Text('VPN'),
                      icon: Icon(Icons.vpn_lock_rounded),
                    ),
                    ButtonSegment<RuntimeMode>(
                      value: RuntimeMode.proxy,
                      label: Text('Proxy'),
                      icon: Icon(Icons.lan_rounded),
                    ),
                  ],
                  selected: <RuntimeMode>{_mode},
                  showSelectedIcon: false,
                  onSelectionChanged: (Set<RuntimeMode> selection) {
                    setState(() {
                      _mode = selection.first;
                    });
                  },
                ),
                const SizedBox(height: 10),
                Text(
                  Platform.isAndroid
                      ? (proxyMode
                          ? 'Proxy mode starts the local listeners and uses the ports below.'
                          : 'VPN mode starts the Android VPN tunnel and still keeps the local listeners available for diagnostics and status checks.')
                      : 'Desktop builds use the local Xray proxy runtime. VPN mode remains available on Android builds only.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          IgnorePointer(
            ignoring: !proxyMode,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              opacity: proxyMode ? 1 : 0.45,
              child: Column(
                children: <Widget>[
                  TextField(
                    controller: _httpController,
                    enabled: proxyMode,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'HTTP proxy port',
                      hintText: '10808',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _socksController,
                    enabled: proxyMode,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'SOCKS proxy port',
                      hintText: '10809',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_errorText != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              _errorText!,
              style: theme.textTheme.bodyMedium?.copyWith(color: colors.error),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _submit,
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
