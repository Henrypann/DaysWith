import 'dart:convert';

import 'package:jinbao_core/jinbao_core.dart';
import 'package:jinbao_core/src/family_archive.dart';
import 'package:test/test.dart';

import 'support.dart' show uuid;

const _time = 1700000000000;
FamilyArchiveScope _scope({int family = 1, int member = 2, int device = 3}) =>
    FamilyArchiveScope(familyID: uuid(family), memberID: uuid(member), deviceID: uuid(device));

FamilyArchiveRecord _record({
  int id = 10, int owner = 2, int device = 3, int revision = 1,
  String note = 'synthetic record', List<FamilyArchiveAsset> assets = const [],
  int? deletedAt,
}) => FamilyArchiveRecord(
  id: uuid(id), ownerMemberID: uuid(owner), writerDeviceID: uuid(device),
  revision: revision, occurredAt: _time, updatedAt: _time + revision,
  title: '合成记录', note: note, assets: assets, deletedAt: deletedAt,
);

FamilyArchiveAsset _asset(int index, {bool video = false}) => FamilyArchiveAsset(
  id: uuid(100 + index), kind: video ? 'video' : 'photo', capturedAt: _time,
  resources: [
    for (final preview in [false, true])
      FamilyArchiveResource(
        id: uuid(1000 + index * 2 + (preview ? 1 : 0)),
        role: preview ? 'preview' : (video ? 'video' : 'photo'),
        contentType: !preview && video ? 'video/mp4' : 'image/jpeg',
        originalFilename: preview ? 'preview-$index.jpg' : 'original-$index.${video ? 'mp4' : 'jpg'}',
        byteCount: utf8.encode('synthetic:$index:$preview').length,
        sha256: Digest.sha256Hex(utf8.encode('synthetic:$index:$preview')),
      ),
  ],
);

