import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jinbao_core/jinbao_core.dart';
import 'package:test/test.dart';

import 'support.dart';

const _now = 1792382400000;
const _device = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
const _link = CloudVerified(bucket: 'example-1234567890', region: 'ap-shanghai');

AppSession _session({List<LocalMoment>? moments, List<LocalAnniversary>? anniversaries}) => AppSession(
      deviceID: _device,
      testBuild: false,
      identity: ParentIdentity.dad,
      link: _link,
      moments: moments,
      anniversaries: anniversaries,
    );

LocalAsset _asset(String name) => LocalAsset(
      id: name,
      kind: 'photo',
      capturedAt: _now,
      provenance: 'systemProvided',
      resources: [
        for (final role in ['photo', 'preview'])
          LocalResource(
            id: '$name-$role',
            role: role,
            contentType: 'image/jpeg',
            originalFilename: '$role.jpg',
            byteCount: utf8.encode('$name-$role').length,
            sha256: Digest.sha256Hex(utf8.encode('$name-$role')),
            relativePath: 'media/$name/$role.jpg',
          ),
      ],
    );

LocalMoment _moment(String id,
        {List<LocalAsset> assets = const [], UploadEligibility eligibility = UploadEligibility.eligible, int? trashedAt}) =>
    LocalMoment(
      id: id,
      title: id,
      note: 'synthetic record',
      occurredAt: _now,
      createdAt: _now,
      updatedAt: _now,
      revision: 1,
      trashedAt: trashedAt,
      parent: ParentIdentity.dad,
      assets: assets,
      uploadEligibility: eligibility,
    );

LocalAnniversary _anniversary(int id, {int? deletedAt}) => LocalAnniversary(
      id: uuid(id),
      owner: ParentIdentity.dad,
      title: 'anniversary $id',
      date: '2026-10-19',
      deletedAt: deletedAt,
      updatedAt: _now,
      uploadEligibility: UploadEligibility.eligible,
    );

Directory _mediaDirectory(List<LocalAsset> assets) {
  final directory = Directory.systemTemp.createTempSync('cloud-snapshot-preservation-');
  addTearDown(() => directory.deleteSync(recursive: true));
  for (final asset in assets) {
    for (final resource in asset.resources) {
      File('${directory.path}/${resource.relativePath}')
        ..createSync(recursive: true)
        ..writeAsBytesSync(utf8.encode('${asset.id}-${resource.role}'));
    }
  }
  return directory;
}

/// Represents a native writer's already-published snapshot. It deliberately does
/// not pass through the queue being tested and can use noncanonical JSON bytes.
CommitReceipt _seed(MemoryCos memory, AppSession old, {bool prettyLowercase = false}) {
  final plan = BackupPlan.manifest(old, now: _now);
  Object? lowercaseIDs(Object? value) {
    if (value is List) return value.map(lowercaseIDs).toList();
    if (value is Map<String, Object?>) return value.map((key, value) => MapEntry(key, lowercaseIDs(value)));
    if (value is String && RegExp(r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$').hasMatch(value)) {
      return value.toLowerCase();
    }
    return value;
  }

  final manifestBytes = prettyLowercase
      ? Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(lowercaseIDs(jsonDecode(utf8.decode(plan.bytes))))))
      : plan.bytes;
  final hash = Digest.sha256Hex(manifestBytes);
  final commit = V1Commit(
    sequence: 1,
    writerDeviceID: _device,
    manifestHash: hash,
    manifestKey: '${plan.prefix}snapshots/$hash.json',
    createdAt: _now,
    requestID: uuid(901),
  );
  final commitBytes = prettyLowercase
      ? Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent(' ').convert(jsonDecode(utf8.decode(V1Json.encodeCommit(commit))))))
      : V1Json.encodeCommit(commit);
  memory.objects[commit.manifestKey] = manifestBytes;
  memory.objects[plan.prefix + V1Json.commitRelativeKey(1)] = commitBytes;
  for (final asset in old.moments.expand((moment) => moment.assets)) {
    for (final resource in asset.resources) {
      memory.objects[V1Layout.objectKey(prefix: plan.prefix, sha256: resource.sha256)] =
          Uint8List.fromList(utf8.encode('${asset.id}-${resource.role}'));
    }
  }
  return CommitReceipt(commit: commit, commitHash: Digest.sha256Hex(commitBytes), manifest: plan.manifest);
}

