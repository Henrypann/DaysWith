import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:jinbao_core/jinbao_core.dart';

/// A single-user NAS connection. This object never belongs in archive JSON,
/// shared preferences, logs or a family invitation.
class WebDavSavedConnection {
  final String name;
  final String url;
  final String username;
  final String password;

  WebDavSavedConnection({
    required String name,
    required String url,
    required this.username,
    required this.password,
  }) : name = name.trim(),
       url = canonicalDirectory(url) {
    if (!WebDavCredentials(username: username, password: password).isValid ||
        this.name.isEmpty ||
        this.name.length > 80 ||
        _hasControls(this.name) ||
        username.isEmpty ||
        username.length > 1024 ||
        username.contains(':') ||
        _hasControls(username) ||
        password.isEmpty ||
        password.length > 4096 ||
        _hasControls(password)) {
      throw const ContractError('webdav', '请填写连接名称、专用账号和密码。');
    }
  }

  /// Use the provider's canonical dedicated-directory validation so saved
  /// connections cannot widen the namespace accepted by the transport.
  static String canonicalDirectory(String value) =>
      WebDavConfiguration(baseUrl: value.trim()).baseUri.toString();

  static bool _hasControls(String value) =>
      value.runes.any((r) => r < 32 || r == 127);

  Map<String, Object> _secureJson() => {
    'version': 1,
    'name': name,
    'url': url,
    'username': username,
    'password': password,
  };

  static WebDavSavedConnection _decode(String raw) {
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> ||
        value['version'] is! int ||
        value['version'] != 1) {
      throw const CosFailure(ConnectionFailure.secureStorage);
    }
    return WebDavSavedConnection(
      name: value['name'] as String,
      url: value['url'] as String,
      username: value['username'] as String,
      password: value['password'] as String,
    );
  }

  @override
  String toString() => 'WebDavSavedConnection(redacted)';

  @override
  bool operator ==(Object other) =>
      other is WebDavSavedConnection &&
      name == other.name &&
      url == other.url &&
      username == other.username &&
      password == other.password;

  @override
  int get hashCode => Object.hash(name, url, username, password);
}

/// Separate from existing COS items and native migration keys. Operations are
/// serialized across instances so a late read/save cannot undo a disconnect.
class WebDavCredentialStore {
  static const _key = 'webdav-connection-v1';
  static Future<void> _operations = Future<void>.value();
  final FlutterSecureStorage _storage;

  WebDavCredentialStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accountName: CredentialStoreContract.keychainService,
              accessibility: KeychainAccessibility.unlocked_this_device,
            ),
          );

  Future<WebDavSavedConnection?> load() => _serial(() async {
    try {
      final value = await _read();
      return value == null ? null : WebDavSavedConnection._decode(value);
    } catch (_) {
      throw const CosFailure(ConnectionFailure.secureStorage);
    }
  });

  Future<void> save(WebDavSavedConnection connection) => _serial(() async {
    String? previous;
    var readPrevious = false;
    try {
      previous = await _read();
      readPrevious = true;
      final encoded = jsonEncode(connection._secureJson());
      await _storage.write(key: _key, value: encoded);
      final readback = await _read();
      if (readback == null ||
          WebDavSavedConnection._decode(readback) != connection) {
        throw const CosFailure(ConnectionFailure.secureStorage);
      }
    } catch (_) {
      // Some platform stores may not update atomically. Best-effort rollback
      // keeps the old connection on a failed replacement; failure still surfaces.
      if (readPrevious) {
        try {
          if (previous != null) {
            await _storage.write(key: _key, value: previous);
          } else {
            await _storage.delete(key: _key);
          }
        } catch (_) {}
      }
      throw const CosFailure(ConnectionFailure.secureStorage);
    }
  });

  Future<void> delete() => _serial(() async {
    try {
      await _storage.delete(key: _key);
      if (await _read() != null) {
        throw const CosFailure(ConnectionFailure.secureStorage);
      }
    } catch (_) {
      throw const CosFailure(ConnectionFailure.secureStorage);
    }
  });

  Future<String?> _read() async {
    final value = await _storage.read(key: _key);
    if (value == null && await _storage.containsKey(key: _key)) {
      throw const CosFailure(ConnectionFailure.secureStorage);
    }
    return value;
  }

  static Future<T> _serial<T>(Future<T> Function() action) {
    final result = _operations.then((_) => action());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}
