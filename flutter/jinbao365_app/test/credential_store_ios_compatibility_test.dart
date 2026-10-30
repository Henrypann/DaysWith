import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/credential_store.dart';
import 'package:jinbao_core/jinbao_core.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const _currentKey = 'cos-credentials';
const _nativeKey = 'credentials-v1';
const _disabledKey = 'native-credentials-disabled-v1';
const _credentials = StorageCredentials(secretID: 'SyntheticNativeID', secretKey: 'SyntheticNativeKey');
const _replacement = StorageCredentials(secretID: 'SyntheticFlutterID', secretKey: 'SyntheticFlutterKey');

String _encoded(StorageCredentials credentials, {int? version}) => jsonEncode({
  'version': ?version,
  'secretID': credentials.secretID,
  'secretKey': credentials.secretKey,
  if (credentials.sessionToken != null) 'sessionToken': credentials.sessionToken,
  if (credentials.expiresAt != null) 'expiresAt': credentials.expiresAt,
});

class _Keychain {
  final items = <String, Object>{};
  final trace = <String>[];
  final failReads = <String>{};
  final failWrites = <String>{};
  final destructiveWriteFailures = <String>{};
  final silentWrites = <String>{};
  final failDeletes = <String>{};
  Future<void> Function(String)? beforeRead;