Future<void> _advance(CosClient client, AppSession state, BackupJob job, {Directory? media}) => BackupQueue.advance(
      client,
      state,
      job,
      resolve: (path) => media == null ? throw StateError('No local source for a cloud-only resource') : '${media.path}/$path',
      persist: (_) {},
    );

/// Re-sign the untrusted job's own internal hash fields, as a modified persisted
/// archive could. The queue must still reject data absent from a remote base.
BackupJob _replaceManifest(BackupJob job, V1Manifest manifest, {V1Manifest? local, String? parentHash}) {
  final json = job.toJson();
  final bytes = V1Json.encodeManifest(manifest);
  final commit = job.commit;
  commit.manifestHash = Digest.sha256Hex(bytes);
  commit.manifestKey = '${job.prefix}snapshots/${commit.manifestHash}.json';
  if (parentHash != null) commit.parentHash = parentHash;
  json['manifestBytes'] = base64.encode(bytes);
  json['commitBytes'] = base64.encode(V1Json.encodeCommit(commit));
  if (local != null) json['localManifestBytes'] = base64.encode(V1Json.encodeManifest(local));
  return BackupJob.fromJson(json);
}

class _LostCommitResponse extends MemoryCos {
  bool loseNextCommitResponse = true;

  @override
  Future<ObjectResponse> execute(ObjectRequest request) async {
    final response = await super.execute(request);
    if (loseNextCommitResponse && request.method == 'PUT' && request.path.contains('/commits/')) {
      loseNextCommitResponse = false;
      throw const SocketException('synthetic lost commit response');
    }
    return response;
  }
}

