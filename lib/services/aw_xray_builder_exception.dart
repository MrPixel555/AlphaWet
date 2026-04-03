class AwXrayBuilderException implements Exception {
  const AwXrayBuilderException(this.message);

  final String message;

  @override
  String toString() => 'AwXrayBuilderException: $message';
}
