class ConfigEntry {
  const ConfigEntry({
    required this.id,
    required this.name,
    required this.path,
    required this.importedAt,
    this.isEnabled = false,
    this.isPinging = false,
    this.pingLabel = 'Not tested',
  });

  final String id;
  final String name;
  final String path;
  final DateTime importedAt;
  final bool isEnabled;
  final bool isPinging;
  final String pingLabel;

  ConfigEntry copyWith({
    String? id,
    String? name,
    String? path,
    DateTime? importedAt,
    bool? isEnabled,
    bool? isPinging,
    String? pingLabel,
  }) {
    return ConfigEntry(
      id: id ?? this.id,
      name: name ?? this.name,
      path: path ?? this.path,
      importedAt: importedAt ?? this.importedAt,
      isEnabled: isEnabled ?? this.isEnabled,
      isPinging: isPinging ?? this.isPinging,
      pingLabel: pingLabel ?? this.pingLabel,
    );
  }
}