  Future<Object?> handle(MethodCall call) async {
    final arguments = Map<String, Object?>.from(call.arguments as Map);
    final key = arguments['key'] as String;
    final options = Map<String, Object?>.from(arguments['options'] as Map);
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      expect(options['accountName'], CredentialStoreContract.keychainService);
      expect(options['synchronizable'], 'false');
      expect(options['accessibility'], 'unlocked_this_device');
    }
    trace.add('${call.method}:$key');
    switch (call.method) {
      case 'read':
        await beforeRead?.call(key);
        if (failReads.contains(key)) throw PlatformException(code: 'synthetic-locked-keychain');
        final value = items[key];
        // The Darwin plugin reports nil for non-UTF8 data despite the item's
        // existence. containsKey must distinguish it from an empty Keychain.
        return value is String ? value : null;
      case 'containsKey':
        if (failReads.contains(key)) throw PlatformException(code: 'synthetic-locked-keychain');
        return items.containsKey(key);
      case 'write':
        if (failWrites.contains(key)) throw PlatformException(code: 'synthetic-write-failure');
        if (destructiveWriteFailures.contains(key)) {
          // Darwin 0.4.3 can delete an existing item after SecItemUpdate fails,
          // then fail the subsequent SecItemAdd. Do not assume atomic updates.
          items.remove(key);
          throw PlatformException(code: 'synthetic-update-delete-add-failure');
        }
        if (!silentWrites.contains(key)) items[key] = arguments['value'] as String;
        return null;
      case 'delete':
        if (failDeletes.contains(key)) throw PlatformException(code: 'synthetic-delete-failure');
        items.remove(key);
        return null;
      default:
        throw StateError('Unexpected secure storage operation: ${call.method}');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Keychain keychain;
  late CredentialStore store;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    keychain = _Keychain();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      keychain.handle,
    );
    store = CredentialStore();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  });

  for (final version in [1, 2]) {
    test('native blob version $version migrates under the same service and preserves its source', () async {
      final source = _encoded(_credentials, version: version);
      keychain.items[_nativeKey] = source;
      expect(await store.load(), _credentials);
      expect(keychain.items[_nativeKey], source);
      expect(keychain.items[_currentKey], _encoded(_credentials));
      expect(keychain.trace, containsAllInOrder(['read:$_nativeKey', 'write:$_currentKey', 'read:$_currentKey']));
      expect(keychain.trace.where((entry) => entry.startsWith('delete:')), isEmpty);
      keychain.trace.clear();
      expect(await store.load(), _credentials);
      expect(keychain.trace, ['read:$_currentKey']);
    });
  }

  test('native temporary credentials retain their token and exact Unix expiry', () async {
    const temporary = StorageCredentials(
      secretID: 'SyntheticTemporaryID',
      secretKey: 'SyntheticTemporaryKey',
      sessionToken: 'SyntheticToken_+/=123',
      expiresAt: 4000000000,
    );
    keychain.items[_nativeKey] = _encoded(temporary, version: 2);
    expect(await store.load(), temporary);
    expect(await CredentialStore().load(), temporary);
    final saved = jsonDecode(keychain.items[_currentKey] as String) as Map<String, Object?>;
    expect(saved['sessionToken'], temporary.sessionToken);
    expect(saved['expiresAt'], 4000000000);
  });

  test('an existing Flutter credential wins even when the native item is locked or corrupt', () async {
    keychain.items[_currentKey] = _encoded(_replacement);
    keychain.items[_nativeKey] = 'corrupt native item';
    keychain.failReads.add(_nativeKey);
    expect(await store.load(), _replacement);
    expect(keychain.trace, ['read:$_currentKey']);
    expect(keychain.items[_currentKey], _encoded(_replacement));
  });

  test('the oldest separate fields migrate only when both are valid', () async {
    keychain.items['secretID'] = _credentials.secretID;
    keychain.items['secretKey'] = _credentials.secretKey;
    expect(await store.load(), _credentials);
    expect(keychain.items['secretID'], _credentials.secretID);
    expect(keychain.items['secretKey'], _credentials.secretKey);
    expect(keychain.items[_currentKey], _encoded(_credentials));
  });

  test('an empty Keychain returns no credentials and writes nothing', () async {
    expect(await store.load(), isNull);
    expect(keychain.items, isEmpty);
    expect(keychain.trace.where((entry) => entry.startsWith('write:')), isEmpty);
  });

  for (final (label, invalid) in [
    ('invalid JSON', 'not JSON'),
    ('nonobject JSON', '[]'),
    ('unknown version', '{"version":999,"secretID":"SyntheticID","secretKey":"SyntheticKey"}'),
    ('noninteger version', '{"version":1.0,"secretID":"SyntheticID","secretKey":"SyntheticKey"}'),
    ('missing secret', '{"version":2,"secretID":"SyntheticID"}'),
    ('invalid token', '{"version":2,"secretID":"SyntheticID","secretKey":"SyntheticKey","sessionToken":"bad token"}'),
    ('invalid expiry', '{"version":2,"secretID":"SyntheticID","secretKey":"SyntheticKey","expiresAt":0}'),
  ]) {
    test('native blob with $label fails closed without falling back or erasing data', () async {
      keychain.items[_nativeKey] = invalid;
      keychain.items['secretID'] = _credentials.secretID;
      keychain.items['secretKey'] = _credentials.secretKey;
      final original = Map<String, Object>.of(keychain.items);
      await expectLater(store.load(), throwsA(const CosFailure(ConnectionFailure.secureStorage)));
      expect(keychain.items, original);
      expect(keychain.trace.any((entry) => entry.startsWith('write:') || entry.startsWith('delete:')), isFalse);
      expect(keychain.trace, isNot(contains('read:secretID')));
    });
  }

  test('a damaged Flutter item never silently falls back to older native credentials', () async {
    keychain.items[_currentKey] = 'damaged';
    keychain.items[_nativeKey] = _encoded(_credentials, version: 2);
    await expectLater(store.load(), throwsA(const CosFailure(ConnectionFailure.secureStorage)));
    expect(keychain.trace, ['read:$_currentKey']);
  });

  test('locked native storage remains an error and is not treated as unconnected', () async {
    keychain.items[_nativeKey] = _encoded(_credentials, version: 2);
    keychain.failReads.add(_nativeKey);
    await expectLater(store.load(), throwsA(const CosFailure(ConnectionFailure.secureStorage)));
    expect(keychain.items.containsKey(_currentKey), isFalse);
  });

  test('non-UTF8 native data remains an error despite the plugin returning nil', () async {
    keychain.items[_nativeKey] = Object();
    await expectLater(store.load(), throwsA(const CosFailure(ConnectionFailure.secureStorage)));
    expect(keychain.items.containsKey(_currentKey), isFalse);
    expect(keychain.trace, contains('containsKey:$_nativeKey'));
  });

  for (final missing in ['secretID', 'secretKey']) {
    test('a partial oldest credential missing $missing is preserved and fails closed', () async {
      keychain.items['secretID'] = _credentials.secretID;
      keychain.items['secretKey'] = _credentials.secretKey;
      keychain.items.remove(missing);
      final original = Map<String, Object>.of(keychain.items);
      await expectLater(store.load(), throwsA(const CosFailure(ConnectionFailure.secureStorage)));
      expect(keychain.items, original);
    });
  }

  test('failed migration write preserves the native item and succeeds after retry', () async {
    final source = _encoded(_credentials, version: 2);
    keychain.items[_nativeKey] = source;
    keychain.failWrites.add(_currentKey);
    await expectLater(store.load(), throwsA(const CosFailure(ConnectionFailure.secureStorage)));
    expect(keychain.items, {_nativeKey: source});
    keychain.failWrites.clear();
    expect(await store.load(), _credentials);
  });

  test('a migration readback mismatch fails and preserves the old item', () async {
    final source = _encoded(_credentials, version: 2);
    keychain.items[_nativeKey] = source;
    keychain.silentWrites.add(_currentKey);
    await expectLater(store.load(), throwsA(const CosFailure(ConnectionFailure.secureStorage)));
    expect(keychain.items, {_nativeKey: source});
  });

  test('disconnect revokes new and known old items without deleting unrelated accounts', () async {
    keychain.items.addAll({
      _currentKey: _encoded(_replacement),
      _nativeKey: _encoded(_credentials, version: 2),
      'secretID': _credentials.secretID,
      'secretKey': _credentials.secretKey,
      'unrelated-account': 'keep',
    });
    await store.delete();
    expect(await CredentialStore().load(), isNull);
    expect(keychain.items['unrelated-account'], 'keep');
    expect(keychain.items.keys.toSet(), {_disabledKey, 'unrelated-account'});
    final marker = keychain.items[_disabledKey] as String;
    expect(marker, isNot(contains(_credentials.secretID)));
    expect(marker, isNot(contains(_replacement.secretKey)));
    expect(
      keychain.trace,
      containsAllInOrder(['write:$_disabledKey', 'read:$_disabledKey', 'delete:$_currentKey', 'delete:$_nativeKey']),
    );
  });

  test('failed legacy cleanup cannot revive old credentials after disconnect or a cold store', () async {
    keychain.items[_nativeKey] = _encoded(_credentials, version: 2);
    keychain.failDeletes.addAll([_nativeKey, 'secretID', 'secretKey']);
    await store.delete();
    expect(keychain.items.containsKey(_nativeKey), isTrue);
    keychain.trace.clear();
    expect(await CredentialStore().load(), isNull);
    expect(keychain.trace, ['read:$_currentKey', 'containsKey:$_currentKey', 'read:$_disabledKey']);
    await store.save(_replacement);
    expect(await CredentialStore().load(), _replacement);
  });

  test('a failed disconnect marker write fails closed and leaves existing data intact', () async {
    keychain.items[_currentKey] = _encoded(_replacement);
    keychain.items[_nativeKey] = _encoded(_credentials, version: 2);
    final original = Map<String, Object>.of(keychain.items);
    keychain.failWrites.add(_disabledKey);
    await expectLater(store.delete(), throwsA(const CosFailure(ConnectionFailure.secureStorage)));
    expect(keychain.items, original);
    expect(keychain.trace.where((entry) => entry.startsWith('delete:')), isEmpty);
  });

  test('a marker readback mismatch prevents credential deletion', () async {
    keychain.items[_currentKey] = _encoded(_replacement);
    keychain.items[_nativeKey] = _encoded(_credentials, version: 2);
    final original = Map<String, Object>.of(keychain.items);
    keychain.silentWrites.add(_disabledKey);
    await expectLater(store.delete(), throwsA(const CosFailure(ConnectionFailure.secureStorage)));
    expect(keychain.items, original);
    expect(keychain.trace.where((entry) => entry.startsWith('delete:')), isEmpty);
  });

  test('a destructive Flutter update failure cannot fall back to older native credentials', () async {
    keychain.items[_currentKey] = _encoded(_replacement);
    keychain.items[_nativeKey] = _encoded(_credentials, version: 2);
    keychain.destructiveWriteFailures.add(_currentKey);
    await expectLater(store.save(_credentials), throwsA(const CosFailure(ConnectionFailure.secureStorage)));
    expect(keychain.items.containsKey(_currentKey), isFalse);
    expect(keychain.items.containsKey(_disabledKey), isTrue);
    expect(keychain.items[_nativeKey], _encoded(_credentials, version: 2));
    keychain.trace.clear();
    expect(await CredentialStore().load(), isNull);
    expect(keychain.trace, isNot(contains('read:$_nativeKey')));
  });

  test('a permanent marker is never rewritten on repeat disconnect or reconnect', () async {
    keychain.items[_nativeKey] = _encoded(_credentials, version: 2);
    keychain.failDeletes.add(_nativeKey);
    await store.delete();
    final marker = keychain.items[_disabledKey];
    keychain.destructiveWriteFailures.add(_disabledKey);
    keychain.trace.clear();
    await CredentialStore().delete();
    await CredentialStore().save(_replacement);
    expect(await store.load(), _replacement);
    expect(keychain.items[_disabledKey], marker);
    expect(keychain.trace, isNot(contains('write:$_disabledKey')));
    expect(keychain.trace, isNot(contains('delete:$_disabledKey')));
  });

  test('a corrupt fallback marker fails closed and is never overwritten', () async {
    keychain.items[_nativeKey] = _encoded(_credentials, version: 2);
    keychain.items[_disabledKey] = 'damaged-marker';
    await expectLater(store.load(), throwsA(const CosFailure(ConnectionFailure.secureStorage)));
    await expectLater(store.delete(), throwsA(const CosFailure(ConnectionFailure.secureStorage)));
    expect(keychain.items[_disabledKey], 'damaged-marker');
    expect(keychain.trace, isNot(contains('read:$_nativeKey')));
    expect(keychain.trace, isNot(contains('write:$_disabledKey')));
  });

  test('non-UTF8 or locked fallback markers are errors rather than missing markers', () async {
    keychain.items[_nativeKey] = _encoded(_credentials, version: 2);
    keychain.items[_disabledKey] = Object();
    await expectLater(store.load(), throwsA(const CosFailure(ConnectionFailure.secureStorage)));
    keychain.failReads.add(_disabledKey);
    await expectLater(store.delete(), throwsA(const CosFailure(ConnectionFailure.secureStorage)));
    expect(keychain.trace, isNot(contains('read:$_nativeKey')));
    expect(keychain.trace, isNot(contains('write:$_disabledKey')));
  });

  test('an in-flight native import cannot undo an explicit disconnect from another store', () async {
    keychain.items[_nativeKey] = _encoded(_credentials, version: 2);
    keychain.failDeletes.add(_nativeKey);
    final entered = Completer<void>();
    final resume = Completer<void>();
    keychain.beforeRead = (key) async {
      if (key == _nativeKey && !entered.isCompleted) {
        entered.complete();
        await resume.future;
      }
    };
    final loading = store.load();
    await entered.future;
    final disconnecting = CredentialStore().delete();
    resume.complete();
    expect(await loading, _credentials);
    await disconnecting;
    expect(await CredentialStore().load(), isNull);
  });

  test('Android reads, writes and deletes only its existing Flutter key', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    keychain.items[_nativeKey] = _encoded(_credentials, version: 2);
    keychain.items['secretID'] = _credentials.secretID;
    keychain.items['secretKey'] = _credentials.secretKey;
    expect(await store.load(), isNull);
    expect(keychain.trace, ['read:$_currentKey']);
    keychain.trace.clear();
    await store.save(_replacement);
    expect(keychain.trace, ['write:$_currentKey']);
    expect(await store.load(), _replacement);
    await store.delete();
    expect(keychain.items.containsKey(_currentKey), isFalse);
    expect(keychain.items.containsKey(_nativeKey), isTrue);
    expect(await store.load(), isNull);
    expect(keychain.trace.every((entry) => entry.endsWith(':$_currentKey')), isTrue);
  });
}
