import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jinbao_core/jinbao_core.dart';
import 'package:test/test.dart';

const _endpoint = 'https://nas.example/DaysWith/';
const _otherEndpoint = 'https://other-nas.example/DaysWith/';
const _device = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
const _request = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';
const _now = 1792382400000;

/// A destination with no cloud bucket, region, signing, or object transport. The
/// generic metadata contract intentionally reports no server-provided hash.
class _MemoryProvider extends StorageProvider {
  @override
  final StorageIdentity identity;
  final objects = <String, Uint8List>{};
  final writes = <String>[];
  final verifications = <String>[];
  int reads = 0;
  bool loseNextCommitAcknowledgement = false;

  _MemoryProvider(String prefix, {String endpoint = _endpoint})
    : identity = StorageIdentity(
        providerId: 'webdav',
        endpoint: endpoint,
        prefix: prefix,
      );

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
    reads++;
    return storageSnapshotPage(
      objects.keys.where((key) => key.startsWith(prefix)).toList(),
      prefix,
      cursor,
      limit,
    );
  }

  @override
  Future<ObjectHead?> stat(String key) async {
    reads++;
    final bytes = objects[key];
    return bytes == null
        ? null
        : ObjectHead(byteCount: bytes.length, sha256: null);
  }

  @override
  Future<Uint8List> get({
    required String key,
    int responseLimit = 32 * 1024 * 1024,
  }) async {
    reads++;
    final bytes = objects[key];
    if (bytes == null) {
      throw const StorageProviderFailure(StorageProviderFailureKind.notFound);
    }
    if (bytes.length > responseLimit) {
      throw const StorageProviderFailure(StorageProviderFailureKind.integrity);
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> getFile({
    required String key,
    required String destination,
    required int byteCount,
    required String sha256,
  }) async {
    reads++;
    verifications.add(key);
    final bytes = objects[key];
    if (bytes == null ||
        bytes.length != byteCount ||
        Digest.sha256Hex(bytes) != sha256) {
      throw const StorageProviderFailure(StorageProviderFailureKind.integrity);
    }
    await File(destination).writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> putImmutable({
    required String key,
    required List<int> body,
    required String contentType,
  }) async {
    final prior = objects[key];
    if (prior != null) {
      if (prior.length != body.length ||
          Digest.sha256Hex(prior) != Digest.sha256Hex(body)) {
        throw const StorageProviderFailure(StorageProviderFailureKind.conflict);
      }
      return;
    }
    writes.add(key);
    objects[key] = Uint8List.fromList(body);
    if (loseNextCommitAcknowledgement && key.contains('/commits/')) {
      loseNextCommitAcknowledgement = false;
      throw const StorageProviderFailure(StorageProviderFailureKind.network);
    }
  }

  @override
  Future<void> putImmutableFile({
    required String key,
    required String filePath,
    required int byteCount,
    required String sha256,
    required String contentType,
  }) async {
    final facts = await Digest.sha256File(filePath);
    if (facts.byteCount != byteCount || facts.hash != sha256) {
      throw const StorageProviderFailure(StorageProviderFailureKind.integrity);
    }
    await putImmutable(
      key: key,
      body: await File(filePath).readAsBytes(),
      contentType: contentType,
    );
  }
}

AppSession _session({String endpoint = _endpoint}) => AppSession(
  deviceID: _device,
  testBuild: false,
  identity: ParentIdentity.dad,
  link: CloudWebDav(name: 'Synthetic NAS', endpoint: endpoint),
  moments: [
    LocalMoment(
      id: 'synthetic-moment',
      title: 'Synthetic local record',
      note: 'No real media',
      occurredAt: _now,
      createdAt: _now,
      updatedAt: _now,
      revision: 1,
      parent: ParentIdentity.dad,
      uploadEligibility: UploadEligibility.eligible,
      assets: [
        LocalAsset(
          id: 'synthetic-asset',
          kind: 'photo',
          capturedAt: _now,
          provenance: 'systemProvided',
          resources: [
            for (final role in ['photo', 'preview'])
              LocalResource(
                id: 'synthetic-$role',
                role: role,
                contentType: 'image/jpeg',
                originalFilename: '$role.jpg',
                byteCount: _bytes(role).length,
                sha256: Digest.sha256Hex(_bytes(role)),
                relativePath: 'media/$role.jpg',
              ),
          ],
        ),
      ],
    ),
  ],
);

Uint8List _bytes(String role) =>
    Uint8List.fromList(utf8.encode('synthetic-$role-content'));

Directory _sources() {
  final directory = Directory.systemTemp.createTempSync(
    'provider-queue-integration-',
  );
  addTearDown(() => directory.deleteSync(recursive: true));
  for (final role in ['photo', 'preview']) {
    File('${directory.path}/media/$role.jpg')
      ..createSync(recursive: true)
      ..writeAsBytesSync(_bytes(role));
  }
  return directory;
}

BackupJob _roundTrip(BackupJob job) =>
    BackupJob.fromJson(jsonDecode(jsonEncode(job.toJson())));

Future<void> _advance(
  _MemoryProvider provider,
  AppSession session,
  BackupJob job,
  Directory sources, {
  void Function(BackupJob)? persist,
  bool Function()? shouldPause,
}) => BackupQueue.advanceWithProvider(
  provider,
  session,
  job,
  resolve: (path) => '${sources.path}/$path',
  persist: (snapshot) => persist?.call(snapshot),
  shouldPause: shouldPause ?? () => false,
);

void main() {
  test('WebDAV queue persists generic identity and publishes without a cloud configuration', () async {
    final session = _session();
    final provider = _MemoryProvider(session.writerPrefix());
    final job = await BackupQueue.prepareWithProvider(
      provider,
      session,
      now: _now,
      requestID: _request,
    );
    final restored = _roundTrip(job);
    expect(restored, job);
    expect(restored.storageIdentity, provider.identity);
    expect(restored.bucket, isEmpty);
    expect(restored.region, isEmpty);
    expect(restored.id, _request);
    final statuses = <BackupJobStatus>[];
    await _advance(
      provider,
      session,
      restored,
      _sources(),
      persist: (snapshot) => statuses.add(snapshot.status),
    );
    expect(restored.status, BackupJobStatus.completed);
    expect(statuses, contains(BackupJobStatus.verifying));
    expect(statuses.last, BackupJobStatus.completed);
    expect(restored.completedCount, 2);
    expect(
      provider.verifications.toSet(),
      restored.uploads.map((upload) => upload.objectKey).toSet(),
    );
    expect(provider.objects[restored.commitKey], restored.commitBytes);
    expect(
      (await FamilyReader.latestStorage(
        provider,
        session.writerPrefix(),
      ))!.commit.requestID,
      _request,
    );
    session.backupJob = restored;
    final reopened = PersistedArchive.fromJson(
      jsonDecode(jsonEncode(PersistedArchive.fromSession(session).toJson())),
    ).session();
    expect(reopened.link, session.link);
    expect(reopened.backupJob, restored);
  });

  test('switching endpoint rejects a restored job before any storage read or write', () async {
    final session = _session();
    final original = _MemoryProvider(session.writerPrefix());
    final job = _roundTrip(
      await BackupQueue.prepareWithProvider(
        original,
        session,
        now: _now,
        requestID: _request,
      ),
    );
    final switched = _session(endpoint: _otherEndpoint);
    final other = _MemoryProvider(
      switched.writerPrefix(),
      endpoint: _otherEndpoint,
    );
    await expectLater(
      _advance(other, switched, job, _sources()),
      throwsA(isA<Exception>()),
    );
    expect(other.reads, 0);
    expect(other.writes, isEmpty);
    expect(job.status, BackupJobStatus.queued);
    await expectLater(
      BackupQueue.prepareWithProvider(other, session, now: _now),
      throwsA(isA<Exception>()),
    );
    expect(other.reads, 0);
    expect(other.writes, isEmpty);
  });

  test('lost commit acknowledgement retries exact publication and rechecks full remote bytes', () async {
    final session = _session();
    final provider = _MemoryProvider(session.writerPrefix())
      ..loseNextCommitAcknowledgement = true;
    final sources = _sources();
    final job = await BackupQueue.prepareWithProvider(
      provider,
      session,
      now: _now,
      requestID: _request,
    );
    await expectLater(
      _advance(provider, session, job, sources),
      throwsA(isA<StorageProviderFailure>()),
    );
    expect(job.status, BackupJobStatus.failed);
    expect(provider.objects[job.commitKey], job.commitBytes);
    final writesBeforeRetry = List<String>.of(provider.writes);
    final retry = _roundTrip(job)..resume();
    await _advance(provider, session, retry, sources);
    expect(retry.status, BackupJobStatus.completed);
    expect(retry.id, job.id);
    expect(retry.commitBytes, job.commitBytes);
    expect(provider.writes, writesBeforeRetry);
    expect(provider.verifications.length, greaterThan(job.uploads.length));
  });

  test(
    'damaged media after commit publication cannot become completed on retry',
    () async {
      final session = _session();
      final provider = _MemoryProvider(session.writerPrefix())
        ..loseNextCommitAcknowledgement = true;
      final sources = _sources();
      final job = await BackupQueue.prepareWithProvider(
        provider,
        session,
        now: _now,
        requestID: _request,
      );
      await expectLater(
        _advance(provider, session, job, sources),
        throwsA(isA<StorageProviderFailure>()),
      );
      final damaged = job.uploads.first;
      provider.objects[damaged.objectKey] = Uint8List(damaged.byteCount);
      final retry = _roundTrip(job)..resume();
      final writesBeforeRetry = List<String>.of(provider.writes);
      final states = <BackupJobStatus>[];
      await expectLater(
        _advance(
          provider,
          session,
          retry,
          sources,
          persist: (snapshot) => states.add(snapshot.status),
        ),
        throwsA(
          isA<StorageProviderFailure>().having(
            (error) => error.kind,
            'kind',
            StorageProviderFailureKind.integrity,
          ),
        ),
      );
      expect(retry.status, BackupJobStatus.failed);
      expect(states, isNot(contains(BackupJobStatus.completed)));
      expect(provider.writes, writesBeforeRetry);
      expect(retry.commitBytes, job.commitBytes);
    },
  );

  test('pause after verified resource resumes from persisted exact IDs and commit bytes', () async {
    final session = _session();
    final provider = _MemoryProvider(session.writerPrefix());
    final sources = _sources();
    final job = await BackupQueue.prepareWithProvider(
      provider,
      session,
      now: _now,
      requestID: _request,
    );
    var pause = false;
    final statuses = <BackupJobStatus>[];
    await _advance(
      provider,
      session,
      job,
      sources,
      shouldPause: () => pause,
      persist: (snapshot) {
        statuses.add(snapshot.status);
        if (snapshot.completedCount == 1) pause = true;
      },
    );
    expect(statuses, contains(BackupJobStatus.verifying));
    expect(job.status, BackupJobStatus.paused);
    expect(job.completedCount, 1);
    expect(provider.objects.containsKey(job.commitKey), isFalse);
    final firstResource = provider.writes.single;
    final restored = _roundTrip(job)..resume();
    await _advance(provider, session, restored, sources);
    expect(restored.status, BackupJobStatus.completed);
    expect(restored.id, job.id);
    expect(restored.commitBytes, job.commitBytes);
    expect(restored.manifestBytes, job.manifestBytes);
    expect(
      restored.uploads.map((upload) => upload.objectKey),
      job.uploads.map((upload) => upload.objectKey),
    );
    expect(provider.writes.where((key) => key == firstResource), hasLength(1));
    expect(provider.objects[restored.commitKey], job.commitBytes);
  });

  test('preparing an already-published snapshot must verify remote media before reporting completed', () async {
    final session = _session();
    final provider = _MemoryProvider(session.writerPrefix());
    final job = await BackupQueue.prepareWithProvider(
      provider,
      session,
      now: _now,
      requestID: _request,
    );
    await _advance(provider, session, job, _sources());
    final damaged = job.uploads.first;
    provider.objects[damaged.objectKey] = Uint8List(damaged.byteCount);
    final writesBeforeRetry = List<String>.of(provider.writes);
    await expectLater(
      BackupQueue.prepareWithProvider(
        provider,
        session,
        now: _now,
        requestID: _request,
      ),
      throwsA(
        isA<StorageProviderFailure>().having(
          (error) => error.kind,
          'kind',
          StorageProviderFailureKind.integrity,
        ),
      ),
    );
    expect(provider.writes, writesBeforeRetry);
  });
}
