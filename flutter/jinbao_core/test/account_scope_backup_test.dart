import 'dart:convert';
import 'dart:typed_data';

import 'package:jinbao_core/jinbao_core.dart';
import 'package:test/test.dart';

const _endpoint = 'https://nas.example/DaysWith/';
const _device = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
const _request = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';
const _now = 1792382400000;

String _scope(String username) => Digest.sha256Hex(utf8.encode(username));

AppSession _session({String? username}) => AppSession(
  deviceID: _device,
  testBuild: false,
  identity: ParentIdentity.dad,
  link: CloudWebDav(
    name: 'Synthetic NAS',
    endpoint: _endpoint,
    accountScope: username == null ? null : _scope(username),
  ),
  moments: [
    LocalMoment(
      id: 'synthetic-account-scope-record',
      title: 'Synthetic text',
      note: 'No real media',
      occurredAt: _now,
      createdAt: _now,
      updatedAt: _now,
      parent: ParentIdentity.dad,
      assets: [],
      uploadEligibility: UploadEligibility.eligible,
    ),
  ],
);

StorageIdentity _identity(AppSession session, {String? username}) {
  final root = session.link.storageIdentity!;
  return StorageIdentity(
    providerId: root.providerId,
    endpoint: root.endpoint,
    prefix: session.writerPrefix(),
    accountScope: username == null ? root.accountScope : _scope(username),
  );
}

/// Empty remote namespace. Any object IO is unexpected in these binding tests.
class _IdentityProvider extends StorageProvider {
  @override
  final StorageIdentity identity;
  int listCalls = 0;
  int objectCalls = 0;

  _IdentityProvider(this.identity);

  @override
  StorageCapabilities get capabilities => const StorageCapabilities(
    conditionalWrites: true,
    versioning: StorageVersioning.unknown,
    nativePagination: false,
  );
  @override
  Future<void> connect() async {}
  @override
  Future<void> healthCheck() async {}
  @override
  Future<void> verifyImmutableWritesAllowed() async {}
  @override
  Future<StorageListPage> listPage({
    required String prefix,
    String? cursor,
    int limit = 1000,
  }) async {
    listCalls++;
    return StorageListPage(const <String>[]);
  }

  Never _unexpectedObjectIO() {
    objectCalls++;
    throw StateError('Unexpected object IO in an account binding test.');
  }

  @override
  Future<ObjectHead?> stat(String key) async => _unexpectedObjectIO();
  @override
  Future<Uint8List> get({
    required String key,
    int responseLimit = 32 * 1024 * 1024,
  }) async => _unexpectedObjectIO();
  @override
  Future<void> getFile({
    required String key,
    required String destination,
    required int byteCount,
    required String sha256,
  }) async => _unexpectedObjectIO();
  @override
  Future<void> putImmutable({
    required String key,
    required List<int> body,
    required String contentType,
  }) async => _unexpectedObjectIO();
  @override
  Future<void> putImmutableFile({
    required String key,
    required String filePath,
    required int byteCount,
    required String sha256,
    required String contentType,
  }) async => _unexpectedObjectIO();
}

Matcher get _configurationFailure => isA<CosFailure>().having(
  (error) => error.failure,
  'failure',
  ConnectionFailure.configuration,
);

BackupJob _roundTrip(BackupJob job) =>
    BackupJob.fromJson(jsonDecode(jsonEncode(job.toJson())));

