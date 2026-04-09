import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

class OpaqueWindowsStorage {
  OpaqueWindowsStorage._();

  static final OpaqueWindowsStorage instance = OpaqueWindowsStorage._();

  static const int _keySeedLength = 32;
  static const String _folderName = 'AlphaWet';
  static const String _vaultFolderName = 'runtime-cache';
  static const String _keyFileName = 'd1f73c9a.kbx';

  static const Map<String, String> _logicalFiles = <String, String>{
    'configs.persisted.v1': 'c8f2b4e1.bin',
    'runtime.settings.v1': 'r91ac4d0.bin',
    'alphawet.config_entries': 'e4ab2077.bin',
  };

  final X25519 _keyExchange = X25519();
  final AesGcm _cipher = AesGcm.with256bits();

  bool get isAvailable => Platform.isWindows;

  Future<String?> readText(String logicalKey) async {
    final File file = await _dataFile(logicalKey);
    if (!await file.exists()) {
      return null;
    }

    final Object? decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) {
      return null;
    }

    final List<int> envelopePublicKey = _decodeBase64(decoded['epk']);
    final List<int> nonce = _decodeBase64(decoded['n']);
    final List<int> mac = _decodeBase64(decoded['m']);
    final List<int> cipherText = _decodeBase64(decoded['c']);
    if (envelopePublicKey.length != 32 || nonce.isEmpty || mac.isEmpty) {
      return null;
    }

    final KeyPair keyPair = await _loadOrCreateKeyPair();
    final SecretKey sharedSecret = await _keyExchange.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(
        envelopePublicKey,
        type: _keyExchange.keyPairType,
      ),
    );

    final List<int> clearText = await _cipher.decrypt(
      SecretBox(
        cipherText,
        nonce: nonce,
        mac: Mac(mac),
      ),
      secretKey: sharedSecret,
    );
    return utf8.decode(clearText);
  }

  Future<void> writeText(String logicalKey, String value) async {
    final File file = await _dataFile(logicalKey);
    final KeyPair staticKeyPair = await _loadOrCreateKeyPair();
    final SimplePublicKey staticPublicKey =
        (await staticKeyPair.extractPublicKey()) as SimplePublicKey;
    final KeyPair ephemeralKeyPair = await _keyExchange.newKeyPair();
    final SimplePublicKey ephemeralPublicKey =
        (await ephemeralKeyPair.extractPublicKey()) as SimplePublicKey;

    final SecretKey sharedSecret = await _keyExchange.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: staticPublicKey,
    );
    final SecretBox secretBox = await _cipher.encrypt(
      utf8.encode(value),
      secretKey: sharedSecret,
      nonce: _cipher.newNonce(),
    );

    final Map<String, Object> envelope = <String, Object>{
      'v': 1,
      'alg': 'x25519+a256gcm',
      'epk': _encodeBase64(ephemeralPublicKey.bytes),
      'n': _encodeBase64(secretBox.nonce),
      'm': _encodeBase64(secretBox.mac.bytes),
      'c': _encodeBase64(secretBox.cipherText),
    };

    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(envelope), flush: true);
  }

  Future<void> delete(String logicalKey) async {
    final File file = await _dataFile(logicalKey);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<File> _dataFile(String logicalKey) async {
    final Directory root = await _storageRoot();
    final String fileName = _logicalFiles[logicalKey] ?? '${logicalKey.hashCode.abs()}.bin';
    return File('${root.path}${Platform.pathSeparator}$fileName');
  }

  Future<KeyPair> _loadOrCreateKeyPair() async {
    final File keyFile = await _keyFile();
    if (!await keyFile.exists()) {
      final List<int> seed = _randomBytes(_keySeedLength);
      final KeyPair keyPair = await _keyExchange.newKeyPairFromSeed(seed);
      final SimplePublicKey publicKey = (await keyPair.extractPublicKey()) as SimplePublicKey;
      final Map<String, Object> payload = <String, Object>{
        'v': 1,
        'seed': _encodeBase64(seed),
        'pub': _encodeBase64(publicKey.bytes),
      };
      await keyFile.parent.create(recursive: true);
      await keyFile.writeAsString(jsonEncode(payload), flush: true);
      return keyPair;
    }

    final Object? decoded = jsonDecode(await keyFile.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid Windows vault key material.');
    }

    final List<int> seed = _decodeBase64(decoded['seed']);
    if (seed.length != _keySeedLength) {
      throw const FormatException('Invalid Windows vault seed length.');
    }
    return _keyExchange.newKeyPairFromSeed(seed);
  }

  Future<File> _keyFile() async {
    final Directory root = await _storageRoot();
    return File('${root.path}${Platform.pathSeparator}$_keyFileName');
  }

  Future<Directory> _storageRoot() async {
    final String? appData = Platform.environment['APPDATA'];
    if (appData != null && appData.trim().isNotEmpty) {
      return Directory(
        '$appData${Platform.pathSeparator}$_folderName${Platform.pathSeparator}$_vaultFolderName',
      );
    }

    final Directory support = await getApplicationSupportDirectory();
    return Directory(
      '${support.path}${Platform.pathSeparator}$_folderName${Platform.pathSeparator}$_vaultFolderName',
    );
  }

  List<int> _randomBytes(int length) {
    final Random random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256), growable: false);
  }

  List<int> _decodeBase64(Object? value) {
    final String text = (value as String? ?? '').trim();
    if (text.isEmpty) {
      return const <int>[];
    }
    return base64Url.decode(base64Url.normalize(text));
  }

  String _encodeBase64(List<int> bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
