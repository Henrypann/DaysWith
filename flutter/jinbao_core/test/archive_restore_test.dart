import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jinbao_core/jinbao_core.dart';
import 'package:test/test.dart';

import 'support.dart' show uuid;

class _RestoreStorage extends StorageProvider {
  final objects = <String, Uint8List>{};
  final downloads = <String>[];
  bool corruptDownload = false;
  Future<void> Function()? beforeDownload;

  @override
  StorageIdentity get identity => const StorageIdentity(
    providerId: 'fixture',
    endpoint: 'https://nas.example.test/dayswith/',
    prefix: 'life/v1/',
  );
  @override
  StorageCapabilities get capabilities => const StorageCapabilities(
    conditionalWrites: true,
    versioning: StorageVersioning.unsupported,
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
  }) async => StorageListPage(objects.keys.where((k) => k.startsWith(prefix)));
  @override
  Future<ObjectHead?> stat(String key) async => objects[key] == null
      ? null
      : ObjectHead(byteCount: objects[key]!.length, sha256: null);
  @override
  Future<Uint8List> get({
    required String key,
    int responseLimit = 32 * 1024 * 1024,
  }) async {
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
    downloads.add(key);
    await beforeDownload?.call();
    final bytes = await get(key: key, responseLimit: byteCount);
    final file = File(destination);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(
      corruptDownload ? List.filled(bytes.length, 255) : bytes,
      flush: true,
    );
  }

  @override
  Future<void> putImmutable({
    required String key,
    required List<int> body,
    required String contentType,
  }) async => throw StateError('Restore must not upload.');
  @override
  Future<void> putImmutableFile({
    required String key,
    required String filePath,
    required int byteCount,
    required String sha256,
    required String contentType,
  }) async => throw StateError('Restore must not upload.');
}

const _time = 1700000000000;
String _prefix(ParentIdentity parent, int writer) =>
    'life/v1/${parent.folder}/${uuid(writer).toLowerCase()}/';

V1Manifest _publish(
  _RestoreStorage storage,
  ParentIdentity parent,
  int writer, {
  int photoCount = 0,
  bool video = false,
  int record = 10,
  int updatedAt = _time,
}) {
  final prefix = _prefix(parent, writer);
  final assets = <V1Asset>[];
  final resources = <V1Resource>[];
  for (var i = 0; i < photoCount + (video ? 1 : 0); i++) {
    final isVideo = i >= photoCount;
    final assetID = uuid(100 + i);
    final originalID = uuid(1000 + i * 2);
    final previewID = uuid(1001 + i * 2);
    // Distinct byte vectors exercise complete-copy/hash contracts. They are not
    // decoded images or a real video playback/device acceptance fixture.
    for (final preview in [false, true]) {
      final bytes = Uint8List.fromList(
        utf8.encode(
          '${parent.folder}:$writer:$i:${preview ? 'preview' : 'original'}',
        ),
      );
      final hash = Digest.sha256Hex(bytes);
      final key = V1Layout.objectKey(prefix: prefix, sha256: hash);
      storage.objects[key] = bytes;
      resources.add(
        V1Resource(
          id: preview ? previewID : originalID,
          assetID: assetID,
          role: preview ? 'preview' : (isVideo ? 'video' : 'photo'),
          contentType: preview || !isVideo ? 'image/jpeg' : 'video/mp4',
          originalFilename: preview
              ? 'preview-$i.jpg'
              : 'original-$i.${isVideo ? 'mp4' : 'jpg'}',
          byteCount: bytes.length,
          sha256: hash,
          objectKey: key,
        ),
      );
    }
    assets.add(
      V1Asset(
        id: assetID,
        kind: isVideo ? 'video' : 'photo',
        capturedAt: _time,
        resourceIDs: [originalID, previewID],
        importProvenance: 'verifiedOriginal',
      ),
    );
  }
  final manifest = V1Manifest(
    version: 2,
    moments: [
      V1Moment(
        id: uuid(record),
        title: '${parent.label}成长记录',
        note: '完整恢复文字',
        occurredAt: _time,
        createdAt: _time,
        updatedAt: updatedAt,
        revision: 2,
        assetIDs: assets.map((a) => a.id).toList(),
      ),
    ],
    assets: assets,
    resources: resources,
    anniversaries: [
      V1Anniversary(
        id: uuid(200 + parent.index),
        owner: parent,
        title: '${parent.label}纪念日',
        date: '2020-02-29',
      ),
    ],
  );
  V1Validator.validate(manifest: manifest, prefix: prefix);
  final bytes = V1Json.encodeManifest(manifest);
  final hash = Digest.sha256Hex(bytes);
  final commit = V1Commit(
    sequence: 1,
    writerDeviceID: uuid(writer),
    manifestHash: hash,
    manifestKey: '${prefix}snapshots/$hash.json',
    createdAt: updatedAt,
    requestID: uuid(300 + writer),
  );
  storage.objects[commit.manifestKey] = bytes;
  storage.objects[prefix + V1Json.commitRelativeKey(1)] = V1Json.encodeCommit(
    commit,
  );
  return manifest;
}