void main() {
  test('native live records, tombstones, anniversaries and cloud-only media survive the next full snapshot', () async {
    final oldAsset = _asset('native-cloud-only');
    final old = _session(
      moments: [_moment('native-live', assets: [oldAsset]), _moment('native-trashed', trashedAt: _now + 1)],
      anniversaries: [_anniversary(1), _anniversary(2, deletedAt: _now + 2)],
    );
    final memory = MemoryCos();
    final base = _seed(memory, old);
    final newAsset = _asset('flutter-new');
    final state = _session(moments: [
      _moment('native-live', eligibility: UploadEligibility.localOnly, assets: [oldAsset.copy()])..title = 'local-only edit',
      _moment('never-published-local', eligibility: UploadEligibility.localOnly),
      _moment('never-published-test', eligibility: UploadEligibility.testOnly),
      _moment('flutter-new', assets: [newAsset]),
    ]);
    final client = memoryClient(memory, prefix: state.writerPrefix());
    final job = await BackupQueue.prepare(client, state, now: _now + 3, requestID: uuid(902));
    expect(job.commit.parentHash, base.commitHash);
    expect(job.manifest.moments.map((record) => record.title).toSet(), {'native-live', 'native-trashed', 'flutter-new'});
    expect(job.manifest.anniversaries.map((anniversary) => anniversary.deletedAt), [null, _now + 2]);
    expect(job.uploads.length, 2);
    expect(job.uploads.every((upload) => upload.relativePath.contains('flutter-new')), isTrue);
    final directory = _mediaDirectory([newAsset]);
    await _advance(client, state, job, media: directory);
    final latest = (await FamilyReader.latest(client, state.writerPrefix()))!;
    expect(latest.commit.sequence, 2);
    expect(latest.manifest.moments.length, 3);
    expect(latest.manifest.moments.singleWhere((record) => record.title == 'native-trashed').trashedAt, _now + 1);
    expect(latest.manifest.resources.length, 4);
    expect(memory.requests.where((request) => request.method == 'PUT' && request.path.contains('/objects/')).length, 2);
    final family = await FamilyReader.readArchive(memoryClient(memory), owner: ParentIdentity.mom, deviceID: uuid(99), testBuild: false);
    expect(family.moments.map((record) => record.title).toSet(), {'native-live', 'flutter-new'});
    expect(family.anniversaries.length, 2);
  });

  test('canonical ID replacement retains the actual dependency closure and removes replaced orphan media', () async {
    final old = _session(moments: [_moment(uuid(10), assets: [_asset('old')]), _moment('retained')]);
    final memory = MemoryCos();
    _seed(memory, old, prettyLowercase: true);
    final replacement = _moment(uuid(10).toLowerCase())..title = 'replacement';
    final state = _session(moments: [replacement]);
    final client = memoryClient(memory, prefix: state.writerPrefix());
    final job = await BackupQueue.prepare(client, state, now: _now + 3);
    expect(job.manifest.moments.length, 2);
    expect(job.manifest.moments.where((record) => record.id == uuid(10).toUpperCase()).single.title, 'replacement');
    expect(job.manifest.assets, isEmpty);
    expect(job.manifest.resources, isEmpty);
    await _advance(client, state, job);
    expect(job.status, BackupJobStatus.completed);
  });

  test('noncanonical native manifest and commit bytes anchor by their real remote hashes', () async {
    final old = _session(moments: [_moment(uuid(15), assets: [_asset('native-photo')])]);
    final memory = MemoryCos();
    final base = _seed(memory, old, prettyLowercase: true);
    expect(base.commitHash, isNot(Digest.sha256Hex(V1Json.encodeCommit(base.commit))));
    final state = _session(moments: [_moment('new text')]);
    final client = memoryClient(memory, prefix: state.writerPrefix());
    final job = await BackupQueue.prepare(client, state, now: _now + 3);
    expect(job.commit.parentHash, base.commitHash);
    await _advance(client, state, job);
    final latest = (await FamilyReader.latest(client, state.writerPrefix()))!;
    expect(latest.manifest.moments.length, 2);
    expect(latest.manifest.resources.length, 2);
  });

  test('a missing cloud-only object stops before every PUT', () async {
    final memory = MemoryCos();
    final old = _session(moments: [_moment('old', assets: [_asset('old')])]);
    _seed(memory, old);
    final state = _session(moments: [_moment('new', assets: [_asset('new')])]);
    final client = memoryClient(memory, prefix: state.writerPrefix());
    final job = await BackupQueue.prepare(client, state, now: _now + 3);
    memory.objects.remove(job.manifest.resources.firstWhere((resource) => !job.uploads.any((upload) => upload.objectKey == resource.objectKey)).objectKey);
    memory.requests.clear();
    await expectLater(_advance(client, state, job), throwsA(isA<CosFailure>()));
    expect(memory.requests.where((request) => request.method == 'PUT'), isEmpty);
    expect(job.status, BackupJobStatus.failed);
    expect((await FamilyReader.latest(client, state.writerPrefix()))!.commit.sequence, 1);
  });

  test('inconsistent shared asset identities fail before a new job can write', () async {
    final shared = _asset('shared');
    final memory = MemoryCos();
    _seed(memory, _session(moments: [_moment('old', assets: [shared])]));
    final changed = shared.copy()..capturedAt = _now + 1;
    final state = _session(moments: [_moment('new', assets: [changed])]);
    await expectLater(BackupQueue.prepare(memoryClient(memory, prefix: state.writerPrefix()), state, now: _now + 3), throwsA(isA<CosFailure>()));
    expect(memory.requests.where((request) => request.method == 'PUT'), isEmpty);
  });

  test('inconsistent shared resource identities fail before a new job can write', () async {
    final shared = _asset('shared-resource');
    final memory = MemoryCos();
    _seed(memory, _session(moments: [_moment('old', assets: [shared])]));
    final changed = shared.copy();
    changed.resources.first.originalFilename = 'other.jpg';
    final state = _session(moments: [_moment('new', assets: [changed])]);
    await expectLater(BackupQueue.prepare(memoryClient(memory, prefix: state.writerPrefix()), state, now: _now + 3), throwsA(isA<CosFailure>()));
    expect(memory.requests.where((request) => request.method == 'PUT'), isEmpty);
  });

  test('identical shared media is retained once and can belong to a new eligible record', () async {
    final shared = _asset('shared-identical');
    final memory = MemoryCos();
    _seed(memory, _session(moments: [_moment('old', assets: [shared])]));
    final state = _session(moments: [_moment('new', assets: [shared.copy()])]);
    final client = memoryClient(memory, prefix: state.writerPrefix());
    final job = await BackupQueue.prepare(client, state, now: _now + 3);
    expect(job.manifest.assets.length, 1);
    expect(job.manifest.resources.length, 2);
    await _advance(client, state, job, media: _mediaDirectory([shared]));
    expect(job.status, BackupJobStatus.completed);
    expect(memory.requests.where((request) => request.method == 'PUT' && request.path.contains('/objects/')), isEmpty);
  });

  test('tampering carried records into a self-consistent job fails real remote reconstruction with zero PUT', () async {
    final memory = MemoryCos();
    _seed(memory, _session(moments: [_moment('old')]));
    final state = _session(moments: [_moment('new'), _moment('private', eligibility: UploadEligibility.localOnly)]);
    final client = memoryClient(memory, prefix: state.writerPrefix());
    final job = await BackupQueue.prepare(client, state, now: _now + 3);
    final privatePlan = BackupPlan.manifest(_session(moments: [_moment('private')]), now: _now);
    final manifest = job.manifest..moments.add(privatePlan.manifest.moments.single);
    final forged = _replaceManifest(job, manifest);
    memory.requests.clear();
    await expectLater(_advance(client, state, forged), throwsA(isA<CosFailure>()));
    expect(memory.requests.where((request) => request.method == 'PUT'), isEmpty);
  });

  test('local-only cannot be smuggled into the frozen local plan even when the full job hashes match', () async {
    final memory = MemoryCos();
    _seed(memory, _session(moments: [_moment('old')]));
    final state = _session(moments: [_moment('new'), _moment('private', eligibility: UploadEligibility.localOnly)]);
    final client = memoryClient(memory, prefix: state.writerPrefix());
    final job = await BackupQueue.prepare(client, state, now: _now + 3);
    final private = BackupPlan.manifest(_session(moments: [_moment('private')]), now: _now).manifest.moments.single;
    final local = job.localManifest..moments.add(private);
    final manifest = job.manifest..moments.add(private);
    final forged = _replaceManifest(job, manifest, local: local);
    memory.requests.clear();
    await expectLater(_advance(client, state, forged), throwsA(isA<CosFailure>()));
    expect(memory.requests.where((request) => request.method == 'PUT'), isEmpty);
  });

  test('a forged base hash cannot authorize carry-forward', () async {
    final memory = MemoryCos();
    _seed(memory, _session(moments: [_moment('old')]));
    final state = _session(moments: [_moment('new')]);
    final client = memoryClient(memory, prefix: state.writerPrefix());
    final job = await BackupQueue.prepare(client, state, now: _now + 3);
    final forged = _replaceManifest(job, job.manifest, parentHash: '0' * 64);
    memory.requests.clear();
    await expectLater(_advance(client, state, forged), throwsA(isA<CosFailure>()));
    expect(memory.requests.where((request) => request.method == 'PUT'), isEmpty);
  });

  test('frozen local payload survives pause, serialization and later local edits without an auto-backup loop', () async {
    final memory = MemoryCos();
    _seed(memory, _session(moments: [_moment('old')]));
    final media = _asset('new-paused');
    final state = _session(moments: [_moment('new', assets: [media])]);
    final client = memoryClient(memory, prefix: state.writerPrefix());
    final job = await BackupQueue.prepare(client, state, now: _now + 3);
    final root = _mediaDirectory([media]);
    var persisted = job.copy();
    await BackupQueue.advance(client, state, job,
        resolve: (path) => '${root.path}/$path', persist: (value) => persisted = value, shouldPause: () => persisted.completedCount >= 1);
    expect(job.status, BackupJobStatus.paused);
    final resumed = BackupJob.fromJson(jsonDecode(jsonEncode(persisted.toJson())))..resume();
    final frozen = resumed.localManifestBytes.toList();
    state.moments.single.title = 'edited while paused';
    await _advance(client, state, resumed, media: root);
    expect(resumed.status, BackupJobStatus.completed);
    expect(resumed.localManifestBytes, frozen);
    expect(resumed.matchesLocalPlan(BackupPlan.manifest(state, now: _now + 4)), isFalse);
    final fresh = await BackupQueue.prepare(client, state, now: _now + 4);
    await _advance(client, state, fresh, media: root);
    expect(fresh.matchesLocalPlan(BackupPlan.manifest(state, now: _now + 5)), isTrue);
    expect(fresh.manifestBytes, isNot(fresh.localManifestBytes));
    final puts = memory.requests.where((request) => request.method == 'PUT').length;
    final duplicate = await BackupQueue.prepare(client, state, now: _now + 5);
    expect(duplicate.status, BackupJobStatus.completed);
    expect(duplicate.commit.sequence, fresh.commit.sequence);
    expect(duplicate.matchesLocalPlan(BackupPlan.manifest(state, now: _now + 6)), isTrue);
    await _advance(client, state, duplicate, media: root);
    expect(memory.requests.where((request) => request.method == 'PUT').length, puts);
  });

  test('the exact already-published job completes after a lost response with no additional PUT', () async {
    final memory = _LostCommitResponse();
    _seed(memory, _session(moments: [_moment('old')]));
    final state = _session(moments: [_moment('new')]);
    final client = memoryClient(memory, prefix: state.writerPrefix());
    final job = await BackupQueue.prepare(client, state, now: _now + 3);
    await expectLater(_advance(client, state, job), throwsA(isA<SocketException>()));
    expect(job.status, BackupJobStatus.failed);
    final resumed = BackupJob.fromJson(jsonDecode(jsonEncode(job.toJson())))..resume();
    memory.requests.clear();
    await _advance(client, state, resumed);
    expect(resumed.status, BackupJobStatus.completed);
    expect(resumed.progress, 1);
    expect(memory.requests.where((request) => request.method == 'PUT'), isEmpty);
  });

  test('forging a completed local fingerprint cannot mark unpublished records as backed up', () async {
    final memory = MemoryCos();
    final state = _session(moments: [_moment('published')]);
    final client = memoryClient(memory, prefix: state.writerPrefix());
    final published = await BackupQueue.prepare(client, state, now: _now);
    await _advance(client, state, published);
    state.moments.add(_moment('unpublished'));
    final current = BackupPlan.manifest(state, now: _now + 1);
    for (final status in ['completed', 'queued']) {
      final json = published.toJson()
        ..['localManifestBytes'] = base64.encode(current.bytes)
        ..['status'] = status;
      final forged = BackupJob.fromJson(json);
      expect(forged.matchesLocalPlan(current), isFalse);
      memory.requests.clear();
      await expectLater(_advance(client, state, forged), throwsA(isA<CosFailure>()));
      expect(memory.requests.where((request) => request.method == 'PUT'), isEmpty);
    }
    final invalid = BackupJob.fromJson(published.toJson()
      ..['localManifestBytes'] = base64.encode(current.bytes)
      ..['manifestBytes'] = base64.encode(utf8.encode('invalid')));
    expect(invalid.matchesLocalPlan(current), isFalse);
  });

  test('a changed remote head rejects a frozen job before any PUT without altering that head', () async {
    final memory = MemoryCos();
    _seed(memory, _session(moments: [_moment('old')]));
    final state = _session(moments: [_moment('new')]);
    final client = memoryClient(memory, prefix: state.writerPrefix());
    final stale = await BackupQueue.prepare(client, state, now: _now + 3, requestID: uuid(910));
    final concurrentState = _session(moments: [_moment('concurrent')]);
    final concurrent = await BackupQueue.prepare(client, concurrentState, now: _now + 4, requestID: uuid(911));
    await _advance(client, concurrentState, concurrent);
    final headBytes = memory.objects[concurrent.commitKey]!.toList();
    memory.requests.clear();
    await expectLater(_advance(client, state, stale), throwsA(isA<CosFailure>()));
    expect(memory.requests.where((request) => request.method == 'PUT'), isEmpty);
    expect(memory.objects[concurrent.commitKey], headBytes);
    expect((await FamilyReader.latest(client, state.writerPrefix()))!.manifest.moments.map((record) => record.title).toSet(), {'old', 'concurrent'});
  });

  test('a concurrent publication between snapshot and commit is preserved without publishing the stale commit', () async {
    final memory = MemoryCos();
    _seed(memory, _session(moments: [_moment('old')]));
    final state = _session(moments: [_moment('stale-new')]);
    final client = memoryClient(memory, prefix: state.writerPrefix());
    final stale = await BackupQueue.prepare(client, state, now: _now + 3, requestID: uuid(920));
    final concurrentState = _session(moments: [_moment('concurrent-new')]);
    final concurrent = await BackupQueue.prepare(client, concurrentState, now: _now + 4, requestID: uuid(921));
    var publishedConcurrent = false;
    await expectLater(
      BackupQueue.advance(client, state, stale,
          resolve: (_) => throw StateError('Text only'),
          persist: (checkpoint) async {
            if (checkpoint.snapshotUploaded && !publishedConcurrent) {
              publishedConcurrent = true;
              await _advance(client, concurrentState, concurrent);
            }
          }),
      throwsA(isA<CosFailure>()),
    );
    expect(publishedConcurrent, isTrue);
    expect(stale.status, BackupJobStatus.failed);
    expect(memory.objects[stale.commitKey], concurrent.commitBytes);
    final commitPuts = memory.requests.where((request) => request.method == 'PUT' && request.path.contains('/commits/'));
    expect(commitPuts.length, 1);
    expect(commitPuts.single.body, concurrent.commitBytes);
    expect((await FamilyReader.latest(client, state.writerPrefix()))!.manifest.moments.map((record) => record.title).toSet(), {'old', 'concurrent-new'});
  });

  test('legacy queued jobs fail closed when their old local-only snapshot would drop the real base', () async {
    final memory = MemoryCos();
    _seed(memory, _session(moments: [_moment('old')]));
    final state = _session(moments: [_moment('new')]);
    final client = memoryClient(memory, prefix: state.writerPrefix());
    final planned = await BackupQueue.prepare(client, state, now: _now + 3);
    final oldFormat = _replaceManifest(planned, planned.localManifest).toJson()..remove('localManifestBytes');
    final legacy = BackupJob.fromJson(oldFormat);
    memory.requests.clear();
    await expectLater(_advance(client, state, legacy), throwsA(isA<CosFailure>()));
    expect(memory.requests.where((request) => request.method == 'PUT'), isEmpty);
    expect((await FamilyReader.latest(client, state.writerPrefix()))!.commit.sequence, 1);
  });

  test('legacy first publications and already-completed jobs remain compatible', () async {
    final memory = MemoryCos();
    final state = _session(moments: [_moment('first')]);
    final client = memoryClient(memory, prefix: state.writerPrefix());
    final planned = await BackupQueue.prepare(client, state, now: _now);
    final json = planned.toJson()..remove('localManifestBytes');
    final legacy = BackupJob.fromJson(json);
    await _advance(client, state, legacy);
    expect(legacy.status, BackupJobStatus.completed);
    memory.requests.clear();
    await _advance(client, state, BackupJob.fromJson(legacy.toJson()..remove('localManifestBytes')));
    expect(memory.requests.where((request) => request.method == 'PUT'), isEmpty);
  });
}
