import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'models/config_entry.dart';
import 'widgets/config_card.dart';

void main() {
  runApp(const AwManagerApp());
}

class AwManagerApp extends StatelessWidget {
  const AwManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final seed = const Color(0xFF3569F6);

    return MaterialApp(
      title: 'AW Manager UI',
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
  final Random _random = Random();
  bool _isImporting = false;

  Future<void> _importConfig() async {
    if (_isImporting) {
      return;
    }

    setState(() {
      _isImporting = true;
    });

    try {
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No file selected.')),
        );
        return;
      }

      final PlatformFile file = result.files.single;
      final String lowerName = file.name.toLowerCase();

      if (!lowerName.endsWith('.aw')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Only .aw files are allowed.')),
        );
        return;
      }

      final ConfigEntry entry = ConfigEntry(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: file.name,
        path: file.path ?? 'Imported from system file picker',
        importedAt: DateTime.now(),
      );

      setState(() {
        _configs.insert(0, entry);
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${file.name} imported into the list.')),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Import failed. This UI is mock-only.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
        });
      }
    }
  }

  void _toggleConfig(String id, bool value) {
    setState(() {
      final int index = _configs.indexWhere((ConfigEntry item) => item.id == id);
      if (index == -1) {
        return;
      }

      _configs[index] = _configs[index].copyWith(isEnabled: value);
    });
  }

  Future<void> _pingConfig(String id) async {
    final int index = _configs.indexWhere((ConfigEntry item) => item.id == id);
    if (index == -1) {
      return;
    }

    setState(() {
      _configs[index] = _configs[index].copyWith(
        isPinging: true,
        pingLabel: 'Pinging...',
      );
    });

    await Future<void>.delayed(
      Duration(milliseconds: 850 + _random.nextInt(700)),
    );

    if (!mounted) {
      return;
    }

    final int refreshedIndex =
        _configs.indexWhere((ConfigEntry item) => item.id == id);
    if (refreshedIndex == -1) {
      return;
    }

    final int latency = 18 + _random.nextInt(137);
    setState(() {
      _configs[refreshedIndex] = _configs[refreshedIndex].copyWith(
        isPinging: false,
        pingLabel: '$latency ms',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final int enabledCount =
        _configs.where((ConfigEntry item) => item.isEnabled).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AW Manager UI'),
        centerTitle: false,
        actions: <Widget>[
          IconButton(
            tooltip: 'Import config',
            onPressed: _isImporting ? null : _importConfig,
            icon: const Icon(Icons.add_link_rounded),
          ),
          const SizedBox(width: 8),
        ],
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
                            color: colors.shadow.withOpacity(0.06),
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
                                        'Smart config dashboard',
                                        style: theme.textTheme.titleLarge?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Material 3 mock UI for importing .aw files and managing visual config states.',
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
                                  icon: Icons.toggle_on_outlined,
                                  label: 'Enabled',
                                  value: '$enabledCount',
                                ),
                                const _MetricChip(
                                  icon: Icons.auto_awesome_outlined,
                                  label: 'Mode',
                                  value: 'UI only',
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
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
                      'Each imported item appears as a vertical card with a switch and a mock ping action.',
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
                            fontWeight: FontWeight.w700,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Tap Import Config and select a .aw file. The app will show it here as a visual entry only.',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 18),
                        OutlinedButton.icon(
                          onPressed: _isImporting ? null : _importConfig,
                          icon: const Icon(Icons.file_open_rounded),
                          label: const Text('Choose .aw file'),
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

                      final ConfigEntry item = _configs[index ~/ 2];
                      return ConfigCard(
                        entry: item,
                        onToggle: (bool value) => _toggleConfig(item.id, value),
                        onPing: () => _pingConfig(item.id),
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
        color: colors.surfaceContainerHighest.withOpacity(0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 18, color: colors.primary),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                value,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
