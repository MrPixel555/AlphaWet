import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../runtime/runtime_bridge.dart';
import 'app_logger.dart';

class AppLogExportService {
  AppLogExportService({AppLogger? logger}) : _logger = logger ?? AppLogger.instance;

  final AppLogger _logger;
  static const String _tag = 'AppLogExportService';

  Future<File> exportLogs() async {
    if (Platform.isAndroid) {
      final bool granted = await RuntimeBridge.ensureManageStoragePermission();
      if (!granted) {
        throw const FileSystemException('Storage permission was not granted for log export.');
      }
    }
    final Directory directory = await _resolveExportDirectory();
    await directory.create(recursive: true);
    final String timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final File file = File('${directory.path}/AlphaWet_logs_$timestamp.txt');
    await file.writeAsString(_logger.dumpAsText(), flush: true);
    _logger.info(_tag, 'Logs exported to ${file.path}');
    return file;
  }

  Future<Directory> _resolveExportDirectory() async {
    if (Platform.isAndroid) {
      return Directory('/storage/emulated/0/AlphaWet/logs');
    }
    return getApplicationDocumentsDirectory();
  }
}
