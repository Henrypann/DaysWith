import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:jinbao_core/jinbao_core.dart';

/// COS credentials live only in the platform secure store (Android Keystore-backed
/// encrypted preferences, iOS Keychain under DaysWith's own service). Never in the archive.
class CredentialStore {
  static const _key = 'cos-credentials';
  static const _nativeKey = 'credentials-v1';
  static const _legacyDisabledKey = 'native-credentials-disabled-v1';
  static const _legacyDisabledValue = 'disabled-v1';
  static Future<void> _iosOperations = Future<void>.value();
  final FlutterSecureStorage _storage;
  final TargetPlatform? platform;

  CredentialStore({FlutterSecureStorage? storage, this.platform})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accountName: CredentialStoreContract.keychainService,
              accessibility: KeychainAccessibility.unlocked_this_device,
            ),
          );

  bool get _isIOS => !kIsWeb && (platform ?? defaultTargetPlatform) == TargetPlatform.iOS;

  Future<StorageCredentials?> load() => _isIOS ? _serialIOS(_loadIOS) : _loadCurrent();

  Future<StorageCredentials?> _loadCurrent() async {
    final String? text;
    try {
      text = await _storage.read(key: _key);
    } catch (_) {
      throw const CosFailure(ConnectionFailure.secureStorage);
    }
    if (text == null) return null;
    return _decodeCredentials(text);
  }

  Future<void> save(StorageCredentials credentials) =>
      _isIOS ? _serialIOS(() => _saveIOS(credentials)) : _write(credentials);

  Future<void> _write(StorageCredentials credentials) async {
    try {
      await _storage.write(
        key: _key,
        value: jsonEncode({
          'secretID': credentials.secretID,
          'secretKey': credentials.secretKey,
          if (credentials.sessionToken != null) 'sessionToken': credentials.sessionToken,
          if (credentials.expiresAt != null) 'expiresAt': credentials.expiresAt,
        }),
      );
    } catch (_) {
      throw const CosFailure(ConnectionFailure.secureStorage);
    }
  }

  Future<void> delete() async {
    if (_isIOS) return _serialIOS(_deleteIOS);
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }

  Future<StorageCredentials?> _loadIOS() async {
    try {
      final current = await _readIOS(_key);
      if (current != null) {
        return _decodeCredentials(current);
      }
      if (await _legacyDisabled()) return null;
      final native = await _readIOS(_nativeKey);
      final StorageCredentials credentials;
      if (native != null) {
        credentials = _decodeCredentials(native, nativeBlob: true);
      } else {
        final identifier = await _readIOS('secretID');
        final key = await _readIOS('secretKey');
        if (identifier == null && key == null) return null;
        if (identifier == null || key == null) throw const CosFailure(ConnectionFailure.secureStorage);
        credentials = StorageCredentials(secretID: identifier, secretKey: key);
      }
      if (!credentials.isValid) throw const CosFailure(ConnectionFailure.secureStorage);
      // This first add targets a missing Flutter item. Keep the native source
      // and leave fallback enabled if the add or readback fails.
      await _saveIOS(credentials, inherited: true);
      return credentials;
    } catch (_) {
      throw const CosFailure(ConnectionFailure.secureStorage);
    }
  }

  Future<String?> _readIOS(String key) async {
    final value = await _storage.read(key: key);
    // The Darwin plugin returns nil for non-UTF8 Data as well as a missing item.
    // Existing unreadable data must never be mistaken for an empty Keychain.
    if (value == null && await _storage.containsKey(key: key)) {
      throw const CosFailure(ConnectionFailure.secureStorage);
    }
    return value;
  }

  Future<void> _saveIOS(StorageCredentials credentials, {bool inherited = false}) async {
    try {
      if (!credentials.isValid) throw const CosFailure(ConnectionFailure.secureStorage);
      // Plugin updates may delete an old item before a failed re-add. A manual
      // save must never make older native credentials authoritative again.
      if (!inherited) await _disableLegacyFallback();
      await _write(credentials);
      final restored = await _readIOS(_key);
      if (restored == null || _decodeCredentials(restored) != credentials) {
        throw const CosFailure(ConnectionFailure.secureStorage);
      }
    } catch (_) {
      throw const CosFailure(ConnectionFailure.secureStorage);
    }
  }

  Future<void> _deleteIOS() async {
    try {
      await _disableLegacyFallback();
      await _storage.delete(key: _key);
      if (await _readIOS(_key) != null) throw const CosFailure(ConnectionFailure.secureStorage);
    } catch (_) {
      throw const CosFailure(ConnectionFailure.secureStorage);
    }
    for (final key in [_nativeKey, 'secretID', 'secretKey']) {
      try {
        await _storage.delete(key: key);
      } catch (_) {
        // The verified disconnect marker already prevents legacy reads.
      }
    }
  }

  Future<bool> _legacyDisabled() async {
    final marker = await _readIOS(_legacyDisabledKey);
    if (marker == null) return false;
    if (marker != _legacyDisabledValue) throw const CosFailure(ConnectionFailure.secureStorage);
    return true;
  }

  Future<void> _disableLegacyFallback() async {
    if (await _legacyDisabled()) return;
    // This marker is only ever added when absent. Once verified, it is never
    // overwritten or deleted, avoiding the plugin's destructive update path.
    await _storage.write(key: _legacyDisabledKey, value: _legacyDisabledValue);
    if (!await _legacyDisabled()) throw const CosFailure(ConnectionFailure.secureStorage);
  }

  static StorageCredentials _decodeCredentials(String text, {bool nativeBlob = false}) {
    try {
      final value = jsonDecode(text);
      if (value is! Map<String, Object?>) {
        throw const CosFailure(ConnectionFailure.secureStorage);
      }
      if (nativeBlob && value['version'] != 1 && value['version'] != 2) {
        throw const CosFailure(ConnectionFailure.secureStorage);
      }
      if (nativeBlob && value['version'] is! int) throw const CosFailure(ConnectionFailure.secureStorage);
      final credentials = StorageCredentials(
        secretID: value['secretID'] as String,
        secretKey: value['secretKey'] as String,
        sessionToken: value['sessionToken'] as String?,
        expiresAt: value['expiresAt'] as int?,
      );
      if (!credentials.isValid) throw const CosFailure(ConnectionFailure.secureStorage);
      return credentials;
    } catch (_) {
      throw const CosFailure(ConnectionFailure.secureStorage);
    }
  }

  /// Serialize automatic import with explicit saves/disconnects across stores
  /// sharing this service, so an in-flight import cannot undo a disconnect.
  static Future<T> _serialIOS<T>(Future<T> Function() operation) {
    final result = _iosOperations.then<T>((_) => operation());
    _iosOperations = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