void main() {
  late Directory sandbox;
  late _RestoreStorage storage;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('dayswith-restore-test-');
    storage = _RestoreStorage();
  });
  tearDown(() async => sandbox.delete(recursive: true));

  test('10 photo and one video vectors recover all originals, text, dates and ownership', () async {
    final manifest = _publish(
      storage,
      ParentIdentity.dad,
      1,
      photoCount: 10,
      video: true,
    );
    _publish(storage, ParentIdentity.mom, 2, record: 20);
    final before = {
      for (final e in storage.objects.entries) e.key: Digest.sha256Hex(e.value),
    };
    final result = await ArchiveRestore.restore(
      storage,
      destination: '${sandbox.path}/recovered',
      owner: ParentIdentity.dad,
      deviceID: uuid(99),
      editableSourcePrefix: _prefix(ParentIdentity.dad, 1),
      chains: [
        RestoreChain(
          parent: ParentIdentity.dad,
          prefix: _prefix(ParentIdentity.dad, 1),
        ),
        RestoreChain(
          parent: ParentIdentity.mom,
          prefix: _prefix(ParentIdentity.mom, 2),
        ),
      ],
    );
    final session = ArchiveStore(result.archivePath).load()!.session();
    expect(result.verifiedObjectCount, 22);
    expect(result.originalResourceCount, 11);
    expect(storage.downloads.length, 22);
    expect(session.link, isA<CloudMissing>());
    expect(session.deviceID, uuid(99));
    expect(session.moments.single.id, manifest.moments.single.id);
    expect(session.moments.single.note, '完整恢复文字');
    expect(
      session.moments.single.uploadEligibility,
      UploadEligibility.localOnly,
    );
    expect(session.moments.single.assets.length, 11);
    expect(
      session.moments.single.assets.where((a) => a.kind == 'video').length,
      1,
    );
    for (final resource in session.moments.single.assets.expand(
      (a) => a.resources,
    )) {
      final digest = await Digest.sha256File(
        '${result.directory}/${resource.relativePath}',
        maximumBytes: resource.byteCount,
      );
      expect(digest, (hash: resource.sha256, byteCount: resource.byteCount));
    }
    final ownEntry = session.timelineEntries().firstWhere(
      (e) => e.parent == ParentIdentity.dad,
    );
    final foreignEntry = session.timelineEntries().firstWhere(
      (e) => e.parent == ParentIdentity.mom,
    );
    expect(ownEntry.readOnly, isFalse);
    expect(foreignEntry.readOnly, isTrue);
    expect(session.anniversaries.single.date, '2020-02-29');
    expect(session.remoteAnniversaries.single.owner, ParentIdentity.mom);
    expect(result.sources.map((s) => s.writerDeviceID).toSet(), {
      uuid(1),
      uuid(2),
    });
    expect(result.requiresConnectionAndOwnershipReview, isTrue);
    expect(File('${result.directory}/sources/1.json').existsSync(), isTrue);
    final receipt = jsonDecode(
      File('${result.directory}/restore-receipt.json').readAsStringSync(),
    ) as Map;
    expect(receipt['version'], 1);
    expect(receipt['sources'], hasLength(2));
    expect({
      for (final e in storage.objects.entries) e.key: Digest.sha256Hex(e.value),
    }, before);
  });

  test(
    'default restoration never claims edit authority even for the same parent',
    () async {
      _publish(storage, ParentIdentity.dad, 1, photoCount: 1);
      final result = await ArchiveRestore.restore(
        storage,
        destination: '${sandbox.path}/read-only',
        owner: ParentIdentity.dad,
        deviceID: uuid(99),
        chains: [
          RestoreChain(
            parent: ParentIdentity.dad,
            prefix: _prefix(ParentIdentity.dad, 1),
          ),
        ],
      );
      expect(result.session.moments, isEmpty);
      expect(result.session.remote.single.readOnly, isTrue);
      expect(result.session.timelineEntries().single.readOnly, isTrue);
      final resource = result.session.remote.single.media.single.resources
          .firstWhere((r) => r.role == 'photo');
      final cached = File(
        '${result.directory}/original-cache/dad-${resource.sha256}.jpg',
      );
      expect(Digest.sha256Hex(cached.readAsBytesSync()), resource.sha256);
      expect(result.session.remote.single.localPreviewPath, isNotNull);
    },
  );

  test('corrupt adapter download is independently rejected and existing files survive', () async {
    _publish(storage, ParentIdentity.dad, 1, photoCount: 1);
    storage.corruptDownload = true;
    final sentinel = File('${sandbox.path}/original.jpg')
      ..writeAsStringSync('unique-original');
    await expectLater(
      ArchiveRestore.restore(
        storage,
        destination: '${sandbox.path}/corrupt',
        owner: ParentIdentity.dad,
        deviceID: uuid(99),
        chains: [
          RestoreChain(
            parent: ParentIdentity.dad,
            prefix: _prefix(ParentIdentity.dad, 1),
          ),
        ],
      ),
      throwsA(isA<ContractError>()),
    );
    expect(Directory('${sandbox.path}/corrupt').existsSync(), isFalse);
    expect(sentinel.readAsStringSync(), 'unique-original');
    expect(sandbox.listSync().map((e) => e.path), [sentinel.path]);
  });

  test('missing original cannot succeed with a preview alone', () async {
    final manifest = _publish(storage, ParentIdentity.dad, 1, photoCount: 1);
    storage.objects.remove(
      manifest.resources.firstWhere((r) => r.role == 'photo').objectKey,
    );
    await expectLater(
      ArchiveRestore.restore(
        storage,
        destination: '${sandbox.path}/missing',
        owner: ParentIdentity.dad,
        deviceID: uuid(99),
        chains: [
          RestoreChain(
            parent: ParentIdentity.dad,
            prefix: _prefix(ParentIdentity.dad, 1),
          ),
        ],
      ),
      throwsA(isA<StorageProviderFailure>()),
    );
    expect(sandbox.listSync(), isEmpty);
  });

  test('repeat restoration refuses existing destination and cannot duplicate its archive', () async {
    _publish(storage, ParentIdentity.dad, 1);
    final args = [
      RestoreChain(
        parent: ParentIdentity.dad,
        prefix: _prefix(ParentIdentity.dad, 1),
      ),
    ];
    final result = await ArchiveRestore.restore(
      storage,
      destination: '${sandbox.path}/once',
      owner: ParentIdentity.dad,
      deviceID: uuid(99),
      chains: args,
    );
    final before = File(result.archivePath).readAsBytesSync();
    await expectLater(
      ArchiveRestore.restore(
        storage,
        destination: result.directory,
        owner: ParentIdentity.dad,
        deviceID: uuid(99),
        chains: args,
      ),
      throwsA(isA<ContractError>()),
    );
    expect(File(result.archivePath).readAsBytesSync(), before);
    expect(
      ArchiveStore(result.archivePath).load()!.session().remote,
      hasLength(1),
    );
  });

  test('nonempty destination and foreign editable source are refused before download', () async {
    _publish(storage, ParentIdentity.mom, 2);
    final existing = Directory('${sandbox.path}/existing')..createSync();
    final sentinel = File('${existing.path}/unique')..writeAsStringSync('keep');
    final sources = [
      RestoreChain(
        parent: ParentIdentity.mom,
        prefix: _prefix(ParentIdentity.mom, 2),
      ),
    ];
    await expectLater(
      ArchiveRestore.restore(
        storage,
        destination: existing.path,
        owner: ParentIdentity.dad,
        deviceID: uuid(99),
        chains: sources,
      ),
      throwsA(isA<ContractError>()),
    );
    await expectLater(
      ArchiveRestore.restore(
        storage,
        destination: '${sandbox.path}/foreign',
        owner: ParentIdentity.dad,
        deviceID: uuid(99),
        chains: sources,
        editableSourcePrefix: _prefix(ParentIdentity.mom, 2),
      ),
      throwsA(isA<ContractError>()),
    );
    expect(sentinel.readAsStringSync(), 'keep');
    expect(storage.downloads, isEmpty);
  });

  test('same record across chains keeps newest source without duplicate local and remote', () async {
    _publish(storage, ParentIdentity.dad, 1, updatedAt: _time + 2);
    _publish(storage, ParentIdentity.dad, 2, updatedAt: _time + 1);
    final result = await ArchiveRestore.restore(
      storage,
      destination: '${sandbox.path}/dedup',
      owner: ParentIdentity.dad,
      deviceID: uuid(99),
      editableSourcePrefix: _prefix(ParentIdentity.dad, 1),
      chains: [
        RestoreChain(
          parent: ParentIdentity.dad,
          prefix: _prefix(ParentIdentity.dad, 1),
        ),
        RestoreChain(
          parent: ParentIdentity.dad,
          prefix: _prefix(ParentIdentity.dad, 2),
        ),
      ],
    );
    expect(result.session.moments, hasLength(1));
    expect(result.session.remote, isEmpty);
    expect(result.session.timelineEntries(), hasLength(1));
  });
  test('restore pins the physical parent and returns its canonical receipt path', () async {
    _publish(storage, ParentIdentity.dad, 1, photoCount: 1);
    final first = Directory('${sandbox.path}/first')..createSync();
    final second = Directory('${sandbox.path}/second')..createSync();
    final alias = Link('${sandbox.path}/current');
    await alias.create(first.path);
    final sentinel = File('${second.path}/original')..writeAsStringSync('keep');
    var switched = false;
    storage.beforeDownload = () async {
      if (switched) return;
      switched = true;
      await alias.delete();
      await alias.create(second.path);
    };
    final result = await ArchiveRestore.restore(
      storage,
      destination: '${alias.path}/recovered',
      owner: ParentIdentity.dad,
      deviceID: uuid(99),
      chains: [
        RestoreChain(
          parent: ParentIdentity.dad,
          prefix: _prefix(ParentIdentity.dad, 1),
        ),
      ],
    );
    final physicalParent = await first.resolveSymbolicLinks();
    expect(result.directory, '$physicalParent/recovered');
    expect(File(result.archivePath).existsSync(), isTrue);
    expect(Directory('${alias.path}/recovered').existsSync(), isFalse);
    expect(sentinel.readAsStringSync(), 'keep');
  }, skip: Platform.isWindows);
}
