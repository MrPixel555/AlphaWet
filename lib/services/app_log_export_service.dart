import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../runtime/runtime_bridge.dart';
import 'app_logger.dart';

class AppLogExportService {
  AppLogExportService({AppLogger? logger}) : _logger = logger ?? AppLogger.instance;

  final AppLogger _logger;
  static const String _tag = 'AppLogExportService';

  Future<File> exportLogs() async {
    bool useFallbackDirectory = false;
    if (Platform.isAndroid) {
      final bool granted = await RuntimeBridge.ensureManageStoragePermission();
      if (!granted) {
        useFallbackDirectory = true;
        _logger.warning(
          _tag,
          'Storage permission was not granted for public log export. Falling back to app documents directory.',
        );
      }
    }
    final Directory directory = await _resolveExportDirectory(
      useFallbackDirectory: useFallbackDirectory,
    );
    await directory.create(recursive: true);
    final String timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final File file = File('${directory.path}/AlphaWet_logs_$timestamp.txt');
    await file.writeAsString(_logger.dumpAsText(), flush: true);
    _logger.info(_tag, 'Logs exported to ${file.path}');
    return file;
  }

  Future<Directory> _resolveExportDirectory({bool useFallbackDirectory = false}) async {
    if (Platform.isAndroid && !useFallbackDirectory) {
      return Directory('/storage/emulated/0/AlphaWet/logs');
    }
    return getApplicationDocumentsDirectory();
  }
}
