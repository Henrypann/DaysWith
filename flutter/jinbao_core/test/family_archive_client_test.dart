import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jinbao_core/src/digest.dart';
import 'package:jinbao_core/src/family_archive.dart';
import 'package:jinbao_core/src/family_archive_client.dart';
import 'package:jinbao_core/src/family_gateway_client.dart';
import 'package:jinbao_core/src/json_wire.dart';
import 'package:test/test.dart';

String uuid(int value) => '00000000-0000-4000-8000-${value.toRadixString(16).padLeft(12, '0').toUpperCase()}';
final scope = FamilyArchiveScope(familyID: uuid(1), memberID: uuid(2), deviceID: uuid(3));
final origin = Uri.parse('https://gateway.example.invalid');

Matcher fails(FamilyArchiveClientFailure failure) => throwsA(isA<FamilyArchiveClientException>()
    .having((error) => error.failure, 'failure', failure));

/// Synthetic protocol fixture only. It does not assert image/video decoding,
/// physical-device playback, or a production storage endpoint's behavior.
class MemoryArchiveTransport implements FamilyArchiveTransport {
  final requests = <FamilyArchiveRequest>[];
  final objects = <String, List<int>>{};
  final manifests = <String, List<int>>{};
  final descriptors = <FamilyArchiveSnapshot>[];
  final moderations = <Map<String, Object?>>[];
  int moderationVersion = 0;
  bool allowModeration = true;
  bool omitModerationFields = false;
  bool revoked = false;
  bool corruptDownload = false;
  bool repeatCursor = false;
  int mediaDownloads = 0;
  int? failDownload;
  FutureOr<void> Function(FamilyArchiveRequest)? before;
  void Function()? duringDownload;

  void seed(FamilyArchiveManifest manifest) {
    final descriptor = FamilyArchiveSnapshot(scope: manifest.scope, sequence: manifest.sequence,
      sha256: manifest.sha256, byteCount: manifest.encode().length);
    descriptors.add(descriptor);
    manifests['/v1/families/${manifest.scope.familyID}/members/${manifest.scope.memberID}/devices/'
      '${manifest.scope.deviceID}/snapshots/${manifest.sequence}/${manifest.sha256}'] = manifest.encode();
  }

  FamilyArchiveResponse json(Object? body, {int status = 200}) =>
      FamilyArchiveResponse(statusCode: status, body: JsonWire.encode(body));

