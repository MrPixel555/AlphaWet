import 'dart:async';

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
import 'services/app_logger.dart';
import 'services/aw_import_exception.dart';
import 'services/aw_import_service.dart';
import 'services/aw_xray_builder_exception.dart';
import 'services/aw_xray_config_builder.dart';
import 'services/config_entries_store.dart';
import 'services/runtime_settings_store.dart';
import 'widgets/config_card.dart';

void main() {
  runApp(const AlphaWetApp());
}

class AlphaWetApp extends StatelessWidget {
  const AlphaWetApp({super.key});

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
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<ConfigEntry> _configs = <ConfigEntry>[];
  final AppLogger _logger = AppLogger.instance;
  late final AwImportService _awImportService;
  late final AwXrayConfigBuilder _xrayConfigBuilder;
  late final AppLogExportService _logExportService;
  late final RuntimeSettingsStore _runtimeSettingsStore;
  late final ConfigEntriesStore _configEntriesStore;
  late final VpnEngine _vpnEngine;
  Timer? _runtimeStatusTimer;
  bool _isImporting = false;
  bool _isExportingLogs = false;
  bool _isLoadingRuntimeSettings = true;
  RuntimeSettings _runtimeSettings = RuntimeSettings.defaults;

  @override
  void initState() {
    super.initState();
    _awImportService = AwImportService(logger: _logger);
    _xrayConfigBuilder = AwXrayConfigBuilder(logger: _logger);
    _logExportService = AppLogExportService(logger: _logger);
    _runtimeSettingsStore = RuntimeSettingsStore();
    _configEntriesStore = ConfigEntriesStore();
    _vpnEngine = createVpnEngine(logger: _logger);
    _loadRuntimeSettings();
    _runtimeStatusTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _pollRuntimeStatus(),
    );
  }

  @override
  void dispose() {
    _runtimeStatusTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadRuntimeSettings() async {
    try {
      final RuntimeSettings loaded = await _runtimeSettingsStore.load();
      final bool permissionGranted = await RuntimeBridge.isVpnPermissionGranted();
      final RuntimeSettings merged = loaded.copyWith(
        vpnPermissionGranted: permissionGranted || loaded.vpnPermissionGranted,
      );
      final List<StoredConfigEntry> storedConfigs = await _configEntriesStore.load();
      final List<ConfigEntry> restored = storedConfigs
          .map((StoredConfigEntry item) => _buildEntryFromProfile(
                id: item.id,
                path: item.path,
                importedAt: item.importedAt,
                profile: item.profile,
                importStatus: item.importStatus,
                payloadKind: item.payloadKind,
                isSecureEnvelope: item.isSecureEnvelope,
              ))
          .toList(growable: false);
      if (!mounted) {
        return;
      }
      setState(() {
        _runtimeSettings = merged;
        _configs
          ..clear()
          ..addAll(restored);
        _isLoadingRuntimeSettings = false;
      });
      await _pollRuntimeStatus();
    } catch (error, stackTrace) {
      _logger.error('HomeScreen', 'Failed to load runtime settings.', error: error, stackTrace: stackTrace);
      if (!mounted) {
        return;
      }
      setState(() {
        _runtimeSettings = RuntimeSettings.defaults;
        _configs.clear();
        _isLoadingRuntimeSettings = false;
      });
    }
  }

  Future<void> _persistConfigs() async {
    try {
      await _configEntriesStore.save(_configs);
    } catch (error, stackTrace) {
      _logger.error('HomeScreen', 'Failed to persist imported configs.', error: error, stackTrace: stackTrace);
    }
  }

  Future<void> _pollRuntimeStatus() async {
    if (!mounted || _configs.isEmpty) {
      return;
    }

    final Map<Object?, Object?>? status = await RuntimeBridge.getCoreStatus();
    if (!mounted || status == null) {
      return;
    }

    final bool running = status['state']?.toString().trim().toLowerCase() == 'running';
    final String? activeConfigId = status['configId']?.toString();
    final String? sessionId = status['sessionId']?.toString();
    final String message = (status['message'] as String? ?? '').trim();

    setState(() {
      for (int index = 0; index < _configs.length; index += 1) {
        final ConfigEntry item = _configs[index];
        final bool shouldBeActive = running && activeConfigId != null && item.id == activeConfigId;
        if (shouldBeActive) {
          _configs[index] = item.copyWith(
            isEnabled: true,
            connectionState: VpnConnectionState.connected,
            engineSessionId: sessionId,
            engineMessage: message.isEmpty ? item.engineMessage : message,
          );
        } else if (item.isEnabled && !item.isBusy) {
          _configs[index] = item.copyWith(
            isEnabled: false,
            connectionState: item.isXrayReady ? VpnConnectionState.ready : VpnConnectionState.failed,
            engineSessionId: null,
            engineMessage: running
                ? 'Another profile is now active.'
                : (message.isEmpty ? 'Runtime stopped.' : message),
          );
        }
      }
    });
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
          ? 'Runtime prepared with ${_runtimeSettings.proxySummary}.'
          : (xrayBuildError ?? 'Xray build failed.'),
    );
  }

  Future<void> _rebuildAllConfigsForRuntimeSettings() async {
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
              ? 'Runtime settings changed. Profiles were rebuilt with ${_runtimeSettings.proxySummary}.'
              : rebuilt.xrayBuildError,
        );
      }
    });
    await _persistConfigs();
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
    if (nextSettings.enableDeviceVpn) {
      final bool granted = await RuntimeBridge.ensureVpnPermission();
      nextSettings = nextSettings.copyWith(vpnPermissionGranted: granted, enableDeviceVpn: granted);
      if (!granted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Android VPN permission was not granted. Full-device mode remains off.'),
          ),
        );
      }
    } else {
      nextSettings = nextSettings.copyWith(vpnPermissionGranted: false);
    }

    await _disconnectOthersExcept('__runtime_settings__');
    await _runtimeSettingsStore.save(nextSettings);
    if (!mounted) {
      return;
    }

    setState(() {
      _runtimeSettings = nextSettings;
    });
    await _rebuildAllConfigsForRuntimeSettings();

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          nextSettings.enableDeviceVpn
              ? 'Runtime settings saved. Full-device tunneling is enabled.'
              : 'Runtime settings saved. ${nextSettings.proxySummary}',
        ),
      ),
    );
  }

  Future<void> _toggleConfig(String id, bool value) async {
    final ConfigEntry? current = _findEntryById(id);
    if (current == null || current.isBusy) {
      return;
    }

    if (!value) {
      await _disconnectEntry(id, current);
      return;
    }

    await _disconnectOthersExcept(id);

    final ConfigEntry? refreshedCurrent = _findEntryById(id);
    if (refreshedCurrent == null || refreshedCurrent.isBusy) {
      return;
    }

    _setEntry(
      id,
      refreshedCurrent.copyWith(
        connectionState: VpnConnectionState.validating,
        engineMessage: 'Validating generated runtime...',
      ),
    );
    final ConfigEntry validateTarget = _findEntryById(id) ?? refreshedCurrent;
    final VpnEngineResult validateResult = await _vpnEngine.validate(validateTarget, _runtimeSettings);
    final ConfigEntry afterValidate = _findEntryById(id) ?? refreshedCurrent;
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

    final ConfigEntry readyToConnect = _findEntryById(id) ?? refreshedCurrent;
    _setEntry(
      id,
      readyToConnect.copyWith(
        isEnabled: true,
        connectionState: VpnConnectionState.connecting,
        engineMessage: 'Starting runtime...',
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
  }

  Future<void> _disconnectOthersExcept(String id) async {
    final List<ConfigEntry> activeEntries = _configs
        .where((ConfigEntry item) => item.id != id && (item.isEnabled || item.connectionState == VpnConnectionState.connected))
        .toList(growable: false);
    for (final ConfigEntry entry in activeEntries) {
      await _disconnectEntry(entry.id, entry, replacementMessage: 'Stopped because another profile was activated.');
    }
  }

  Future<void> _disconnectEntry(
    String id,
    ConfigEntry current, {
    String? replacementMessage,
  }) async {
    _setEntry(
      id,
      current.copyWith(
        connectionState: VpnConnectionState.disconnecting,
        engineMessage: 'Stopping runtime...',
      ),
    );
    final VpnEngineResult result = await _vpnEngine.disconnect(current);
    final ConfigEntry latest = _findEntryById(id) ?? current;
    _setEntry(
      id,
      latest.copyWith(
        isEnabled: false,
        connectionState: result.state,
        engineMessage: replacementMessage ?? result.message,
        engineSessionId: null,
      ),
    );
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
        targetHost: current.host,
        targetPort: current.port,
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
        height: 112,
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
                    label: Text(_isExportingLogs ? 'Exporting...' : 'Export Log'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'made by AlphaCraft',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontSize: 11,
                  ),
            ),
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
                                        'AlphaWet',
                                        style: theme.textTheme.titleLarge?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _isLoadingRuntimeSettings
                                            ? 'Loading runtime settings...'
                                            : 'Current runtime profile: ${_runtimeSettings.proxySummary}',
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
                                  label: 'Full device',
                                  value: _runtimeSettings.enableDeviceVpn ? 'On' : 'Off',
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
                                  'Full-device mode routes the whole device through the active profile while keeping the local HTTP and SOCKS listeners available for checks and diagnostics.',
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
                      'Profiles',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Profiles are rebuilt with your current ports and saved locally, so they stay available after the app is closed and opened again.',
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
                          'Import a .aw file to save it locally, build the runtime, and connect it whenever you want.',
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
  late bool _enableDeviceVpn;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _httpController = TextEditingController(text: '${widget.initialSettings.httpPort}');
    _socksController = TextEditingController(text: '${widget.initialSettings.socksPort}');
    _enableDeviceVpn = widget.initialSettings.enableDeviceVpn;
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
      enableDeviceVpn: _enableDeviceVpn,
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
            'Connection settings',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            'Saved settings are restored automatically when AlphaWet opens again.',
            style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _httpController,
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
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'SOCKS proxy port',
              hintText: '10809',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Tunnel the whole device'),
            subtitle: const Text(
              'When enabled, AlphaWet starts an Android VPN service and routes device traffic through the active profile.',
            ),
            value: _enableDeviceVpn,
            onChanged: (bool value) {
              setState(() {
                _enableDeviceVpn = value;
              });
            },
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
