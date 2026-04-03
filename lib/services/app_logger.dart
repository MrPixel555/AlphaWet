import 'package:flutter/foundation.dart';

enum AppLogLevel {
  debug,
  info,
  warning,
  error,
}

class AppLogRecord {
  const AppLogRecord({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
    this.error,
    this.stackTrace,
  });

  final DateTime timestamp;
  final AppLogLevel level;
  final String tag;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;

  String toLine() {
    final String ts = timestamp.toIso8601String();
    final String lvl = level.name.toUpperCase();
    final String base = '[$ts] [$lvl] [$tag] $message';
    if (error == null) {
      return base;
    }
    return '$base | error=$error';
  }

  String toExpandedText() {
    final StringBuffer buffer = StringBuffer()..writeln(toLine());
    if (stackTrace != null) {
      buffer.writeln(stackTrace.toString());
    }
    return buffer.toString().trimRight();
  }
}

class AppLogger {
  AppLogger._();

  static final AppLogger instance = AppLogger._();
  static const int _maxRecords = 400;

  final List<AppLogRecord> _records = <AppLogRecord>[];

  List<AppLogRecord> snapshot() => List<AppLogRecord>.unmodifiable(_records);

  String dumpAsText() {
    if (_records.isEmpty) {
      return '[NO LOGS] No records have been captured yet.';
    }

    return _records.map((AppLogRecord record) => record.toExpandedText()).join('\n\n');
  }

  void debug(String tag, String message) => _push(AppLogLevel.debug, tag, message);
  void info(String tag, String message) => _push(AppLogLevel.info, tag, message);
  void warning(String tag, String message, {Object? error, StackTrace? stackTrace}) {
    _push(AppLogLevel.warning, tag, message, error: error, stackTrace: stackTrace);
  }

  void error(String tag, String message, {Object? error, StackTrace? stackTrace}) {
    _push(AppLogLevel.error, tag, message, error: error, stackTrace: stackTrace);
  }

  void _push(
    AppLogLevel level,
    String tag,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final AppLogRecord record = AppLogRecord(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
      error: error,
      stackTrace: stackTrace,
    );

    _records.add(record);
    if (_records.length > _maxRecords) {
      _records.removeRange(0, _records.length - _maxRecords);
    }

    debugPrint(record.toLine());
    if (stackTrace != null) {
      debugPrint(stackTrace.toString());
    }
  }
}
