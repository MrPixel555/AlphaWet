import 'aw_profile_models.dart';

class ParsedAwPayload {
  const ParsedAwPayload({
    required this.raw,
    required this.isSecureEnvelope,
    required this.payloadKind,
    required this.profile,
    this.json = const <String, dynamic>{},
  });

  final String raw;
  final bool isSecureEnvelope;
  final String payloadKind;
  final AwConnectionProfile profile;
  final Map<String, dynamic> json;

  String get displayName => profile.displayName;
  String get protocol => profile.protocol;
  String get host => profile.host;
  int? get port => profile.port;
  String? get fragment => profile.fragment;
  Map<String, String> get query => profile.queryParameters;
}

class AwImportResult {
  const AwImportResult({
    required this.payload,
    required this.fileName,
    required this.filePath,
    required this.signatureVerified,
    required this.decrypted,
  });

  final ParsedAwPayload payload;
  final String fileName;
  final String filePath;
  final bool signatureVerified;
  final bool decrypted;
}