void main() {
  test('family namespace UUIDs and digest paths are canonical and isolated', () {
    final scope = _scope();
    final hash = Digest.sha256Hex([1, 2, 3]);
    expect(scope.objectKey(hash), 'family/v1/${uuid(1)}/members/${uuid(2)}/objects/$hash');
    expect(scope.manifestKey(sequence: 1, sha256: hash),
        'family/v1/${uuid(1)}/members/${uuid(2)}/devices/${uuid(3)}/manifests/1-$hash.json');
    expect(_scope(member: 4).objectKey(hash), isNot(scope.objectKey(hash)));
    expect(() => scope.objectKey('../secret'), throwsA(isA<ContractError>()));
    expect(() => FamilyArchiveScope(familyID: '../x', memberID: uuid(2), deviceID: uuid(3)),
        throwsA(isA<ContractError>()));
  });

  test('ten photo and one video metadata vectors roundtrip all original facts and dates', () {
    final scope = _scope();
    final assets = [for (var i = 0; i < 11; i++) _asset(i, video: i == 10)];
    final manifest = FamilyArchiveManifest(
      scope: scope, sequence: 1, records: [_record(assets: assets)],
      anniversaries: [FamilyArchiveAnniversary(
        id: uuid(90), ownerMemberID: uuid(2), title: '生日', date: '--02-29', revision: 1,
      )],
    );
    final bytes = manifest.encode();
    final restored = FamilyArchiveManifest.decode(bytes, expectedScope: scope);
    expect(restored.encode(), bytes);
    expect(restored.sha256, Digest.sha256Hex(bytes));
    expect(restored.records.single.assets, hasLength(11));
    expect(restored.records.single.assets.expand((a) => a.resources), hasLength(22));
    expect(restored.records.single.assets.where((a) => a.kind == 'video'), hasLength(1));
    expect(restored.anniversaries.single.date, '0004-02-29');
    for (final asset in restored.records.single.assets) {
      final original = asset.resources.where((r) => r.role != 'preview').single;
      expect(original.byteCount, greaterThan(0));
      expect(original.toJson(scope)['objectKey'], scope.objectKey(original.sha256));
    }
    expect(() => restored.records.clear(), throwsUnsupportedError);
    expect(() => restored.records.single.assets.clear(), throwsUnsupportedError);
    // These bytes are synthetic metadata vectors, not decoded media/device acceptance.
  });

  test('strict decoding refuses unknown version, fields, identity and object path swaps', () {
    final manifest = FamilyArchiveManifest(scope: _scope(), sequence: 1, records: [_record(assets: [_asset(0)])]);
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (json) => json['version'] = 2,
      (json) => json['unexpected'] = true,
      (json) => json['familyID'] = uuid(9),
      (json) => json['memberID'] = uuid(9),
      (json) => json['deviceID'] = uuid(9),
      (json) => (json['records'] as List).single['ownerMemberID'] = uuid(9),
      (json) => (json['records'] as List).single['revision'] = true,
      (json) => (json['records'] as List).single['assets'][0]['resources'][0]['objectKey'] = 'life/v1/dad/secret',
      (json) => (json['records'] as List).single['assets'][0]['resources'][0]['byteCount'] = -1,
    ]) {
      final data = jsonDecode(utf8.decode(manifest.encode())) as Map<String, dynamic>;
      mutate(data);
      expect(() => FamilyArchiveManifest.decode(utf8.encode(jsonEncode(data)), expectedScope: _scope()),
          throwsA(isA<ContractError>()));
    }
    final text = utf8.decode(manifest.encode());
    expect(() => FamilyArchiveManifest.decode(utf8.encode('{"version":1,${text.substring(1)}'), expectedScope: _scope()),
        throwsA(isA<ContractError>()), reason: 'Duplicate JSON fields must not be accepted.');
  });

  test('preview-only assets and foreign record ownership cannot form a snapshot', () {
    final full = _asset(0);
    expect(() => FamilyArchiveAsset(
      id: full.id, kind: full.kind, capturedAt: full.capturedAt,
      resources: full.resources.where((r) => r.role == 'preview').toList(),
    ), throwsA(isA<ContractError>()));
    expect(() => FamilyArchiveManifest(scope: _scope(), sequence: 1, records: [_record(owner: 9)]),
        throwsA(isA<ContractError>()));
  });

  test('one digest cannot claim contradictory byte counts under different resource IDs', () {
    final full = _asset(0);
    final original = full.resources.firstWhere((r) => r.role == 'photo');
    final contradictory = FamilyArchiveResource(
      id: uuid(9999), role: 'preview', contentType: 'image/jpeg',
      originalFilename: 'preview.jpg', byteCount: original.byteCount + 1,
      sha256: original.sha256,
    );
    final asset = FamilyArchiveAsset(id: full.id, kind: 'photo', capturedAt: _time,
        resources: [original, contradictory]);
    expect(() => FamilyArchiveManifest(scope: _scope(), sequence: 1, records: [_record(assets: [asset])]),
        throwsA(isA<ContractError>()));
  });

  test('snapshot chain is contiguous, preserves tombstones and rejects revision mutation', () {
    final first = FamilyArchiveManifest(scope: _scope(), sequence: 1, records: [_record()]);
    first.validateSuccessor(null);
    final next = FamilyArchiveManifest(scope: _scope(), sequence: 2, parentHash: first.sha256,
        records: [_record(revision: 2, deletedAt: _time + 2)]);
    next.validateSuccessor(first);
    expect(next.records.single.deletedAt, isNotNull);
    for (final invalid in [
      FamilyArchiveManifest(scope: _scope(), sequence: 3, parentHash: first.sha256, records: [_record(revision: 2)]),
      FamilyArchiveManifest(scope: _scope(), sequence: 2, parentHash: first.sha256, records: [_record(note: 'changed at same revision')]),
      FamilyArchiveManifest(scope: _scope(), sequence: 2, parentHash: first.sha256, records: []),
    ]) {
      expect(() => invalid.validateSuccessor(first), throwsA(isA<ContractError>()));
    }
  });

  test('merge keeps separate owners and rejects lower-revision forks regardless of order', () {
    final first = FamilyArchiveManifest(scope: _scope(), sequence: 1, records: [_record()]);
    final newest = FamilyArchiveManifest(scope: _scope(device: 4), sequence: 1, records: [_record(revision: 3, device: 4)]);
    final foreign = FamilyArchiveManifest(scope: _scope(member: 5), sequence: 1, records: [_record(owner: 5)]);
    final merged = mergeFamilyArchiveRecords([newest, first, foreign], familyID: uuid(1));
    expect(merged, hasLength(2));
    expect(merged.firstWhere((r) => r.ownerMemberID == uuid(2)).revision, 3);
    final fork = FamilyArchiveManifest(scope: _scope(device: 6), sequence: 1, records: [_record(note: 'fork', device: 6)]);
    expect(() => mergeFamilyArchiveRecords([newest, first, fork], familyID: uuid(1)), throwsA(isA<ContractError>()));
    expect(() => mergeFamilyArchiveRecords([fork, newest, first], familyID: uuid(1)), throwsA(isA<ContractError>()));
    expect(() => mergeFamilyArchiveRecords([first], familyID: uuid(8)), throwsA(isA<ContractError>()));
  });

  test('legacy copy plan binds original bytes and keeps source untouched for rollback', () {
    final prefix = 'life/v1/dad/${uuid(3).toLowerCase()}/';
    final assets = [_asset(0)];
    final legacy = V1Manifest(
      version: 2,
      moments: [V1Moment(id: uuid(10), title: '旧记录', note: '合成', occurredAt: _time,
          createdAt: _time, updatedAt: _time, revision: 1, assetIDs: [assets.single.id])],
      assets: [V1Asset(id: assets.single.id, kind: 'photo', capturedAt: _time,
          resourceIDs: assets.single.resources.map((r) => r.id).toList())],
      resources: [for (final r in assets.single.resources) V1Resource(
        id: r.id, assetID: assets.single.id, role: r.role, contentType: r.contentType,
        originalFilename: r.originalFilename, byteCount: r.byteCount, sha256: r.sha256,
        objectKey: V1Layout.objectKey(prefix: prefix, sha256: r.sha256),
      )],
      anniversaries: [V1Anniversary(id: uuid(90), owner: ParentIdentity.dad, title: '生日', date: '0004-02-29')],
    );
    final bytes = V1Json.encodeManifest(legacy);
    final before = List<int>.from(bytes);
    final storage = StorageIdentity(providerId: 'cos', endpoint: 'https://synthetic.example/', prefix: prefix);
    final plan = FamilyLegacyCopyPlan.inspect(sourceStorage: storage, sourceOwner: ParentIdentity.dad,
        sourceManifestBytes: bytes, sourceManifestHash: Digest.sha256Hex(bytes), destination: _scope());
    expect(plan.mayActivateAutomatically, isFalse);
    expect(plan.mayDeleteSource, isFalse);
    expect(plan.objects, hasLength(2));
    expect(plan.recordOwners[uuid(10)], uuid(2));
    expect(plan.anniversaryIDs, [uuid(90)]);
    expect(plan.objects.every((o) => o.sourceKey.startsWith('life/v1/dad/') && o.destinationKey.startsWith(_scope().memberPrefix)), isTrue);
    expect(bytes, before);
    expect(() => FamilyLegacyCopyPlan.inspect(sourceStorage: storage, sourceOwner: ParentIdentity.mom,
        sourceManifestBytes: bytes, sourceManifestHash: Digest.sha256Hex(bytes), destination: _scope()), throwsA(isA<ContractError>()));
    expect(() => FamilyLegacyCopyPlan.inspect(sourceStorage: storage, sourceOwner: ParentIdentity.dad,
        sourceManifestBytes: bytes, sourceManifestHash: Digest.sha256Hex([0]), destination: _scope()), throwsA(isA<ContractError>()));
  });
}