void main() {
  test('prepare rejects another NAS account at the same URL before remote IO', () async {
    final session = _session(username: 'synthetic-alice');
    final otherAccount = _IdentityProvider(
      _identity(session, username: 'synthetic-bob'),
    );
    await expectLater(
      BackupQueue.prepareWithProvider(otherAccount, session, now: _now),
      throwsA(_configurationFailure),
    );
    expect(otherAccount.listCalls, 0);
    expect(otherAccount.objectCalls, 0);
  });

  test('scoped target and frozen job survive archive restart with full identity', () async {
    final session = _session(username: 'synthetic-alice');
    final provider = _IdentityProvider(_identity(session));
    final job = await BackupQueue.prepareWithProvider(
      provider,
      session,
      now: _now,
      requestID: _request,
    );
    session.backupJob = job;
    final reopened = PersistedArchive.fromJson(
      jsonDecode(jsonEncode(PersistedArchive.fromSession(session).toJson())),
    ).session();
    expect(reopened.backupJob!.storageIdentity, provider.identity);
    expect(reopened.backupJob!.storageIdentity.accountScope, _scope('synthetic-alice'));
    expect(reopened.link, session.link);
    expect(
      () => BackupQueue.validateWithProvider(reopened.backupJob!, reopened, provider),
      returnsNormally,
    );
  });

  test('changed session account rejects old job even if client still matches that job', () async {
    final session = _session(username: 'synthetic-alice');
    final provider = _IdentityProvider(_identity(session));
    final job = _roundTrip(
      await BackupQueue.prepareWithProvider(provider, session, now: _now),
    );
    final readsBefore = provider.listCalls;
    final switched = _session(username: 'synthetic-bob');
    expect(
      () => BackupQueue.validateWithProvider(job, switched, provider),
      throwsA(_configurationFailure),
    );
    expect(provider.listCalls, readsBefore);
    expect(provider.objectCalls, 0);
  });

  test('restored job cannot advance through another account at the same URL', () async {
    final session = _session(username: 'synthetic-alice');
    final original = _IdentityProvider(_identity(session));
    final job = _roundTrip(
      await BackupQueue.prepareWithProvider(original, session, now: _now),
    );
    final switched = _session(username: 'synthetic-bob');
    final other = _IdentityProvider(_identity(switched));
    var persists = 0;
    await expectLater(
      BackupQueue.advanceWithProvider(
        other,
        switched,
        job,
        resolve: (_) => throw StateError('Must not resolve local media.'),
        persist: (_) {
          persists++;
        },
      ),
      throwsA(_configurationFailure),
    );
    expect(other.listCalls, 0);
    expect(other.objectCalls, 0);
    expect(persists, 0);
    expect(job.status, BackupJobStatus.queued);
  });

  test('legacy unscoped WebDAV job is not silently rebound to a scoped account', () async {
    final legacySession = _session();
    final legacy = _IdentityProvider(_identity(legacySession));
    final job = _roundTrip(
      await BackupQueue.prepareWithProvider(legacy, legacySession, now: _now),
    );
    final scopedSession = _session(username: 'synthetic-alice');
    final scoped = _IdentityProvider(_identity(scopedSession));
    expect(
      () => BackupQueue.validateWithProvider(job, scopedSession, scoped),
      throwsA(_configurationFailure),
    );
    await expectLater(
      BackupQueue.prepareWithProvider(scoped, legacySession, now: _now),
      throwsA(_configurationFailure),
    );
    expect(scoped.listCalls, 0);
    expect(scoped.objectCalls, 0);
  });

  test('legacy COS jobs retain exact bucket and writer namespace compatibility', () async {
    final session = _session()
      ..link = const CloudVerified(
        bucket: 'synthetic-1234567890',
        region: 'ap-shanghai',
      );
    final provider = _IdentityProvider(_identity(session));
    final prepared = await BackupQueue.prepareWithProvider(provider, session, now: _now);
    final legacyJson = Map<String, Object?>.from(prepared.toJson())
      ..remove('storageIdentity');
    final restored = BackupJob.fromJson(jsonDecode(jsonEncode(legacyJson)));
    expect(restored.storageIdentity, provider.identity);
    expect(restored.storageIdentity.accountScope, isNull);
    expect(
      () => BackupQueue.validateWithProvider(restored, session, provider),
      returnsNormally,
    );
    final otherBucket = _session()
      ..link = const CloudVerified(
        bucket: 'other-synthetic-1234567890',
        region: 'ap-shanghai',
      );
    expect(
      () => BackupQueue.validateWithProvider(restored, otherBucket, provider),
      throwsA(_configurationFailure),
    );
  });
}
