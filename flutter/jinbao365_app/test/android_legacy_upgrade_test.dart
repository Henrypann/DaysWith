import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/android_legacy_upgrade.dart';
import 'package:jinbao365/credential_store.dart';
import 'package:jinbao_core/jinbao_core.dart';

class _Credentials extends CredentialStore {
  StorageCredentials? value;
  bool failSave = false;
  bool failReadBack = false;
  int saves = 0;
  final List<String> events;

  _Credentials(this.events);

  @override
  Future<void> save(StorageCredentials credentials) async {
    events.add('saveCredentials');
    saves++;
    if (failSave) throw const CosFailure(ConnectionFailure.secureStorage);
    value = credentials;
  }

  @override
  Future<StorageCredentials?> load() async => failReadBack ? null : value;

  @override
  Future<void> delete() async => value = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/legacy_upgrade');
  const id = '12345678-1234-4234-8234-123456789abc';
  const credentials = StorageCredentials(
    secretID: 'fixture-id',
    secretKey: 'fixture-key',
  );
  late Directory temporary;
  late Directory source;
  late String destination;
  late ArchiveStore store;
  late Map<String, Object?> payload;
  late _Credentials secure;
  late List<String> calls;
  late List<int> originalBytes;
  late AndroidLegacyUpgrade upgrade;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('jinbao-upgrade-test-');
    source = await Directory('${temporary.path}/native-files').create();
    destination = '${temporary.path}/flutter-files/Jinbao365';
    store = ArchiveStore('$destination/archive.json');
    originalBytes = utf8.encode('synthetic original media bytes');
    final original = await File('${source.path}/native-media/original.png')
        .create(recursive: true);
    await original.writeAsBytes(originalBytes, flush: true);
    final digest = Digest.sha256Hex(originalBytes);
    final resource = LocalResource(
      id: 'resource-1',
      role: 'photo',
      contentType: 'image/png',
      originalFilename: 'original.png',
      byteCount: originalBytes.length,
      sha256: digest,
      relativePath: 'legacy-media/asset-1/original.png',
    );
    final asset = LocalAsset(
      id: 'asset-1',
      kind: 'photo',
      capturedAt: 1700000000000,
      provenance: 'systemPicker',
      resources: [resource],
    );
    final session = AppSession(
      deviceID: id,
      testBuild: false,
      identity: ParentIdentity.mom,
      link: const CloudVerified(
        bucket: 'fixture-1234567890',
        region: 'ap-shanghai',
      ),
      moments: [
        LocalMoment(
          id: 'record-1',
          title: '旧版本记录',
          note: '内容不变',
          occurredAt: 1700000000000,
          createdAt: 1690000000000,
          updatedAt: 1710000000000,
          revision: 7,
          trashedAt: 1720000000000,
          parent: ParentIdentity.mom,
          assets: [asset],
          uploadEligibility: UploadEligibility.eligible,
        ),
      ],
      draft: ComposerDraft(
        id: 'draft-1',
        title: '未完成内容',
        note: '续写',
        occurredAt: 1710000000000,
        assets: [asset.copy()],
        uploadEligibility: UploadEligibility.eligible,
      ),
      anniversaries: [
        LocalAnniversary(
          id: 'anniversary-1',
          owner: ParentIdentity.mom,
          title: '生日',
          date: '2024-03-01',
          updatedAt: 1710000000000,
          uploadEligibility: UploadEligibility.eligible,
        ),
      ],
    );
    payload = {
      'archive': PersistedArchive.fromSession(session).toJson(),
      'mediaRoot': source.path,
      'sourceFingerprint': 'fixture-source-1',
      'credentialsRequired': true,
      'mediaFiles': [
        {
          'sourcePath': original.path,
          'targetPath': resource.relativePath,
          'sha256': digest,
          'byteCount': originalBytes.length,
        },
      ],
    };
    (payload['archive'] as Map<String, Object?>)['backupJob'] = {
      'prefix': 'life/v1/mom/old-chain/',
    };
    calls = [];
    secure = _Credentials(calls);
    upgrade = AndroidLegacyUpgrade(
      platformChannel: channel,
      credentials: secure,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'prepareMigration') {
            expect(call.arguments, {'testBuild': true});
            return payload;
          }
          if (call.method == 'readLegacyCredentials') {
            expect(call.arguments, {
              'bucket': 'fixture-1234567890',
              'region': 'ap-shanghai',
            });
            expect(File(store.path).existsSync(), isFalse);
            expect(
              File('$destination/legacy-media/asset-1/original.png')
                  .readAsBytesSync(),
              originalBytes,
            );
            return {
              'secretID': credentials.secretID,
              'secretKey': credentials.secretKey,
            };
          }
          throw MissingPluginException();
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await temporary.delete(recursive: true);
  });

  Future<void> migrate() => upgrade.migrateIfNeeded(
    store: store,
    directory: destination,
    testBuild: true,
  );

  test('inherits identity, records, trash, draft, anniversaries and media before publishing', () async {
    final sourcePayload = jsonEncode(payload);
    await migrate();
    final archive = store.load()!;
    expect(archive.deviceID, id);
    expect(archive.identityFolder, 'mom');
    expect(archive.testBuild, isTrue);
    expect(archive.link, isA<CloudVerified>());
    expect(archive.moments.single.title, '旧版本记录');
    expect(archive.moments.single.note, '内容不变');
    expect(archive.moments.single.revision, 7);
    expect(archive.moments.single.trashedAt, 1720000000000);
    expect(
      archive.moments.single.uploadEligibility,
      UploadEligibility.localOnly,
    );
    expect(archive.draft!.title, '未完成内容');
    expect(archive.draft!.uploadEligibility, UploadEligibility.localOnly);
    expect(archive.anniversaries.single.title, '生日');
    expect(
      archive.anniversaries.single.uploadEligibility,
      UploadEligibility.localOnly,
    );
    expect(archive.backupJob, isNull);
    expect(archive.session().writerPrefix(), 'life/v1/test/$id/');
    expect(calls, [
      'prepareMigration',
      'readLegacyCredentials',
      'saveCredentials',
    ]);
    expect(secure.value!.secretKey, credentials.secretKey);
    expect(
      File('${source.path}/native-media/original.png').readAsBytesSync(),
      originalBytes,
    );
    expect(
      jsonEncode(payload),
      sourcePayload,
      reason: 'Native input is read-only.',
    );
    final text = File(store.path).readAsStringSync();
    expect(text, isNot(contains(credentials.secretID)));
    expect(text, isNot(contains(credentials.secretKey)));
    expect(text, isNot(contains('sourcePath')));
    final receipt = jsonDecode(
      File('$destination/native-upgrade-v1.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(receipt, {
      'version': 1,
      'sourceFingerprint': 'fixture-source-1',
      'deviceID': id,
      'identityFolder': 'mom',
      'recordCount': 1,
      'mediaCount': 1,
      'credentialsCopiedAndVerified': true,
      'testBuild': true,
    });
  });

  test('a completed import never reads the old source or revives disconnected credentials', () async {
    await migrate();
    final bytes = File(store.path).readAsBytesSync();
    await secure.delete();
    calls.clear();
    await migrate();
    expect(calls, isEmpty);
    expect(secure.value, isNull);
    expect(File(store.path).readAsBytesSync(), bytes);
    expect(secure.saves, 1);
  });

  test('secure storage failure leaves no archive and retries identical copied files safely', () async {
    secure.failSave = true;
    await expectLater(migrate(), throwsA(isA<CosFailure>()));
    expect(File(store.path).existsSync(), isFalse);
    expect(File(store.recoveryPath).existsSync(), isFalse);
    expect(
      File('${source.path}/native-media/original.png').readAsBytesSync(),
      originalBytes,
    );
    secure.failSave = false;
    await migrate();
    expect(store.load()!.moments.single.title, '旧版本记录');
    expect(secure.saves, 2);
  });

  test(
    'a credential readback mismatch prevents publishing the archive',
    () async {
      secure.failReadBack = true;
      await expectLater(migrate(), throwsA(isA<CosFailure>()));
      expect(secure.saves, 1);
      expect(File(store.path).existsSync(), isFalse);
      expect(File(store.recoveryPath).existsSync(), isFalse);
      expect(File('$destination/native-upgrade-v1.json').existsSync(), isFalse);
    },
  );

  test('invalid media stops before credentials and does not publish an empty archive', () async {
    await File('${source.path}/native-media/original.png')
        .writeAsString('changed source');
    await expectLater(migrate(), throwsA(isA<ContractError>()));
    expect(calls, ['prepareMigration']);
    expect(secure.saves, 0);
    expect(File(store.path).existsSync(), isFalse);
    expect(File(store.recoveryPath).existsSync(), isFalse);
  });

  test(
    'missing resources stop migration instead of dropping a record',
    () async {
      payload['mediaFiles'] = <Object?>[];
      await expectLater(migrate(), throwsA(isA<ContractError>()));
      expect(secure.saves, 0);
      expect(File(store.path).existsSync(), isFalse);
    },
  );

  test('target traversal cannot overwrite an unrelated file', () async {
    final untouched = await File('${temporary.path}/untouched')
        .writeAsString('keep');
    final map = (payload['mediaFiles'] as List).single as Map<String, Object?>;
    map['targetPath'] = '../untouched';
    await expectLater(migrate(), throwsA(isA<ContractError>()));
    expect(await untouched.readAsString(), 'keep');
    expect(File(store.path).existsSync(), isFalse);
  });

  test('a source outside native media root cannot be copied', () async {
    final outside = await File('${temporary.path}/outside.png')
        .writeAsBytes(originalBytes);
    final map = (payload['mediaFiles'] as List).single as Map<String, Object?>;
    map['sourcePath'] = outside.path;
    await expectLater(migrate(), throwsA(isA<ContractError>()));
    expect(File(store.path).existsSync(), isFalse);
    expect(secure.saves, 0);
  });

  test(
    'a corrupt existing Flutter archive is preserved and never reimported',
    () async {
      await File(store.path).create(recursive: true);
      await File(store.path).writeAsString('unreadable original');
      await expectLater(migrate(), throwsA(isA<ContractError>()));
      expect(calls, isEmpty);
      expect(File(store.path).readAsStringSync(), 'unreadable original');
    },
  );

  test('an existing target with other bytes is preserved', () async {
    final target = await File('$destination/legacy-media/asset-1/original.png')
        .create(recursive: true);
    await target.writeAsString('keep old target');
    await expectLater(migrate(), throwsA(isA<ContractError>()));
    expect(await target.readAsString(), 'keep old target');
    expect(File(store.path).existsSync(), isFalse);
  });

  test('an unconfigured native archive needs no credential read', () async {
    (payload['archive'] as Map<String, Object?>)['link'] = const CloudMissing()
        .toJson();
    payload['credentialsRequired'] = false;
    await migrate();
    expect(store.load()!.link, isA<CloudMissing>());
    expect(calls, ['prepareMigration']);
    expect(secure.value, isNull);
  });

  test('no native source returns without creating an archive or reading credentials', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
    await migrate();
    expect(calls, ['prepareMigration']);
    expect(File(store.path).existsSync(), isFalse);
    expect(secure.value, isNull);
  });
}
