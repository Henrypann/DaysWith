import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/webdav_credential_store.dart';
import 'package:jinbao_core/jinbao_core.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const _key = 'webdav-connection-v1';

WebDavSavedConnection _connection([String password = 'SyntheticPassword']) =>
    WebDavSavedConnection(
      name: '合成 NAS',
      url: 'https://nas.example.com/dav/DaysWith/',
      username: 'synthetic-user',
      password: password,
    );

class _SecureStore {
  final values = <String, Object>{};
  final trace = <String>[];
  bool silentWrite = false;
  bool failRead = false;
  bool failWrite = false;
  bool failDelete = false;
  Future<void> Function()? beforeWrite;

  Future<Object?> handle(MethodCall call) async {
    final args = Map<String, Object?>.from(call.arguments as Map);
    final key = args['key'] as String;
    trace.add('${call.method}:$key');
    final options = Map<String, Object?>.from(args['options'] as Map);
    expect(options['accountName'], CredentialStoreContract.keychainService);
    expect(options['accessibility'], 'unlocked_this_device');
    expect(options['synchronizable'], 'false');
    switch (call.method) {
      case 'read':
        if (failRead) throw PlatformException(code: 'synthetic-locked');
        return values[key] is String ? values[key] : null;
      case 'containsKey':
        if (failRead) throw PlatformException(code: 'synthetic-locked');
        return values.containsKey(key);
      case 'write':
        await beforeWrite?.call();
        if (failWrite) throw PlatformException(code: 'synthetic-write-failure');
        if (!silentWrite) values[key] = args['value'] as String;
        return null;
      case 'delete':
        if (failDelete) {
          throw PlatformException(code: 'synthetic-delete-failure');
        }
        values.remove(key);
        return null;
      default:
        throw StateError('Unexpected secure store call');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _SecureStore secure;
  late WebDavCredentialStore store;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    secure = _SecureStore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, secure.handle);
    store = WebDavCredentialStore();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('a missing NAS connection performs no write or delete', () async {
    expect(await store.load(), isNull);
    expect(secure.values, isEmpty);
    expect(secure.trace, ['read:$_key', 'containsKey:$_key']);
  });

  test(
    'connection survives a cold store in the device-only keychain service',
    () async {
      await store.save(_connection());
      expect(await WebDavCredentialStore().load(), _connection());
      expect(secure.trace, containsAllInOrder(['write:$_key', 'read:$_key']));
      expect(secure.values.keys, [_key]);
    },
  );

  test('logs cannot disclose URL or credentials through toString', () {
    final connection = _connection();
    expect(connection.toString(), 'WebDavSavedConnection(redacted)');
    for (final value in [
      connection.name,
      connection.url,
      connection.username,
      connection.password,
    ]) {
      expect(connection.toString(), isNot(contains(value)));
    }
  });

  for (final invalid in [
    'http://nas.example.com/dav/DaysWith/',
    'https://user:password@nas.example.com/dav/DaysWith/',
    'https://nas.example.com/dav/DaysWith/?token=secret',
    'https://nas.example.com/dav/DaysWith/#secret',
    'https://nas.example.com/',
    'https://nas.example.com/personal-photos/',
    'https://nas.example.com/dav/../DaysWith/',
    'https://nas.example.com/dav/%2e%2e/DaysWith/',
    'https://nas.example.com/dav/%252e%252e/DaysWith/',
  ]) {
    test('unsafe NAS endpoint is rejected before secure storage: $invalid', () {
      expect(
        () => WebDavSavedConnection(
          name: '合成连接',
          url: invalid,
          username: 'synthetic-user',
          password: 'synthetic-password',
        ),
        throwsA(isA<Exception>()),
      );
      expect(secure.trace, isEmpty);
    });
  }

  test('invalid Basic username cannot enter the secure store', () {
    expect(
      () => WebDavSavedConnection(
        name: '合成连接',
        url: 'https://nas.example.com/DaysWith/',
        username: 'user:injected',
        password: 'synthetic-password',
      ),
      throwsA(isA<Exception>()),
    );
    expect(secure.values, isEmpty);
  });

  for (final damaged in [
    'not json',
    '{"version":2}',
    '[]',
    '{"version":1.0}',
  ]) {
    test(
      'damaged saved connection fails closed and preserves the item: $damaged',
      () async {
        secure.values[_key] = damaged;
        await expectLater(
          store.load(),
          throwsA(const CosFailure(ConnectionFailure.secureStorage)),
        );
        expect(secure.values[_key], damaged);
        expect(secure.trace, ['read:$_key']);
      },
    );
  }

  test(
    'non-UTF8 existing key is not mistaken for an unconnected device',
    () async {
      secure.values[_key] = Object();
      await expectLater(
        store.load(),
        throwsA(const CosFailure(ConnectionFailure.secureStorage)),
      );
      expect(secure.values.containsKey(_key), isTrue);
      expect(secure.trace, ['read:$_key', 'containsKey:$_key']);
    },
  );

  test('locked keychain cannot trigger a destructive replacement', () async {
    await store.save(_connection());
    final original = secure.values[_key];
    secure.trace.clear();
    secure.failRead = true;
    await expectLater(
      store.save(_connection('SyntheticReplacement')),
      throwsA(const CosFailure(ConnectionFailure.secureStorage)),
    );
    expect(secure.values[_key], original);
    expect(secure.trace, ['read:$_key']);
  });

  test(
    'readback mismatch is surfaced and keeps the prior connection',
    () async {
      await store.save(_connection());
      secure.silentWrite = true;
      await expectLater(
        store.save(_connection('SyntheticReplacement')),
        throwsA(const CosFailure(ConnectionFailure.secureStorage)),
      );
      expect(await store.load(), _connection());
    },
  );

  test('save failure does not report a verified connection', () async {
    await store.save(_connection());
    secure.failWrite = true;
    await expectLater(
      store.save(_connection('SyntheticReplacement')),
      throwsA(const CosFailure(ConnectionFailure.secureStorage)),
    );
    secure.failWrite = false;
    expect(await store.load(), _connection());
  });

  test(
    'disconnect deletes only NAS credentials and verifies absence',
    () async {
      secure.values['cos-credentials'] = 'preserve-cos';
      secure.values['credentials-v1'] = 'preserve-native';
      await store.save(_connection());
      await store.delete();
      expect(await WebDavCredentialStore().load(), isNull);
      expect(secure.values, {
        'cos-credentials': 'preserve-cos',
        'credentials-v1': 'preserve-native',
      });
    },
  );

  test('disconnect failure is not swallowed', () async {
    await store.save(_connection());
    secure.failDelete = true;
    await expectLater(
      store.delete(),
      throwsA(const CosFailure(ConnectionFailure.secureStorage)),
    );
    expect(await store.load(), _connection());
  });

  test('serialized late save cannot undo a requested disconnect', () async {
    final entered = Completer<void>();
    final resume = Completer<void>();
    secure.beforeWrite = () async {
      if (!entered.isCompleted) {
        entered.complete();
        await resume.future;
      }
    };
    final saving = store.save(_connection());
    await entered.future;
    final disconnecting = WebDavCredentialStore().delete();
    resume.complete();
    await saving;
    await disconnecting;
    expect(await store.load(), isNull);
  });
}