  @override
  Future<FamilyArchiveResponse> send(FamilyArchiveRequest request) async {
    requests.add(request);
    if (request.headers['Authorization'] != 'Bearer synthetic-session') return json({}, status: 401);
    if (revoked) return json({'error': 'revoked'}, status: 403);
    await before?.call(request);
    if (request.shouldPause?.call() ?? false) throw const FamilyArchiveClientException(FamilyArchiveClientFailure.paused);
    final path = request.uri.path;
    if (path.endsWith('/archive')) {
      final offset = int.parse(request.uri.queryParameters['cursor'] ?? '0');
      final page = descriptors.skip(offset).take(3).toList();
      final next = offset + page.length < descriptors.length ? '${offset + page.length}' : null;
      return json({'snapshots': page.map((d) => d.toJson()).toList(),
        if (!omitModerationFields) 'moderationVersion': moderationVersion,
        if (!omitModerationFields) 'moderations': moderations,
        'nextCursor': repeatCursor ? '0' : next});
    }
    if (path.endsWith('/moderation') && request.method == 'POST') {
      if (!allowModeration) return json({'error': 'denied'}, status: 403);
      final parts = path.split('/');
      final body = jsonDecode(utf8.decode(request.body)) as Map<String, dynamic>;
      final event = <String, Object?>{'id': ++moderationVersion,
        'familyID': parts[3], 'ownerMemberID': parts[5], 'recordID': parts[7],
        'hidden': body['hidden'], 'recordRevision': body['expectedRevision'],
        'at': 1700000000000, 'actorMemberID': scope.memberID};
      moderations.removeWhere((old) => old['ownerMemberID'] == event['ownerMemberID'] && old['recordID'] == event['recordID']);
      moderations.add(event);
      return json(event);
    }
    if (path.contains('/objects/')) {
      if (request.method == 'PUT') {
        final bytes = await File(request.sourceFile!).readAsBytes();
        if (Digest.sha256Hex(bytes) != path.split('/').last ||
            request.headers['Content-Length'] != '${bytes.length}') return json({}, status: 409);
        if (objects[path] != null && Digest.sha256Hex(objects[path]!) != Digest.sha256Hex(bytes)) return json({}, status: 409);
        objects[path] = bytes;
        return json({'ok': true});
      }
      final bytes = objects[path];
      if (bytes == null) return json({'error': 'notFound'}, status: 404);
      final headers = {'Content-Length': '${bytes.length}', 'X-Content-SHA256': Digest.sha256Hex(bytes)};
      if (request.method == 'HEAD') return FamilyArchiveResponse(statusCode: 200, headers: headers);
      mediaDownloads++;
      if (mediaDownloads == failDownload) throw Exception('Synthetic disconnected network with secret URL');
      // GET sends no request body even though the expected response has bytes.
      expect(request.headers['Content-Length'], '0');
      final content = corruptDownload ? [...bytes.reversed] : bytes;
      if (duringDownload == null) {
        await File(request.destinationFile!).writeAsBytes(content, flush: true);
      } else {
        final middle = content.length ~/ 2;
        await File(request.destinationFile!).writeAsBytes(content.sublist(0, middle), flush: true);
        duringDownload!();
        if (request.shouldPause?.call() ?? false) {
          throw const FamilyArchiveClientException(FamilyArchiveClientFailure.paused);
        }
        await File(request.destinationFile!).writeAsBytes(content.sublist(middle), mode: FileMode.append, flush: true);
      }
      return FamilyArchiveResponse(statusCode: 200, headers: headers);
    }
    if (path.contains('/snapshots/')) {
      if (request.method == 'PUT') {
        final manifest = FamilyArchiveManifest.decode(request.body, expectedScope: scope);
        final descriptor = FamilyArchiveSnapshot(scope: manifest.scope, sequence: manifest.sequence,
            sha256: manifest.sha256, byteCount: request.body.length);
        if (!manifests.containsKey(path)) descriptors.add(descriptor);
        manifests[path] = request.body;
        return json(descriptor.toJson());
      }
      final bytes = manifests[path];
      return bytes == null ? json({}, status: 404) : FamilyArchiveResponse(statusCode: 200, body: bytes);
    }
    if (request.method == 'POST' && path.endsWith('/devices/${scope.deviceID}')) return json({'ok': true});
    return json({'error': 'notFound'}, status: 404);
  }
}

