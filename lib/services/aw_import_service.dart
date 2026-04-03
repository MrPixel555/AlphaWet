import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../models/aw_import_models.dart';
import 'app_logger.dart';
import 'aw_import_exception.dart';
import 'aw_payload_parser.dart';

class AwImportService {
  AwImportService({AppLogger? logger})
      : _logger = logger ?? AppLogger.instance,
        _payloadParser = AwPayloadParser(logger: logger ?? AppLogger.instance);

  final AppLogger _logger;
  final AwPayloadParser _payloadParser;

  static const String _tag = 'AwImportService';
  static const String _transportKeyBase64 =
      String.fromEnvironment('AW_TRANSPORT_KEY_BASE64', defaultValue: '');
  static const String _ed25519PublicKeyBase64 =
      String.fromEnvironment('AW_ED25519_PUBLIC_KEY_BASE64', defaultValue: '');
  static const bool allowLegacyPlaintextImport = bool.fromEnvironment(
    'AW_ALLOW_LEGACY_PLAINTEXT_IMPORT',
    defaultValue: false,
  );
  static const int _gcmTagLengthBytes = 16;

  Future<AwImportResult> importFromPath({
    required String path,
    required String fileName,
  }) async {
    _logger.info(_tag, 'Starting import for $fileName');

    final File file = File(path);
    if (!await file.exists()) {
      throw const AwImportException('Selected file does not exist on disk.');
    }

    final Uint8List bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw const AwImportException('Selected file is empty.');
    }

    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw const AwImportException('The .aw file is not valid UTF-8 text.');
    }

    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const AwImportException('The .aw file is blank.');
    }

    final _EnvelopeParseResult envelopeParse = await _parseEnvelopeOrLegacy(trimmed);
    final ParsedAwPayload payload = envelopeParse.payload;

    _logger.info(
      _tag,
      'Import finished. protocol=${payload.profile.protocol}, security=${payload.profile.security}, network=${payload.profile.network}, host=${payload.profile.host}, secure=${payload.isSecureEnvelope}',
    );

    return AwImportResult(
      payload: payload,
      fileName: fileName,
      filePath: path,
      signatureVerified: envelopeParse.signatureVerified,
      decrypted: envelopeParse.decrypted,
    );
  }

  Future<_EnvelopeParseResult> _parseEnvelopeOrLegacy(String input) async {
    final Object? decodedJson = _tryDecodeJson(input);
    if (decodedJson is Map<String, dynamic>) {
      final bool looksLikeEnvelope =
          (decodedJson.containsKey('ciphertext') || decodedJson.containsKey('data')) &&
          (decodedJson.containsKey('signature') || decodedJson.containsKey('sig'));

      if (looksLikeEnvelope) {
        _logger.debug(_tag, 'Secure envelope detected.');
        return _parseSecureEnvelope(decodedJson);
      }

      if (allowLegacyPlaintextImport) {
        _logger.warning(_tag, 'Legacy plaintext JSON payload imported.');
        return _EnvelopeParseResult(
          payload: _payloadParser.parse(input, isSecureEnvelope: false),
          signatureVerified: false,
          decrypted: false,
        );
      }
    }

    if (_looksLikeUri(input)) {
      if (!allowLegacyPlaintextImport) {
        throw const AwImportException('Legacy plaintext import is disabled.');
      }
      _logger.warning(_tag, 'Legacy plaintext URI payload imported.');
      return _EnvelopeParseResult(
        payload: _payloadParser.parse(input, isSecureEnvelope: false),
        signatureVerified: false,
        decrypted: false,
      );
    }

    throw const AwImportException(
      'The .aw file is neither a valid secure envelope nor a supported legacy payload.',
    );
  }

  Future<_EnvelopeParseResult> _parseSecureEnvelope(Map<String, dynamic> envelope) async {
    if (_transportKeyBase64.isEmpty || _ed25519PublicKeyBase64.isEmpty) {
      throw const AwImportException(
        'Secure envelope import is configured, but cryptographic keys were not provided via --dart-define.',
      );
    }

    final int version = (envelope['v'] as num?)?.toInt() ?? 1;
    final String algorithm = (envelope['alg'] as String?)?.trim().isNotEmpty == true
        ? envelope['alg'] as String
        : 'A256GCM';
    final String signatureAlgorithm =
        (envelope['sigAlg'] as String?)?.trim().isNotEmpty == true
            ? envelope['sigAlg'] as String
            : 'Ed25519';
    final String keyId = (envelope['kid'] as String?)?.trim() ?? 'aw-ed25519-v1';
    final String nonceBase64 = ((envelope['nonce'] ?? '') as String).trim();
    final String cipherBase64 =
        (((envelope['ciphertext'] ?? envelope['data']) ?? '') as String).trim();
    final String signatureBase64 =
        (((envelope['signature'] ?? envelope['sig']) ?? '') as String).trim();

    if (nonceBase64.isEmpty || cipherBase64.isEmpty || signatureBase64.isEmpty) {
      throw const AwImportException('Envelope is missing nonce, ciphertext, or signature.');
    }

    if (algorithm != 'A256GCM') {
      throw AwImportException('Unsupported alg "$algorithm". Expected A256GCM.');
    }
    if (signatureAlgorithm != 'Ed25519') {
      throw AwImportException('Unsupported sigAlg "$signatureAlgorithm". Expected Ed25519.');
    }

    final Uint8List nonce;
    final Uint8List cipherAndTag;
    final Uint8List signature;
    try {
      nonce = Uint8List.fromList(base64Decode(nonceBase64));
      cipherAndTag = Uint8List.fromList(base64Decode(cipherBase64));
      signature = Uint8List.fromList(base64Decode(signatureBase64));
    } on FormatException {
      throw const AwImportException('Envelope contains invalid base64 fields.');
    }

    if (cipherAndTag.length <= _gcmTagLengthBytes) {
      throw const AwImportException('Ciphertext is too short.');
    }

    final Uint8List signingMessage = Uint8List.fromList(
      utf8.encode('$version|$algorithm|$keyId|$nonceBase64|$cipherBase64'),
    );

    final bool signatureVerified = await _verifyEnvelopeSignature(
      message: signingMessage,
      signature: signature,
    );
    if (!signatureVerified) {
      throw const AwImportException('Envelope signature verification failed.');
    }

    final String plaintext = await _decryptCiphertext(
      cipherAndTag: cipherAndTag,
      nonce: nonce,
    );

    return _EnvelopeParseResult(
      payload: _payloadParser.parse(plaintext, isSecureEnvelope: true),
      signatureVerified: true,
      decrypted: true,
    );
  }

  Future<bool> _verifyEnvelopeSignature({
    required Uint8List message,
    required Uint8List signature,
  }) {
    try {
      final Ed25519 algorithm = Ed25519();
      final SimplePublicKey publicKey = SimplePublicKey(
        base64Decode(_ed25519PublicKeyBase64),
        type: KeyPairType.ed25519,
      );
      final Signature sig = Signature(signature, publicKey: publicKey);
      return algorithm.verify(message, signature: sig);
    } catch (error, stackTrace) {
      _logger.error(
        _tag,
        'Signature verification crashed.',
        error: error,
        stackTrace: stackTrace,
      );
      throw const AwImportException('Signature verification could not be completed.');
    }
  }

  Future<String> _decryptCiphertext({
    required Uint8List cipherAndTag,
    required Uint8List nonce,
  }) async {
    try {
      final List<int> rawKey = base64Decode(_transportKeyBase64);
      final SecretKey key = SecretKey(rawKey);
      final AesGcm algorithm = AesGcm.with256bits();
      final int splitAt = cipherAndTag.length - _gcmTagLengthBytes;
      final SecretBox box = SecretBox(
        cipherAndTag.sublist(0, splitAt),
        nonce: nonce,
        mac: Mac(cipherAndTag.sublist(splitAt)),
      );
      final List<int> clear = await algorithm.decrypt(box, secretKey: key);
      return utf8.decode(clear);
    } catch (error, stackTrace) {
      _logger.error(
        _tag,
        'Decryption failed.',
        error: error,
        stackTrace: stackTrace,
      );
      throw const AwImportException('The payload could not be decrypted.');
    }
  }

  Object? _tryDecodeJson(String input) {
    try {
      return jsonDecode(input);
    } catch (_) {
      return null;
    }
  }

  bool _looksLikeUri(String input) {
    final Uri? uri = Uri.tryParse(input);
    return uri != null && uri.scheme.isNotEmpty;
  }
}

class _EnvelopeParseResult {
  const _EnvelopeParseResult({
    required this.payload,
    required this.signatureVerified,
    required this.decrypted,
  });

  final ParsedAwPayload payload;
  final bool signatureVerified;
  final bool decrypted;
}
