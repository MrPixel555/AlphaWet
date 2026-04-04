import 'package:flutter/material.dart';

import '../models/config_entry.dart';
import '../models/runtime_settings.dart';
import '../models/vpn_runtime_models.dart';

class ConfigCard extends StatelessWidget {
  const ConfigCard({
    super.key,
    required this.entry,
    required this.runtimeSettings,
    required this.onToggle,
    required this.onPing,
  });

  final ConfigEntry entry;
  final RuntimeSettings runtimeSettings;
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
    final String endpoint = entry.port == null ? entry.host : '${entry.host}:${entry.port}';

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
                    entry.isEnabled ? Icons.shield_rounded : Icons.shield_outlined,
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
                        endpoint,
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
                  onChanged: entry.isBusy ? null : onToggle,
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
                  label: entry.isEnabled ? 'Active' : 'Idle',
                ),
                _StatusPill(
                  icon: _runtimeIcon(entry.connectionState),
                  label: entry.connectionState.label,
                ),
                _StatusPill(
                  icon: Icons.lock_outline_rounded,
                  label: entry.importStatus,
                ),
                _StatusPill(
                  icon: Icons.http_rounded,
                  label: 'HTTP ${runtimeSettings.httpPort}',
                ),
                _StatusPill(
                  icon: Icons.route_rounded,
                  label: 'SOCKS ${runtimeSettings.socksPort}',
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
            if (_hasText(entry.serverName) ||
                _hasText(entry.shortId) ||
                _hasText(entry.engineSessionId) ||
                _hasText(entry.engineMessage)) ...<Widget>[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (_hasText(entry.serverName))
                      _DetailLine(
                        label: 'SNI',
                        value: entry.serverName!,
                      ),
                    if (_hasText(entry.shortId))
                      _DetailLine(
                        label: 'Short ID',
                        value: _maskShortId(entry.shortId!),
                      ),
                    _DetailLine(
                      label: 'Proxy',
                      value: runtimeSettings.proxySummary,
                    ),
                    _DetailLine(
                      label: 'Mode',
                      value: runtimeSettings.enableDeviceVpn ? 'FULL DEVICE VPN' : 'LOCAL PROXY',
                    ),
                    if (_hasText(entry.engineSessionId))
                      _DetailLine(
                        label: 'Session',
                        value: entry.engineSessionId!,
                      ),
                    if (_hasText(entry.engineMessage))
                      _DetailLine(
                        label: 'Runtime',
                        value: entry.engineMessage!,
                      ),
                  ],
                ),
              ),
            ],
            if (_hasText(entry.xrayBuildError)) ...<Widget>[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colors.errorContainer.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  entry.xrayBuildError!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onErrorContainer,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: entry.isPinging || entry.isBusy ? null : onPing,
                  icon: entry.isPinging
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_ping_rounded),
                  label: Text(entry.isPinging ? 'Pinging...' : 'Ping'),
                ),
                Text(
                  _runtimeSummary(entry),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _runtimeSummary(ConfigEntry entry) {
    if (!entry.isXrayReady) {
      return 'Runtime blocked';
    }
    switch (entry.connectionState) {
      case VpnConnectionState.connected:
        return runtimeSettings.enableDeviceVpn
            ? 'Full-device tunnel active'
            : 'Local proxy active';
      case VpnConnectionState.connecting:
        return 'Starting runtime...';
      case VpnConnectionState.validating:
        return 'Validating config...';
      case VpnConnectionState.failed:
        return 'Runtime failed';
      case VpnConnectionState.ready:
        return entry.isSecureEnvelope
            ? 'Ready • verified import'
            : 'Ready • imported';
      case VpnConnectionState.disconnecting:
        return 'Stopping runtime...';
      case VpnConnectionState.idle:
        return 'Runtime idle';
    }
  }

  bool _hasText(String? value) => value != null && value.trim().isNotEmpty;

  String _maskShortId(String value) {
    if (value.length <= 8) {
      return value;
    }
    return '${value.substring(0, 8)}...';
  }

  IconData _runtimeIcon(VpnConnectionState state) {
    switch (state) {
      case VpnConnectionState.idle:
        return Icons.pause_circle_outline_rounded;
      case VpnConnectionState.validating:
        return Icons.rule_folder_outlined;
      case VpnConnectionState.ready:
        return Icons.check_circle_outline_rounded;
      case VpnConnectionState.connecting:
        return Icons.sync_rounded;
      case VpnConnectionState.connected:
        return Icons.verified_rounded;
      case VpnConnectionState.disconnecting:
        return Icons.link_off_rounded;
      case VpnConnectionState.failed:
        return Icons.error_outline_rounded;
    }
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: colors.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
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
        color: colors.surfaceContainerHighest.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 16, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
