class AwImportException implements Exception {
  const AwImportException(this.message);

  final String message;

  @override
  String toString() => 'AwImportException: $message';
}
