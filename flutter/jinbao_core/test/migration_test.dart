import 'dart:convert';
import 'dart:io';

import 'package:jinbao_core/jinbao_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Port of MigrationTests.swift, UploadEligibilityTests.swift and MigrationWireBoundsTests.swift.
void main() {
  const device = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
  const now = 1792382400000;
  const verified = CloudVerified(bucket: 'example-1234567890', region: 'ap-shanghai');
  const placeholder = CloudPlaceholder(bucket: 'example-1234567890', region: 'ap-shanghai');

  AppSession session({bool test = true, CloudLink link = verified, List<LocalMoment>? moments}) =>
      AppSession(deviceID: device, testBuild: test, identity: ParentIdentity.dad, link: link, moments: moments);

  LocalAsset asset(String name, {int capturedAt = 0, CaptureMetadata? metadata}) => LocalAsset(
        id: name,
        kind: 'photo',
        capturedAt: capturedAt,
        provenance: 'systemProvided',
        captureMetadata: metadata,
        resources: [
          for (final role in ['photo', 'preview'])
            LocalResource(
              id: name + role,
              role: role,
              contentType: 'image/jpeg',
              originalFilename: '$name$role.jpg',
              byteCount: utf8.encode(name + role).length,
              sha256: Digest.sha256Hex(utf8.encode(name + role)),
              relativePath: 'media/$name$role.jpg',
            ),
        ],
      );

  LocalMoment save(AppSession state, {String text = 'Record', List<LocalAsset> assets = const []}) {
    state.beginDraft(now: now);
    state.updateDraft(title: text, note: 'Synthetic');
    state.addAssets(assets);
    return state.commitDraft(now: now);
  }

  Directory tempDirectory() {
    final directory = Directory.systemTemp.createTempSync('migration-tests-');
    addTearDown(() => directory.deleteSync(recursive: true));
    return directory;
  }

  void writeMedia(List<LocalAsset> assets, Directory root) {
    for (final item in assets) {
      for (final resource in item.resources) {
        File('${root.path}/${resource.relativePath}')
          ..createSync(recursive: true)
          ..writeAsBytesSync(utf8.encode(item.id + resource.role));
      }
    }
  }

  test('initial batch uses earliest time; manual and append never overwrite', () {
    final state = session();
    state.beginDraft(now: now);
    state.addAssets([asset('later', capturedAt: now - 1000), asset('earlier', capturedAt: now - 2000)]);
    expect(state.draft!.occurredAt, now - 2000);
    state.addAssets([asset('muchOlder', capturedAt: now - 9999)]);
    expect(state.draft!.occurredAt, now - 2000);
    state.setDraftOccurredAt(now - 1234);
    expect(state.draft!.occurredAtIsEstimated, isFalse);
    state.removeAsset('earlier');
    state.addAssets([asset('oldest', capturedAt: now - 99999)]);
    expect(state.draft!.occurredAt, now - 1234);
    state.discardDraft();
    state.beginDraft(now: now);
    state.setDraftOccurredAt(now + 111);
    state.addAssets([asset('p', capturedAt: now - 222)]);
    expect(state.draft!.occurredAt, now + 111);
  });

  test('unknown zone uses estimated form time without fabricating an asset timestamp', () {
    final state = session();
    state.beginDraft(now: now);
    state.addAssets([
      asset('zone',
          metadata: CaptureMetadata(source: 'exifLocalTime', localDateTime: '2026-10-18 12:34:56', isEstimated: true))
    ], zone: const FixedOffsetZone(8 * 60));
    expect(state.draft!.occurredAt, DateTime.utc(2026, 10, 18, 4, 34, 56).millisecondsSinceEpoch);
    expect(state.draft!.assets.first.capturedAt, 0);
    expect(state.draft!.occurredAtIsEstimated, isTrue);
    expect(state.copy().draft, state.draft);
  });

  test('missing metadata leaves default time and marks estimated only on import', () {
    final state = session();
    state.beginDraft(now: now);
    expect(state.draft!.occurredAtIsEstimated, isFalse);
    state.addAssets([asset('missing')]);
    expect(state.draft!.occurredAt, now);
    expect(state.draft!.occurredAtIsEstimated, isTrue);
    state.addAssets([asset('next', capturedAt: now - 999)]);
    expect(state.draft!.occurredAt, now);
  });

  test('draft resume, edit with stable id and baseline, idempotent commit', () {
    final state = session();
    state.beginDraft(now: now);
    state.updateDraft(title: 'Original', note: 'Do not discard');
    final firstDraft = state.draft!.copy();
    state.beginDraft(now: now + 123);
    expect(state.draft, firstDraft);
    final original = state.commitDraft(now: now);
    state.draft = firstDraft.copy(); // A repeated transaction after restoring a stale UI payload.
    expect(state.commitDraft(now: now + 99), original);
    expect(state.moments.length, 1);
    state.beginEdit(id: original.id, now: now + 1);
    state.updateDraft(title: 'Edited', note: 'Kept identity');
    final edited = state.commitDraft(now: now + 1);
    expect(edited.id, original.id);
    expect(edited.createdAt, original.createdAt);
    expect(edited.revision, original.revision + 1);
    expect(state.moments.length, 1);
    state.beginEdit(id: original.id, now: now + 2);
    state.trashMoment(id: original.id, now: now + 3);
    expect(() => state.commitDraft(now: now + 4), throwsA(isA<ContractError>()));
    expect(state.draft, isNotNull);
  });

  test('editing another record keeps the draft and never promotes local-only', () {
    final state = session(link: placeholder);
    final privateMoment = save(state);
    state.link = verified;
    final other = save(state, text: 'Other');
    state.beginEdit(id: privateMoment.id, now: now);
    final draft = state.draft!.copy();
    expect(() => state.beginEdit(id: other.id, now: now), throwsA(isA<ContractError>()));
    expect(state.draft, draft);
    state.updateDraft(title: 'Updated locally', note: 'Private');
    expect(state.commitDraft(now: now + 1).uploadEligibility, UploadEligibility.localOnly);
    expect(() => state.beginEdit(id: 'remote:dad:record:example', now: now), throwsA(isA<ContractError>()));
  });

  test('thirty media limit, batch atomicity and reorder', () {
    final state = session();
    state.beginDraft(now: now);
    state.addAssets([for (var i = 0; i < 30; i++) asset('p$i')]);
    expect(() => state.addAssets([asset('extra')]), throwsA(isA<ContractError>()));
    expect(state.draft!.assets.length, 30);
    state.moveAsset(from: 0, to: 29);
    expect(state.draft!.assets.last.id, 'p0');
    expect(() => state.moveAsset(from: 99, to: 0), throwsA(isA<ContractError>()));
    state.removeAsset('p0');
    final before = state.draft!.copy();
    expect(() => state.addAssets([asset('p1')]), throwsA(isA<ContractError>()));
    expect(state.draft, before);
  });

  test('trash backs up a tombstone; restore publishes a new revision', () {
    final state = session();
    final original = save(state, assets: [asset('shared')]);
    state.trashMoment(id: original.id, now: now + 1);
    expect(state.timelineEntries(), isEmpty);
    final deleted = BackupPlan.manifest(state, now: now + 1).manifest;
    expect(deleted.moments.first.trashedAt, now + 1);
    expect(deleted.resources.length, 2);
    expect(BackupPlan.uploads(state).length, 2);
    state.restoreMoment(id: original.id, now: now + 2);
    final restored = BackupPlan.manifest(state, now: now + 2).manifest;
    expect(restored.moments.first.trashedAt, isNull);
    expect(restored.moments.first.revision, original.revision + 2);
    expect(restored.resources, deleted.resources);
  });

  test('corrupt archive never resets; explicit recovery preserves bytes', () {
    final root = tempDirectory();
    final store = ArchiveStore('${root.path}/archive.json');
    expect(store.load(), isNull);
    final state = session();
    save(state);
    store.save(PersistedArchive.fromSession(state));
    state.beginDraft(now: now);
    state.updateDraft(title: 'New draft', note: 'Recoverable');
    store.save(PersistedArchive.fromSession(state));
    final corrupt = utf8.encode('{corrupt');
    File(store.path).writeAsBytesSync(corrupt);
    expect(() => store.load(), throwsA(isA<ContractError>()));
    expect(() => store.save(PersistedArchive.fromSession(session())), throwsA(isA<ContractError>()));
    expect(File(store.path).readAsBytesSync(), corrupt);
    final restored = store.restoreRecovery();
    expect(restored.moments.length, 1);
    expect(restored.draft, isNull);
    final quarantined = root.listSync().whereType<File>().firstWhere((f) => f.path.contains('.unreadable-'));
    expect(quarantined.readAsBytesSync(), corrupt);
    expect(store.load(), restored);
  });

  test('missing primary with recovery never creates an empty archive', () {
    final root = tempDirectory();
    final store = ArchiveStore('${root.path}/archive.json');
    final state = session();
    save(state);
    store.save(PersistedArchive.fromSession(state));
    File(store.path).deleteSync();
    expect(() => store.load(), throwsA(isA<ContractError>()));
    expect(() => store.save(PersistedArchive.fromSession(session())), throwsA(isA<ContractError>()));
    expect(store.restoreRecovery().moments.length, 1);
    expect(store.load()!.moments.length, 1);
  });

  test('future archive and identity change are rejected without replacing the primary', () {
    final root = tempDirectory();
    final store = ArchiveStore('${root.path}/archive.json');
    final state = session();
    store.save(PersistedArchive.fromSession(state));
    final original = File(store.path).readAsBytesSync();
    final wrong = state.copy()..identity = ParentIdentity.mom;
    expect(() => store.save(PersistedArchive.fromSession(wrong)), throwsA(isA<ContractError>()));
    expect(File(store.path).readAsBytesSync(), original);
    final json = jsonDecode(utf8.decode(original)) as Map<String, Object?>;
    json['schemaVersion'] = 999;
    final future = utf8.encode(jsonEncode(json));
    File(store.path).writeAsBytesSync(future);
    expect(() => store.load(), throwsA(isA<ContractError>()));
    expect(() => store.save(PersistedArchive.fromSession(state)), throwsA(isA<ContractError>()));
    expect(File(store.path).readAsBytesSync(), future);
  });

  test('legacy iOS archive (Swift Codable JSON) migrates and fails closed', () {
    // Shape written by the Swift app: `\/` escapes, Base64-free, keys missing in old versions.
    final legacy = r'''{"deviceID":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","testBuild":false,"identityFolder":"dad",
      "link":{"verified":{"bucket":"example-1234567890","region":"ap-shanghai"}},
      "moments":[{"id":"M1","title":"Old","note":"Kept","occurredAt":1,"createdAt":1,"updatedAt":1,"revision":1,
        "parent":"dad","assets":[{"id":"A1","kind":"photo","capturedAt":0,"resources":[{"id":"R1","role":"photo",
        "contentType":"image\/jpeg","originalFilename":"a.jpg","byteCount":1,"sha256":"aa","relativePath":"media\/a.jpg"}]}]}],
      "draft":{"title":"Legacy draft","note":"Keep","occurredAt":5,"assets":[]}}''';
    final restored = PersistedArchive.fromJson(jsonDecode(legacy)).session();
    expect(restored.moments.single.uploadEligibility, UploadEligibility.localOnly);
    expect(restored.moments.single.assets.single.resources.single.relativePath, 'media/a.jpg');
    expect(restored.draft!.uploadEligibility, UploadEligibility.localOnly);
    expect(restored.draft!.timeWasEdited, isTrue);
    restored.addAssets([asset('old', capturedAt: now - 999)]);
    expect(restored.draft!.occurredAt, 5);
    expect(() => BackupPlan.manifest(restored, now: now), throwsA(isA<ContractError>()));
  });

  test('unknown eligibility values fail closed to local-only', () {
    final state = session(test: false, moments: [
      LocalMoment(
          id: 'legacy',
          title: 't',
          note: 'n',
          occurredAt: now,
          createdAt: now,
          updatedAt: now,
          parent: ParentIdentity.dad,
          assets: [asset('legacy')],
          uploadEligibility: UploadEligibility.eligible)
    ]);
    final json = PersistedArchive.fromSession(state).toJson();
    for (final value in [null, 'eligible', 'futureEligibility', 123, {'state': 'eligible'}]) {
      final moments = (jsonDecode(jsonEncode(json['moments'])) as List).cast<Map<String, Object?>>();
      moments[0]['uploadEligibility'] = value;
      final changed = Map<String, Object?>.of(json)..['moments'] = moments;
      final restored = PersistedArchive.fromJson(changed).session();
      expect(restored.moments[0].uploadEligibility, UploadEligibility.localOnly);
      expect(restored.moments[0].assets, state.moments[0].assets);
    }
  });

  test('placeholder records stay local after verification', () {
    final state = session(link: placeholder);
    state.beginDraft(now: now);
    state.updateDraft(title: 'Private title', note: 'Private text');
    state.commitDraft(now: now);
    state.connectVerified(bucket: 'example-1234567890', region: 'ap-shanghai');
    expect(state.moments.single.uploadEligibility, UploadEligibility.localOnly);
    expect(() => BackupPlan.manifest(state, now: now), throwsA(isA<ContractError>()));
  });

  test('local-only publish makes zero transport requests', () async {
    final state = session(moments: [
      LocalMoment(
          id: 'private',
          title: 't',
          note: 'n',
          occurredAt: now,
          createdAt: now,
          updatedAt: now,
          parent: ParentIdentity.dad,
          assets: [asset('private')])
    ]);
    final memory = MemoryCos();
    final error = await throwsOf(() => BackupPublisher.publishBytes(memoryClient(memory, prefix: state.writerPrefix()),
        state, files: {}, now: now, requestID: uuid(4)));
    expect(error, const ContractError('backup', '没有可备份的记录。'));
    expect(memory.requests, isEmpty);
  });

  test('anniversary defaults are virtual and placeholder overrides stay local', () {
    final state = session();
    expect(state.anniversaryEntries().length, 3);
    expect(() => BackupPlan.manifest(state, now: now), throwsA(isA<ContractError>()));
    state.link = placeholder;
    final birthday = AnniversaryCalendar.defaults[1];
    state.saveAnniversary(id: birthday.id, title: '示例纪念日', date: '--02-14', now: now);
    state.deleteAnniversary(id: AnniversaryCalendar.defaults[2].id, now: now);
    state.link = verified;
    expect(state.anniversaryEntries().length, 2);
    expect(state.anniversaryEntries().firstWhere((e) => e.id == birthday.id).date, '0004-02-14');
    expect(state.backupAnniversaries(), isEmpty);
    final real = state.saveAnniversary(title: '新纪念', date: '2026-10-19', now: now);
    expect(BackupPlan.manifest(state, now: now).manifest.anniversaries.map((a) => a.id), [real.id]);
    state.deleteAnniversary(id: real.id, now: now + 5);
    expect(state.backupAnniversaries().first.deletedAt, now + 5);
  });

  test('anniversary validation, countdown, leap day and unknown year', () {
    expect(() => AnniversaryCalendar.normalizedDate('2026-02-30'), throwsA(isA<ContractError>()));
    expect(() => AnniversaryCalendar.normalizedDate('--13-01'), throwsA(isA<ContractError>()));
    expect(AnniversaryCalendar.normalizedDate('--02-29'), '0004-02-29');
    const entry =
        AnniversaryEntry(id: 'leap', title: 'Leap', date: '0004-02-29', owner: ParentIdentity.dad, readOnly: false);
    final upcoming = AnniversaryCalendar.upcoming([entry],
            now: DateTime.utc(2027, 2, 27, 12).millisecondsSinceEpoch, zone: FixedOffsetZone.utc)
        .first;
    expect(upcoming.daysUntil, 1);
    expect(upcoming.years, isNull);
    expect(upcoming.shouldRemind, isTrue);
  });

  test('family merge includes remote originals and anniversary tombstones', () {
    final state = session(test: false);
    final original = save(state, assets: [asset('family')]);
    final anniversary = state.saveAnniversary(title: 'Family day', date: '--10-19', now: now);
    final first = BackupPlan.manifest(state, now: now);
    state.deleteAnniversary(id: anniversary.id, now: now + 1);
    final latest = BackupPlan.manifest(state, now: now + 1);
    final sources = [
      ChainSnapshot(parent: ParentIdentity.dad, prefix: first.prefix, writer: device, createdAt: now, manifest: first.manifest),
      ChainSnapshot(
          parent: ParentIdentity.dad, prefix: latest.prefix, writer: device, createdAt: now + 1, manifest: latest.manifest),
    ];
    final merged = ArchiveMerge.merge(sources).first;
    expect(merged.id, ArchiveMerge.remoteID(ParentIdentity.dad, original.id));
    expect(merged.media.first.resources.length, 2);
    merged.media.first.resources.first.validate();
    expect(ArchiveMerge.mergeAnniversaries(sources).first.deletedAt, now + 1);
    expect(RemoteMoment.fromJson(jsonDecode(jsonEncode(merged.toJson()))), merged);
  });

  test('backup queue pause, round trip, resume and duplicate make no extra commit', () async {
    final state = session();
    final media = [asset('first'), asset('second')];
    save(state, assets: media);
    final root = tempDirectory();
    writeMedia(media, root);
    final memory = MemoryCos();
    final writer = memoryClient(memory, prefix: state.writerPrefix());
    final job = await BackupQueue.prepare(writer, state, now: now);
    final frozen = job.manifestBytes;
    var persisted = job.copy();
    await BackupQueue.advance(writer, state, job,
        resolve: (path) => '${root.path}/$path',
        persist: (value) => persisted = value,
        shouldPause: () => persisted.completedCount >= 1);
    expect(job.status, BackupJobStatus.paused);
    expect(job.completedCount, 1);
    expect(memory.objects.keys.any((k) => k.contains('/commits/')), isFalse);
    final resumed = BackupJob.fromJson(jsonDecode(jsonEncode(persisted.toJson())))..resume();
    await BackupQueue.advance(writer, state, resumed,
        resolve: (path) => '${root.path}/$path', persist: (value) => persisted = value);
    expect(resumed.status, BackupJobStatus.completed);
    expect(resumed.manifestBytes, frozen);
    expect(resumed.progress, 1);
    expect(memory.requests.where((r) => r.method == 'PUT' && r.path.contains('/objects/')).length, 4);
    expect(memory.requests.where((r) => r.method == 'PUT' && r.path.contains('/commits/')).length, 1);
    final unchanged = await BackupQueue.prepare(writer, state, now: now + 1);
    expect(unchanged.status, BackupJobStatus.completed);
    expect(memory.requests.where((r) => r.method == 'PUT').every((r) => r.path.startsWith('/life/v1/test/')), isTrue);
  });

  test('backup queue stops before publication when persist fails', () async {
    final state = session();
    save(state);
    final memory = MemoryCos();
    final writer = memoryClient(memory, prefix: state.writerPrefix());
    final job = await BackupQueue.prepare(writer, state, now: now);
    final error = await throwsOf(() => BackupQueue.advance(writer, state, job,
        resolve: (_) => throw const CosFailure(ConnectionFailure.notFound),
        persist: (_) => throw const CosFailure(ConnectionFailure.secureStorage)));
    expect(error, const CosFailure(ConnectionFailure.secureStorage));
    expect(memory.requests.every((r) => r.method != 'PUT'), isTrue);
    expect(job.status, BackupJobStatus.failed);
  });

  test('filename truncation uses UTF-16 and never splits emoji or combined characters', () {
    final exact = '${'😀' * 127}a';
    expect(exact.length, 255);
    expect(BackupPlan.safeFilename(exact), exact);
    final result = BackupPlan.safeFilename('${'😀' * 128}.jpg');
    expect(result, '😀' * 127);
    expect(BackupPlan.safeFilename('${'a' * 250}👨‍👩‍👧‍👦'), 'a' * 250);
    expect(BackupPlan.safeFilename('${'a' * 254}é'), 'a' * 254);
    expect(BackupPlan.safeFilename('a${'́' * 300}'), 'import');
    expect(BackupPlan.safeFilename(''), 'import');
  });

  test('versioning gate accepts only a strict empty configuration', () async {
    const acceptable = [
      '<VersioningConfiguration/>',
      '<?xml version="1.0" encoding="UTF-8"?><VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\n </VersioningConfiguration>',
    ];
    for (final xml in acceptable) {
      final memory = MemoryCos()..versioningBody = xml;
      await memoryClient(memory, prefix: 'life/v1/test/').verifyImmutableWritesAllowed();
    }
    const rejected = [
      '', '<VersioningConfiguration>', '<VersioningConfiguration/><unexpected/>',
      '<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>',
      '<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>',
      '<VersioningConfiguration><Status/></VersioningConfiguration>',
      '<VersioningConfiguration><Future/></VersioningConfiguration>',
      '<VersioningConfiguration future="true"/>',
      '<VersioningConfiguration xmlns="https://unexpected.example"/>',
      '<VersioningConfiguration>Suspended</VersioningConfiguration>',
      '<VersioningConfiguration><![CDATA[ ]]></VersioningConfiguration>',
      '<!DOCTYPE VersioningConfiguration><VersioningConfiguration/>',
      '<ListBucketResult/>',
    ];
    for (final xml in rejected) {
      final memory = MemoryCos()..versioningBody = xml;
      final error = await throwsOf(() => memoryClient(memory, prefix: 'life/v1/test/')
          .putImmutable(key: 'life/v1/test/snapshots/check.json', body: utf8.encode('{}'), contentType: 'application/json'));
      expect(error, const CosFailure(ConnectionFailure.unsafeVersioning), reason: xml);
      expect(memory.requests.any((r) => r.method == 'PUT'), isFalse, reason: xml);
    }
    final denied = MemoryCos()..versioningStatus = 403;
    expect(await throwsOf(() => memoryClient(denied, prefix: 'life/v1/test/').verifyImmutableWritesAllowed()),
        const CosFailure(ConnectionFailure.permission));
  });

  test('large file upload streams from a staged copy and getFile verifies the hash', () async {
    final root = tempDirectory();
    final bytes = List<int>.generate(3 * 1024 * 1024 + 7, (i) => i % 251);
    final source = File('${root.path}/big.bin')..writeAsBytesSync(bytes);
    final hash = Digest.sha256Hex(bytes);
    const prefix = 'life/v1/test/';
    final memory = MemoryCos();
    final client = memoryClient(memory, prefix: prefix);
    final key = V1Layout.objectKey(prefix: prefix, sha256: hash);
    await client.putImmutableFile(
        key: key, filePath: source.path, byteCount: bytes.length, sha256: hash, contentType: 'video/mp4');
    expect(memory.objects[key], bytes);
    final wrong = await throwsOf(() => client.putImmutableFile(
        key: key, filePath: source.path, byteCount: bytes.length - 1, sha256: hash, contentType: 'video/mp4'));
    expect(wrong, const CosFailure(ConnectionFailure.contentMismatch));
    final destination = '${root.path}/cache/copy.bin';
    await client.getFile(key: key, destination: destination, byteCount: bytes.length, sha256: hash);
    expect(File(destination).readAsBytesSync(), bytes);
  });
}