void main() {
  late Directory workspace;
  late MemoryArchiveTransport transport;
  late FamilyArchiveClient client;
  late FamilyArchiveManifest manifest;
  late Map<String, String> sources;
  late Map<String, List<int>> originalBytes;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('dayswith-family-transfer-');
    transport = MemoryArchiveTransport();
    client = FamilyGatewayClient(origin: origin, accessToken: () async => 'synthetic-session')
        .createArchiveClient(transport: transport);
    sources = {};
    originalBytes = {};
    final assets = <FamilyArchiveAsset>[];
    for (var n = 0; n < 11; n++) {
      final resources = <FamilyArchiveResource>[];
      for (var variant = 0; variant < 2; variant++) {
        final role = variant == 1 ? 'preview' : n == 10 ? 'video' : 'photo';
        final bytes = utf8.encode('SYNTHETIC-$n-$variant-byte-roundtrip-body');
        final digest = Digest.sha256Hex(bytes);
        final source = '${workspace.path}/source-$n-$variant';
        await File(source).writeAsBytes(bytes);
        originalBytes[source] = bytes;
        sources[scope.objectKey(digest)] = source;
        resources.add(FamilyArchiveResource(id: uuid(100 + 2 * n + variant), role: role,
          contentType: role == 'video' ? 'video/mp4' : 'image/jpeg', originalFilename: 'synthetic-$n-$variant',
          byteCount: bytes.length, sha256: digest));
      }
      assets.add(FamilyArchiveAsset(id: uuid(50 + n), kind: n == 10 ? 'video' : 'photo',
          capturedAt: 1700000000000 + n, resources: resources));
    }
    manifest = FamilyArchiveManifest(scope: scope, sequence: 1, records: [
      FamilyArchiveRecord(id: uuid(10), ownerMemberID: scope.memberID, writerDeviceID: scope.deviceID,
        revision: 1, occurredAt: 1700000000000, updatedAt: 1700000000001,
        title: '十张合成照片和一段合成视频', note: '协议验证，不含真实家庭数据', assets: assets),
    ], anniversaries: [FamilyArchiveAnniversary(id: uuid(20), ownerMemberID: scope.memberID,
      title: '合成纪念日', date: '0004-02-29', revision: 1)]);
  });
  tearDown(() => workspace.delete(recursive: true));

  test('10 photo + 1 video originals and previews roundtrip into an isolated archive', () async {
    final published = await client.publishManifest(manifest, sourceFiles: sources);
    expect(published.sha256, manifest.sha256);
    expect(transport.objects, hasLength(22));
    final activeArchive = File('${workspace.path}/archive.json')..writeAsStringSync('preserve active archive');
    final result = await client.restoreFamily(familyID: scope.familyID,
      restoreParent: Directory('${workspace.path}/restores'));
    expect(result.directory, isNot(workspace.path));
    expect(result.records.single.title, manifest.records.single.title);
    expect(result.records.single.ownerMemberID, scope.memberID);
    expect(result.records.single.occurredAt, 1700000000000);
    expect(result.anniversaries.single.date, '0004-02-29');
    expect(result.verifiedResourceCount, 22);
    expect(result.verifiedByteCount, originalBytes.values.fold<int>(0, (sum, bytes) => sum + bytes.length));
    for (final entry in result.resourceFiles.entries) {
      final source = sources[entry.key]!;
      expect(await File(entry.value).readAsBytes(), originalBytes[source]);
      expect(await File(source).readAsBytes(), originalBytes[source]);
    }
    expect(activeArchive.readAsStringSync(), 'preserve active archive');
    expect(File('${result.directory}/RESTORE_COMPLETE.json').existsSync(), isTrue);
    final restore = jsonDecode(File('${result.directory}/family-restore.json').readAsStringSync()) as Map;
    expect(restore['manifestFiles'], hasLength(1));
    expect(result.manifestCount, 1);
  });

  test('modified source fails before device registration or any remote write', () async {
    await File(sources.values.first).writeAsString('corrupt');
    await expectLater(client.publishManifest(manifest, sourceFiles: sources), fails(FamilyArchiveClientFailure.integrity));
    expect(transport.requests, isEmpty);
  });

  test('stage pointer is persisted before first network; failed persistence aborts', () async {
    String? stage;
    await expectLater(client.restoreFamily(familyID: scope.familyID,
      restoreParent: Directory('${workspace.path}/restores'), onStageCreated: (path) {
        stage = path;
        expect(File('$path/STATUS.json').existsSync(), isTrue);
        expect(transport.requests, isEmpty);
        throw StateError('Synthetic pointer persistence failure');
      }), fails(FamilyArchiveClientFailure.integrity));
    expect(stage, isNotNull);
    expect(transport.requests, isEmpty);
    expect(File('$stage/RESTORE_COMPLETE.json').existsSync(), isFalse);
  });

  test('paginated members and devices restore contiguous chains with deterministic latest revisions', () async {
    await client.publishManifest(manifest, sourceFiles: sources);
    final original = manifest.records.single;
    FamilyArchiveRecord revision(int number, String device) => FamilyArchiveRecord(
      id: original.id, ownerMemberID: original.ownerMemberID, writerDeviceID: device,
      revision: number, occurredAt: original.occurredAt, updatedAt: original.updatedAt + number,
      title: 'revision $number', note: original.note, assets: original.assets);
    transport.seed(FamilyArchiveManifest(scope: scope, sequence: 2, parentHash: manifest.sha256,
      records: [revision(2, scope.deviceID)], anniversaries: manifest.anniversaries));
    final otherDevice = FamilyArchiveScope(familyID: scope.familyID, memberID: scope.memberID, deviceID: uuid(4));
    transport.seed(FamilyArchiveManifest(scope: otherDevice, sequence: 1,
      records: [revision(3, otherDevice.deviceID)], anniversaries: manifest.anniversaries));
    final otherMember = FamilyArchiveScope(familyID: scope.familyID, memberID: uuid(5), deviceID: uuid(6));
    transport.seed(FamilyArchiveManifest(scope: otherMember, sequence: 1, records: [
      FamilyArchiveRecord(id: uuid(7), ownerMemberID: otherMember.memberID,
        writerDeviceID: otherMember.deviceID, revision: 1, occurredAt: 1700000000000,
        updatedAt: 1700000000001, title: '另一位成员', note: '合成文字'),
    ]));
    final result = await client.restoreFamily(familyID: scope.familyID,
      restoreParent: Directory('${workspace.path}/restores'));
    expect(result.manifestCount, 4);
    expect(result.records, hasLength(2));
    expect(result.records.firstWhere((r) => r.id == original.id).revision, 3);
    expect(result.records.map((r) => r.ownerMemberID).toSet(), {scope.memberID, otherMember.memberID});
    expect(transport.requests.where((r) => r.uri.queryParameters.containsKey('cursor')), isNotEmpty);
  });

  test('missing chain sequence and unequal bytes at the same revision fail restoration', () async {
    await client.publishManifest(manifest, sourceFiles: sources);
    transport.seed(FamilyArchiveManifest(scope: scope, sequence: 3, parentHash: manifest.sha256,
      records: manifest.records, anniversaries: manifest.anniversaries));
    await expectLater(client.restoreFamily(familyID: scope.familyID,
      restoreParent: Directory('${workspace.path}/gap')), fails(FamilyArchiveClientFailure.integrity));
    transport.manifests.removeWhere((path, _) => path.contains('/snapshots/3/'));
    transport.descriptors.removeLast();
    final other = FamilyArchiveScope(familyID: scope.familyID, memberID: scope.memberID, deviceID: uuid(4));
    final original = manifest.records.single;
    transport.seed(FamilyArchiveManifest(scope: other, sequence: 1, records: [
      FamilyArchiveRecord(id: original.id, ownerMemberID: original.ownerMemberID, writerDeviceID: other.deviceID,
        revision: 1, occurredAt: original.occurredAt, updatedAt: original.updatedAt,
        title: 'conflicting same revision', note: original.note, assets: original.assets),
    ]));
    await expectLater(client.restoreFamily(familyID: scope.familyID,
      restoreParent: Directory('${workspace.path}/fork')), fails(FamilyArchiveClientFailure.integrity));
  });

  test('idempotent retry reuses exact bytes and missing local sources need verified remote media', () async {
    await client.publishManifest(manifest, sourceFiles: sources);
    final puts = transport.requests.where((r) => r.method == 'PUT' && r.sourceFile != null).length;
    await client.publishManifest(manifest, sourceFiles: {});
    expect(transport.descriptors, hasLength(1));
    expect(transport.requests.where((r) => r.method == 'PUT' && r.sourceFile != null).length, puts);
    transport.objects.remove(transport.objects.keys.first);
    await expectLater(client.publishManifest(manifest, sourceFiles: {}), fails(FamilyArchiveClientFailure.integrity));
  });

  test('interrupted restore leaves incomplete stage; retry hashes cached bytes and repairs corrupt cache', () async {
    await client.publishManifest(manifest, sourceFiles: sources);
    transport.failDownload = 2;
    String? stage;
    try {
      await client.restoreFamily(familyID: scope.familyID, restoreParent: Directory('${workspace.path}/restores'));
      fail('Expected a disconnected transfer');
    } on FamilyArchiveClientException catch (error) {
      expect(error.failure, FamilyArchiveClientFailure.unavailable);
      stage = error.stageDirectory;
    }
    expect(stage, isNotNull);
    expect(File('$stage/RESTORE_COMPLETE.json').existsSync(), isFalse);
    // Reproduce a crash after immutable catalog bytes reached disk, before the
    // status checkpoint recorded their hash. Only exact live bytes may recover.
    final statusFile = File('$stage/STATUS.json');
    final status = jsonDecode(statusFile.readAsStringSync()) as Map<String, dynamic>;
    status['catalogSha256'] = null;
    status.remove('catalogCount');
    statusFile.writeAsStringSync(jsonEncode(status));
    final cached = Directory('$stage/objects').listSync(recursive: true).whereType<File>()
        .firstWhere((file) => !file.path.endsWith('.part'));
    cached.writeAsStringSync('tampered digest-named cache');
    transport.failDownload = null;
    final result = await client.restoreFamily(familyID: scope.familyID,
      restoreParent: Directory('${workspace.path}/restores'), resumeDirectory: stage);
    expect(result.verifiedResourceCount, 22);
    expect(Directory(result.directory).listSync(recursive: true).whereType<File>()
        .any((file) => file.path.contains('/.corrupt-')), isTrue);
  });

  test('corrupt remote download never produces completed restore', () async {
    await client.publishManifest(manifest, sourceFiles: sources);
    transport.corruptDownload = true;
    String? stage;
    try {
      await client.restoreFamily(familyID: scope.familyID, restoreParent: Directory('${workspace.path}/restores'));
      fail('Expected hash failure');
    } on FamilyArchiveClientException catch (error) {
      expect(error.failure, FamilyArchiveClientFailure.integrity);
      stage = error.stageDirectory;
    }
    expect(File('$stage/RESTORE_COMPLETE.json').existsSync(), isFalse);
    expect(Directory(stage!).listSync(recursive: true).whereType<File>()
        .any((file) => file.path.endsWith('.part')), isFalse);
    expect(Directory('${workspace.path}/restores').listSync().every((d) => d.path.contains('.pending')), isTrue);
  });

  test('pause prevents manifest publication and interrupted recovery remains resumable', () async {
    var paused = false;
    transport.before = (request) {
      if (request.method == 'PUT' && request.sourceFile != null) paused = true;
    };
    await expectLater(client.publishManifest(manifest, sourceFiles: sources, shouldPause: () => paused),
      fails(FamilyArchiveClientFailure.paused));
    expect(transport.manifests, isEmpty);
    transport.before = null;
    paused = false;
    await client.publishManifest(manifest, sourceFiles: sources);
    transport.before = (request) {
      if (request.destinationFile != null) paused = true;
    };
    await expectLater(client.restoreFamily(familyID: scope.familyID,
      restoreParent: Directory('${workspace.path}/restores'), shouldPause: () => paused),
      fails(FamilyArchiveClientFailure.paused));
  });

  test('resume cannot present a stale subset after the authenticated family catalog changed', () async {
    await client.publishManifest(manifest, sourceFiles: sources);
    transport.failDownload = 2;
    String? stage;
    try {
      await client.restoreFamily(familyID: scope.familyID, restoreParent: Directory('${workspace.path}/restores'));
    } on FamilyArchiveClientException catch (error) { stage = error.stageDirectory; }
    expect(stage, isNotNull);
    transport.seed(FamilyArchiveManifest(scope: FamilyArchiveScope(familyID: scope.familyID,
      memberID: uuid(4), deviceID: uuid(5)), sequence: 1, records: []));
    transport.failDownload = null;
    await expectLater(client.restoreFamily(familyID: scope.familyID,
      restoreParent: Directory('${workspace.path}/restores'), resumeDirectory: stage),
      fails(FamilyArchiveClientFailure.conflict));
    expect(File('$stage/RESTORE_COMPLETE.json').existsSync(), isFalse);
  });

  test('revocation blocks publication and even fully cached restart recovery', () async {
    await client.publishManifest(manifest, sourceFiles: sources);
    transport.revoked = true;
    await expectLater(client.publishManifest(manifest, sourceFiles: {}), fails(FamilyArchiveClientFailure.denied));
    await expectLater(client.restoreFamily(familyID: scope.familyID,
      restoreParent: Directory('${workspace.path}/restores')), fails(FamilyArchiveClientFailure.denied));
  });

  test('tampered manifest digest and duplicate catalog/cursor cannot be trusted', () async {
    final descriptor = await client.publishManifest(manifest, sourceFiles: sources);
    transport.manifests[transport.manifests.keys.single] = utf8.encode('{}');
    await expectLater(client.getManifest(descriptor), fails(FamilyArchiveClientFailure.integrity));
    transport.descriptors.add(descriptor);
    await expectLater(client.catalog(scope.familyID), fails(FamilyArchiveClientFailure.invalidResponse));
    transport.descriptors.removeLast();
    transport.repeatCursor = true;
    await expectLater(client.catalog(scope.familyID), fails(FamilyArchiveClientFailure.invalidResponse));
  });

  test('symlink restore parents and arbitrary existing directories are never overwritten', () async {
    await client.publishManifest(manifest, sourceFiles: sources);
    final safe = Directory('${workspace.path}/existing')..createSync();
    final original = File('${safe.path}/archive.json')..writeAsStringSync('KEEP');
    final link = Link('${workspace.path}/alias')..createSync(safe.path);
    await expectLater(client.restoreFamily(familyID: scope.familyID,
      restoreParent: Directory(link.path)), fails(FamilyArchiveClientFailure.invalidPath));
    await expectLater(client.restoreFamily(familyID: scope.familyID,
      restoreParent: Directory(workspace.path), resumeDirectory: safe.path), fails(FamilyArchiveClientFailure.invalidPath));
    expect(original.readAsStringSync(), 'KEEP');
  });

  test('explicit moderation hides visible records while raw snapshots and recovery originals remain intact', () async {
    await client.publishManifest(manifest, sourceFiles: sources);
    final immutableBytes = [...transport.manifests.values.single];
    final event = await client.moderateRecord(familyID: scope.familyID, ownerMemberID: scope.memberID,
      recordID: manifest.records.single.id, expectedRevision: 1, hidden: true);
    expect(event.hidden, isTrue);
    final action = transport.requests.last;
    expect(jsonDecode(utf8.decode(action.body)), {'expectedRevision': 1, 'hidden': true});
    final catalog = await client.loadCatalog(scope.familyID);
    expect(catalog.moderationVersion, 1);
    expect(catalog.visibleRecords(manifest.records), isEmpty);
    final original = manifest.records.single;
    final ownerEdit = FamilyArchiveRecord(id: original.id, ownerMemberID: original.ownerMemberID,
      writerDeviceID: original.writerDeviceID, revision: 2, occurredAt: original.occurredAt,
      updatedAt: original.updatedAt + 1, title: 'owner cannot unhide by editing',
      note: original.note, assets: original.assets);
    expect(catalog.visibleRecords([ownerEdit]), isEmpty);
    expect(transport.manifests.values.single, immutableBytes);
    final result = await client.restoreFamily(familyID: scope.familyID,
      restoreParent: Directory('${workspace.path}/restores'));
    expect(result.records, hasLength(1));
    expect(result.visibleRecords, isEmpty);
    expect(result.verifiedResourceCount, 22);
    expect(result.moderations.single.id, event.id);
    final export = jsonDecode(File('${result.directory}/family-restore.json').readAsStringSync()) as Map;
    expect(export['records'], hasLength(1));
    expect((export['moderations'] as List).single['hidden'], isTrue);
    final complete = jsonDecode(File('${result.directory}/RESTORE_COMPLETE.json').readAsStringSync()) as Map;
    expect(complete['archiveSha256'], Digest.sha256Hex(File('${result.directory}/family-restore.json').readAsBytesSync()));
    expect(complete['moderationVersion'], 1);
    await client.moderateRecord(familyID: scope.familyID, ownerMemberID: scope.memberID,
      recordID: manifest.records.single.id, expectedRevision: 1, hidden: false);
    expect((await client.loadCatalog(scope.familyID)).visibleRecords(manifest.records), hasLength(1));
    expect(transport.manifests.values.single, immutableBytes);
    transport.allowModeration = false;
    await expectLater(client.moderateRecord(familyID: scope.familyID, ownerMemberID: scope.memberID,
      recordID: manifest.records.single.id, expectedRevision: 1, hidden: true), fails(FamilyArchiveClientFailure.denied));
  });

  test('moderation fields are mandatory, strictly scoped and duplicate/order-safe', () async {
    Map<String, Object?> event({int id = 1, String? family, String? owner, String? record}) => {
      'id': id, 'familyID': family ?? scope.familyID, 'ownerMemberID': owner ?? scope.memberID,
      'recordID': record ?? manifest.records.single.id, 'hidden': true, 'recordRevision': 1,
      'at': 1700000000000, 'actorMemberID': uuid(9),
    };
    Map<String, Object?> page(List<Object?> events, {Object? version = 1}) => {
      'snapshots': [], 'moderationVersion': version, 'moderations': events,
    };
    for (final data in [
      {'snapshots': []}, page([], version: true), page([], version: 1),
      page([event()], version: 2), page([event(family: uuid(99))]),
      page([event(), event()]), page([event(id: 2), event(id: 1, record: uuid(80))]),
      page([event(id: 2)], version: 1), page([event(), event(id: 2)]),
      page([{...event(), 'hidden': 'true'}]), page([{...event(), 'recordRevision': 0}]),
    ]) {
      expect(() => FamilyArchiveCatalog.fromJson(data, familyID: scope.familyID),
        fails(FamilyArchiveClientFailure.invalidResponse));
    }
    transport.omitModerationFields = true;
    await expectLater(client.loadCatalog(scope.familyID), fails(FamilyArchiveClientFailure.invalidResponse));
    final invalidReference = FamilyArchiveCatalog.fromJson(page([event(record: uuid(500))]), familyID: scope.familyID);
    expect(() => invalidReference.visibleRecords(manifest.records), fails(FamilyArchiveClientFailure.integrity));
  });

  test('overlay changes between pages or during restore prevent stale visible completion', () async {
    await client.publishManifest(manifest, sourceFiles: sources);
    for (var n = 10; n < 13; n++) {
      transport.seed(FamilyArchiveManifest(scope: FamilyArchiveScope(familyID: scope.familyID,
        memberID: uuid(n), deviceID: uuid(n + 1000)), sequence: 1, records: []));
    }
    transport.before = (request) {
      if (request.uri.queryParameters['cursor'] == '3' && transport.moderationVersion == 0) {
        transport.moderationVersion = 1;
        transport.moderations.add({'id': 1, 'familyID': scope.familyID, 'ownerMemberID': scope.memberID,
          'recordID': manifest.records.single.id, 'hidden': true, 'recordRevision': 1,
          'at': 1700000000000, 'actorMemberID': uuid(9)});
      }
    };
    await expectLater(client.loadCatalog(scope.familyID), fails(FamilyArchiveClientFailure.conflict));
    transport.before = (request) {
      if (request.destinationFile != null && transport.moderationVersion == 1) {
        transport.moderationVersion = 2;
        transport.moderations[0] = {...transport.moderations.single, 'id': 2, 'hidden': false};
      }
    };
    String? stage;
    try {
      await client.restoreFamily(familyID: scope.familyID, restoreParent: Directory('${workspace.path}/restores'));
      fail('Expected changed moderation watermark');
    } on FamilyArchiveClientException catch (error) {
      expect(error.failure, FamilyArchiveClientFailure.conflict);
      stage = error.stageDirectory;
    }
    expect(File('$stage/RESTORE_COMPLETE.json').existsSync(), isFalse);
  });

  test('resource cache hit requires live HEAD and complete bytes on every new view', () async {
    await client.publishManifest(manifest, sourceFiles: sources);
    final resource = manifest.records.single.assets.first.resources.first;
    final cache = Directory('${workspace.path}/media-cache');
    final first = await client.loadResource(scope: scope, resource: resource, cacheParent: cache);
    expect(Digest.sha256Hex(File(first).readAsBytesSync()), resource.sha256);
    final downloads = transport.mediaDownloads;
    final requests = transport.requests.length;
    final second = await client.loadResource(scope: scope, resource: resource, cacheParent: cache);
    expect(second, first);
    expect(transport.mediaDownloads, downloads);
    expect(transport.requests.skip(requests).map((r) => r.method), ['HEAD', 'HEAD']);
    transport.revoked = true;
    await expectLater(client.loadResource(scope: scope, resource: resource, cacheParent: cache),
      fails(FamilyArchiveClientFailure.denied));
    expect(File(first).existsSync(), isTrue, reason: 'Revocation cannot erase bytes already downloaded.');
  });

  test('corrupt cached resource is quarantined; corrupt network bytes never become a hit', () async {
    await client.publishManifest(manifest, sourceFiles: sources);
    final resource = manifest.records.single.assets.first.resources.first;
    final cache = Directory('${workspace.path}/media-cache');
    final path = await client.loadResource(scope: scope, resource: resource, cacheParent: cache);
    File(path).writeAsStringSync('damaged cached media');
    transport.corruptDownload = true;
    await expectLater(client.loadResource(scope: scope, resource: resource, cacheParent: cache),
      fails(FamilyArchiveClientFailure.integrity));
    expect(File(path).existsSync(), isFalse);
    final staged = cache.listSync(recursive: true).whereType<File>();
    expect(staged.any((file) => file.path.endsWith('.part')), isFalse);
    expect(staged.any((file) => file.path.contains('/.corrupt-')), isTrue);
    transport.corruptDownload = false;
    expect(await client.loadResource(scope: scope, resource: resource, cacheParent: cache), path);
    expect(Digest.sha256Hex(File(path).readAsBytesSync()), resource.sha256);
  });

  test('identical media hashes remain isolated across family, member and gateway origins', () async {
    await client.publishManifest(manifest, sourceFiles: sources);
    final resource = manifest.records.single.assets.first.resources.first;
    final cache = Directory('${workspace.path}/media-cache');
    final first = await client.loadResource(scope: scope, resource: resource, cacheParent: cache);
    final otherFamily = FamilyArchiveScope(familyID: uuid(999), memberID: scope.memberID, deviceID: scope.deviceID);
    final otherMember = FamilyArchiveScope(familyID: scope.familyID, memberID: uuid(998), deviceID: scope.deviceID);
    final originalBytes = transport.objects['/v1/families/${scope.familyID}/members/${scope.memberID}/objects/${resource.sha256}']!;
    for (final other in [otherFamily, otherMember]) {
      transport.objects['/v1/families/${other.familyID}/members/${other.memberID}/objects/${resource.sha256}'] = originalBytes;
    }
    final second = await client.loadResource(scope: otherFamily, resource: resource, cacheParent: cache);
    final third = await client.loadResource(scope: otherMember, resource: resource, cacheParent: cache);
    final otherGateway = FamilyArchiveClient(origin: Uri.parse('https://second.example.invalid'),
      accessToken: () async => 'synthetic-session', transport: transport);
    final fourth = await otherGateway.loadResource(scope: scope, resource: resource, cacheParent: cache);
    expect({first, second, third, fourth}, hasLength(4));
    expect(transport.mediaDownloads, 4);
  });

  test('resource pause cleans only owned partial; revocation after GET blocks new exposure', () async {
    await client.publishManifest(manifest, sourceFiles: sources);
    final resource = manifest.records.single.assets.first.resources.first;
    final cache = Directory('${workspace.path}/media-cache');
    var paused = false;
    transport.duringDownload = () => paused = true;
    await expectLater(client.loadResource(scope: scope, resource: resource, cacheParent: cache,
      shouldPause: () => paused), fails(FamilyArchiveClientFailure.paused));
    expect(cache.listSync(recursive: true).whereType<File>(), isEmpty);
    paused = false;
    transport.duringDownload = () => transport.revoked = true;
    await expectLater(client.loadResource(scope: scope, resource: resource, cacheParent: cache),
      fails(FamilyArchiveClientFailure.denied));
    expect(cache.listSync(recursive: true).whereType<File>()
      .any((file) => file.path.endsWith('.part')), isFalse);
  });

  test('resource cache refuses user-controlled symlinks', () async {
    await client.publishManifest(manifest, sourceFiles: sources);
    final resource = manifest.records.single.assets.first.resources.first;
    final actual = Directory('${workspace.path}/actual-cache')..createSync();
    final link = Link('${workspace.path}/cache-alias')..createSync(actual.path);
    await expectLater(client.loadResource(scope: scope, resource: resource, cacheParent: Directory(link.path)),
      fails(FamilyArchiveClientFailure.invalidPath));
    expect(actual.listSync(), isEmpty);
  });

  test('resource cache accepts fixed iOS/macOS /var system alias', () async {
    await client.publishManifest(manifest, sourceFiles: sources);
    final resource = manifest.records.single.assets.first.resources.first;
    final real = workspace.resolveSymbolicLinksSync();
    final alias = real.replaceFirst('/private/var/', '/var/');
    final result = await client.loadResource(scope: scope, resource: resource,
      cacheParent: Directory('$alias/media-cache'));
    expect(Digest.sha256Hex(File(result).readAsBytesSync()), resource.sha256);
  }, skip: !Platform.isIOS && !Platform.isMacOS);
}
