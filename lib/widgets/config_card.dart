import 'package:flutter/material.dart';

import '../models/config_entry.dart';

class ConfigCard extends StatelessWidget {
  const ConfigCard({
    super.key,
    required this.entry,
    required this.onToggle,
    required this.onPing,
  });

  final ConfigEntry entry;
  final ValueChanged<bool> onToggle;
  final VoidCallback onPing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final String formattedDate =
        '${entry.importedAt.year.toString().padLeft(4, '0')}-'
        '${entry.importedAt.month.toString().padLeft(2, '0')}-'
        '${entry.importedAt.day.toString().padLeft(2, '0')} '
        '${entry.importedAt.hour.toString().padLeft(2, '0')}:'
        '${entry.importedAt.minute.toString().padLeft(2, '0')}';

    return Card(
      elevation: 0,
      color: colors.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: entry.isEnabled
                        ? colors.primaryContainer
                        : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    entry.isEnabled
                        ? Icons.shield_rounded
                        : Icons.shield_outlined,
                    color: entry.isEnabled
                        ? colors.onPrimaryContainer
                        : colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        entry.name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        entry.path,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Switch.adaptive(
                  value: entry.isEnabled,
                  onChanged: onToggle,
                ),
              ],
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                _StatusPill(
                  icon: entry.isEnabled
                      ? Icons.power_settings_new_rounded
                      : Icons.pause_circle_outline_rounded,
                  label: entry.isEnabled ? 'Enabled' : 'Disabled',
                ),
                _StatusPill(
                  icon: Icons.speed_rounded,
                  label: entry.pingLabel,
                ),
                _StatusPill(
                  icon: Icons.schedule_rounded,
                  label: formattedDate,
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: entry.isPinging ? null : onPing,
                  icon: entry.isPinging
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_ping_rounded),
                  label: Text(entry.isPinging ? 'Pinging...' : 'Ping'),
                ),
                const SizedBox(width: 10),
                Text(
                  'UI only',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withOpacity(0.6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 16, color: colors.primary),
          const SizedBox(width: 8),
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
