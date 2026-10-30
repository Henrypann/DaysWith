import 'dart:convert';
import 'dart:typed_data';

import 'package:jinbao_core/jinbao_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Port of ios-app/Tests/JinbaoCoreTests/ContractTests.swift.
void main() {
  const id = '643C9BAE-C2F8-42F7-BE24-119076330069';
  const deviceA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const deviceB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  final a64 = 'a' * 64;

  V1Manifest sampleManifest() => V1Manifest(
        moments: [
          V1Moment(id: id, note: '中文 / café 👕\n\t"\\', occurredAt: 1, createdAt: 2, updatedAt: 3, assetIDs: [id])
        ],
        assets: [V1Asset(id: id, kind: 'photo', capturedAt: 0, resourceIDs: [id])],
        resources: [
          V1Resource(
              id: id,
              assetID: id,
              role: 'photo',
              contentType: 'image/jpeg',
              originalFilename: 'IMG/中文.jpg',
              byteCount: 8,
              sha256: a64,
              objectKey: 'life/v1/android/objects/aa/$a64')
        ],
      );

  V1Manifest textManifest(String id, String note, int updatedAt, {int? trashedAt}) => V1Manifest(moments: [
        V1Moment(
            id: id,
            note: note,
            occurredAt: updatedAt,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            assetIDs: [],
            trashedAt: trashedAt,
            revision: 1)
      ]);

  void publish(MemoryCos memory, String prefix, String writer, int moment, String note, int updatedAt) {
    final bytes = V1Json.encodeManifest(textManifest(uuid(moment), note, updatedAt));
    final hash = Digest.sha256Hex(bytes);
    memory.objects['${prefix}snapshots/$hash.json'] = bytes;
    final commit = V1Commit(
        sequence: 1,
        writerDeviceID: writer,
        manifestHash: hash,
        manifestKey: '${prefix}snapshots/$hash.json',
        createdAt: updatedAt,
        requestID: uuid(99));
    memory.objects[prefix + V1Json.commitRelativeKey(1)] = V1Json.encodeCommit(commit);
  }

  LocalAsset photoAsset() {
    final hash = Digest.sha256Hex(utf8.encode('original'));
    final preview = Digest.sha256Hex(utf8.encode('preview'));
    return LocalAsset(
      id: uuid(40),
      kind: 'photo',
      capturedAt: 0,
      provenance: ImportProvenance.verifiedOriginal.rawValue,
      resources: [
        LocalResource(
            id: uuid(41),
            role: 'photo',
            contentType: 'image/jpeg',
            originalFilename: 'original.jpg',
            byteCount: 8,
            sha256: hash,
            relativePath: 'media/original.jpg'),
        LocalResource(
            id: uuid(42),
            role: 'preview',
            contentType: 'image/jpeg',
            originalFilename: 'preview.jpg',
            byteCount: 7,
            sha256: preview,
            relativePath: 'media/preview.jpg'),
      ],
    );
  }

  TimelineEntry entry(String id, int occurredAt, ParentIdentity parent) => TimelineEntry(
      id: id,
      title: '',
      note: id,
      occurredAt: occurredAt,
      parent: parent,
      readOnly: false,
      mediaCount: 0,
      previewPath: null,
      provenanceLabel: null);

  test('digests and UUID version 5', () {
    expect(Digest.sha256Hex([]), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(Digest.hex(Digest.sha1([])), 'da39a3ee5e6b4b0d3255bfef95601890afd80709');
    expect(V1Ids.uuidV5(namespace: '6ba7b810-9dad-11d1-80b4-00c04fd430c8', name: 'python.org'),
        '886313e1-3b8a-5372-9b90-0c9aee199e5d');
    expect(V1Ids.namespace, '6F0F3B0E-6B2F-5C55-9E57-0D365A7D0001');
    expect(V1Ids.map(kind: 'record', localID: 'local-123'), '729821C3-92EC-547D-8423-E0A85BAA6A11');
    expect(V1Ids.map(kind: 'asset', localID: 'local-123'), '9ED6C522-4F56-55C6-99FE-D50CDA4FC5A7');
    expect(V1Ids.map(kind: 'resource', localID: 'local-123'), 'D4551570-A072-5141-915E-C4D2662C4CC1');
    expect(V1Ids.map(kind: 'record', localID: id.toLowerCase()), id);
    expect(V1Ids.map(kind: 'record', localID: 'rec-$id'), id);
    expect(() => V1Ids.map(kind: 'device', localID: 'id'), throwsA(isA<ContractError>()));
    expect(() => V1Ids.legacyID(kind: 'record', localID: id), throwsA(isA<ContractError>()));
  });

  test('commit matches Android wire format', () {
    final commit = V1Commit(
        sequence: 1,
        writerDeviceID: id,
        manifestHash: a64,
        manifestKey: 'life/v1/android/snapshots/$a64.json',
        createdAt: 123,
        requestID: id);
    final expected = '{"createdAt":123,"kind":"snapshot","manifestHash":"$a64",'
        '"manifestKey":"life/v1/android/snapshots/$a64.json","requestID":"$id","sequence":1,"version":1,'
        '"writerDeviceID":"$id"}';
    final bytes = V1Json.encodeCommit(commit);
    expect(utf8.decode(bytes), expected);
    expect(V1Json.decodeCommit(bytes), commit);
    expect(V1Json.commitRelativeKey(1), 'commits/00000000000000000001.json');
    expect(V1Json.commitRelativeKey(9223372036854775807), 'commits/09223372036854775807.json');
  });

  test('manifest round trip ignores unknown keys and sorts', () {
    final manifest = sampleManifest();
    final bytes = V1Json.encodeManifest(manifest);
    final text = utf8.decode(bytes);
    expect(V1Json.decodeManifest(bytes), manifest);
    expect(V1Json.encodeManifest(V1Json.decodeManifest(bytes)), bytes);
    expect(text, contains('"title":""'));
    expect(text, contains('中文 / café 👕'));
    expect(text, contains(r'\n\t\"\\'));
    expect(text, isNot(contains(r'\/')));
    expect(text, isNot(contains('\\u' '4e2d')));
    expect(text, isNot(contains('trashedAt')));
    expect(text, isNot(contains(': ')));
    expect(text, isNot(contains(', ')));
    expect(text, isNot(contains('\n')));
    final invalid = [
      text.replaceAll('"version":1', '"version":"1"'),
      text.replaceAll('"version":1', '"version":1.0'),
      text.replaceAll('"revision":0', '"revision":9223372036854775808'),
      text.replaceAll(id, 'not-a-uuid'),
      text.replaceAll('"title":"",', ''),
      text.replaceAll('"note":', '"renamedNote":'),
    ];
    for (final sample in invalid) {
      expect(() => V1Json.decodeManifest(utf8.encode(sample)), throwsA(isA<ContractError>()), reason: sample);
    }
    final extra = '${text.substring(0, text.length - 1)},"future":{"anything":true}}';
    expect(V1Json.decodeManifest(utf8.encode(extra)), manifest);
    expect(V1Json.decodeManifest(utf8.encode(text.replaceAll(id, id.toLowerCase()))), manifest);
    expect(() => V1Json.decodeManifest([0xc3, 0x28]), throwsA(isA<ContractError>()));
    expect(() => V1Json.decodeManifest(Uint8List(JsonWire.metadataLimit + 1)), throwsA(isA<ContractError>()));
  });

  test('ignore list skips objects and snapshot-only prefixes', () {
    final chain = V1Layout.chainPrefix(parent: ParentIdentity.dad, deviceID: deviceA, test: false);
    expect(V1Layout.objectRoot(chain), 'life/v1/dad/');
    expect(V1Layout.objectKey(prefix: chain, sha256: 'ab' * 32), 'life/v1/dad/objects/ab/${'ab' * 32}');
    expect(V1Layout.objectRoot(V1Layout.chainPrefix(parent: ParentIdentity.mom, deviceID: deviceA, test: true)),
        'life/v1/test/');
    for (final parent in ParentIdentity.values) {
      final testChain = V1Layout.chainPrefix(parent: parent, deviceID: deviceA, test: true);
      expect(testChain, 'life/v1/test/$deviceA/');
    }
    final listed = [
      'life/v1/dad/commits/00000000000000000001.json',
      'life/v1/dad/snapshots/x.json',
      'life/v1/dad/objects/ab/abc',
      'life/v1/dad/$deviceA/commits/00000000000000000001.json',
      'life/v1/dad/$deviceA/commits/00000000000000000002.json',
      'life/v1/dad/$deviceB/snapshots/only.json',
      'life/v1/mom/commits/00000000000000000001.json',
    ];
    expect(V1Layout.chainsUnder(root: 'life/v1/dad/', keys: listed), ['life/v1/dad/', 'life/v1/dad/$deviceA/']);
    expect(V1Layout.owns(owner: ParentIdentity.dad, prefix: 'life/v1/dad/'), isTrue);
    expect(V1Layout.owns(owner: ParentIdentity.dad, prefix: 'life/v1/test/$deviceA/'), isTrue);
    expect(V1Layout.owns(owner: ParentIdentity.dad, prefix: 'life/v1/mom/'), isFalse);
  });

  test('signer matches shared vector and never prints the key', () {
    const signer = CosSigner(StorageCredentials(secretID: 'AKIDExample', secretKey: 'ExampleSecretKey'));
    expect(
      signer.authorization(
        method: 'PUT',
        path: '/life/v1/photos/球衣(1).heic',
        query: {'uploadId': 'a+/=', 'partNumber': '2'},
        headers: {
          'Host': 'ootd365-life-1234567890.cos.ap-shanghai.myqcloud.com',
          'Content-Type': 'image/heic',
          'x-cos-forbid-overwrite': 'true',
          'x-cos-server-side-encryption': 'AES256',
        },
        now: 1700000000,
      ),
      'q-sign-algorithm=sha1&q-ak=AKIDExample&q-sign-time=1699999940;1700000900&q-key-time=1699999940;1700000900'
      '&q-header-list=content-type;host;x-cos-forbid-overwrite;x-cos-server-side-encryption'
      '&q-url-param-list=partnumber;uploadid&q-signature=f0b1a7e8aab81b273bf8d8095731fbe39627adee',
    );
    const temporary =
        StorageCredentials(secretID: 'AKIDSynthetic_-', secretKey: '+/8AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0=');
    expect(
      const CosSigner(temporary).authorization(
          method: 'GET',
          path: '/life/v1/mom/objects/synthetic',
          headers: {'Host': 'example.cos.ap-shanghai.myqcloud.com'},
          now: 1700000000),
      'q-sign-algorithm=sha1&q-ak=AKIDSynthetic_-&q-sign-time=1699999940;1700000900&q-key-time=1699999940;1700000900'
      '&q-header-list=host&q-url-param-list=&q-signature=e319acc461e2e3cb1a321fdd6e6a608147d8fb2f',
    );
    expect(temporary.toString(), 'StorageCredentials(redacted)');
    expect(signer.toString(), isNot(contains('ExampleSecretKey')));
    expect(
        () => const CosSigner(temporary)
            .authorization(method: 'GET', path: '/', headers: {'Host': 'x', 'host': 'y'}, now: 1700000000),
        throwsA(isA<CosFailure>()));
    expect(StorageCredentials.validID('AKID+'), isFalse);
    expect(StorageCredentials.validKey('AKID+'), isTrue);
    expect(const StorageConfiguration(bucket: 'example-1234567890').host, 'example-1234567890.cos.ap-shanghai.myqcloud.com');
    expect(() => const StorageConfiguration(bucket: 'BUCKET-12345').validate(), throwsA(isA<ContractError>()));
    expect(() => const StorageConfiguration(bucket: 'example-1234567890', prefix: 'life/../').validate(), throwsA(isA<ContractError>()));
  });

  test('temporary token travels with every request and is covered by the signature', () async {
    const credentials = StorageCredentials(
        secretID: 'AKIDSynthetic', secretKey: 'SyntheticKey', sessionToken: 'SyntheticToken+/=:', expiresAt: 1700000120);
    final memory = MemoryCos();
    final client = CosClient(
        configuration: const StorageConfiguration(bucket: 'example-1234567890'),
        credentials: credentials,
        transport: memory,
        now: () => 1700000000);
    const key = 'life/v1/test/synthetic.json';
    await client.put(key: key, body: utf8.encode('synthetic'), contentType: 'application/json');
    await client.list(prefix: 'life/v1/test/');
    await client.get(key: key);
    expect(memory.requests.map((r) => r.method).toSet(), {'GET', 'HEAD', 'PUT'});
    for (final request in memory.requests) {
      expect(request.headers['x-cos-security-token'], credentials.sessionToken);
      final authorization = request.headers['Authorization']!;
      expect(authorization, contains('x-cos-security-token'));
      expect(authorization, contains('q-sign-time=1699999940;1700000120&'));
      final headers = Map<String, String>.of(request.headers)..remove('Authorization');
      expect(
          const CosSigner(credentials).authorization(
              method: request.method, path: request.path, query: request.query, headers: headers, now: 1700000000),
          authorization);
    }
  });

  test('expired temporary credentials never reach transport', () async {
    var clock = 1700000000;
    final memory = MemoryCos();
    final client = CosClient(
      configuration: const StorageConfiguration(bucket: 'example-1234567890'),
      credentials: StorageCredentials(
          secretID: 'AKIDSynthetic', secretKey: 'SyntheticKey', sessionToken: 'SyntheticToken', expiresAt: clock + 1),
      transport: memory,
      now: () => clock,
    );
    clock += 1;
    expect(await throwsOf(() => client.list(prefix: 'life/v1/dad/')),
        const CosFailure(ConnectionFailure.expiredCredentials));
    expect(await throwsOf(() => client.put(key: 'life/v1/test/synthetic', body: [], contentType: 'text/plain')),
        const CosFailure(ConnectionFailure.expiredCredentials));
    expect(memory.requests, isEmpty);
  });

  test('long-term credentials add no token; token validation rejects header injection', () async {
    final memory = MemoryCos();
    final client = memoryClient(memory);
    await client.list(prefix: 'life/v1/mom/');
    expect(memory.requests.first.headers['x-cos-security-token'], isNull);
    expect(memory.requests.first.headers['Authorization'], isNot(contains('x-cos-security-token')));
    expect(StorageCredentials.validSessionToken('A' * 16384), isTrue);
    for (final token in ['', 'synthetic\r\nInjected:header', 'synthetic\n', 'with space', '\u007f', 'A' * 16385]) {
      expect(StorageCredentials(secretID: 'AKIDSynthetic', secretKey: 'SyntheticKey', sessionToken: token).isValid,
          isFalse);
    }
    expect(const StorageCredentials(secretID: 'AKIDSynthetic', secretKey: 'SyntheticKey', expiresAt: 0).isValid, isFalse);
  });

  test('keychain service is not shared with OOTD', () {
    expect(CredentialStoreContract.keychainService, 'com.henrypann.jinbao365.credentials');
    expect(CredentialStoreContract.bundleIdentifier, 'com.henrypann.jinbao365');
    expect(CredentialStoreContract.displayName, 'DaysWith');
  });

  test('month titles always include the year', () {
    final months = JinbaoCalendar.months([
      entry('a', millis(2026, 10, 18), ParentIdentity.dad),
      entry('b', millis(2026, 1, 2), ParentIdentity.mom),
      entry('c', millis(2025, 12, 31), ParentIdentity.dad),
    ], FixedOffsetZone.utc);
    expect(months.map((m) => m.title), ['2026年10月', '2026年1月', '2025年12月']);
    expect(TimelineMonth.titleFor(year: 2026, month: 10), '2026年10月');
  });

  test('placeholder timeline then text and photo draft', () {
    final session = AppSession(deviceID: deviceA, testBuild: true);
    expect(session.phase, AppPhase.chooseIdentity);
    session.confirmIdentity(ParentIdentity.dad);
    expect(session.phase, AppPhase.connectCloud);
    expect(() => session.confirmIdentity(ParentIdentity.mom), throwsA(isA<ContractError>()));
    session.confirmIdentity(ParentIdentity.dad);
    session.connectPlaceholder(bucket: 'example-1234567890', region: 'ap-shanghai');
    expect(session.phase, AppPhase.timeline);
    expect(session.months(FixedOffsetZone.utc), isEmpty);
    final when = millis(2026, 10, 18);
    session.beginDraft(now: when);
    session.updateDraft(title: '', note: '今天会说谢谢');
    final saved = session.commitDraft(now: when);
    expect(saved.parent, ParentIdentity.dad);
    expect(saved.uploadEligibility, UploadEligibility.localOnly);
    expect(session.draft, isNull);
    final months = session.months(FixedOffsetZone.utc);
    expect(months.map((m) => m.title), ['2026年10月']);
    expect(months[0].days[0].moments[0].note, '今天会说谢谢');
    expect(months[0].days[0].moments[0].readOnly, isFalse);

    session.beginDraft(now: when);
    session.addAsset(photoAsset());
    final photo = session.commitDraft(now: when + 1);
    expect(photo.assets.length, 1);
    expect(session.timelineEntries().firstWhere((e) => e.id == photo.id).provenanceLabel, '已确认原件');
    expect(session.writerPrefix(), 'life/v1/test/$deviceA/');
    expect(session.objectRoot(), 'life/v1/test/');
    final persisted = jsonEncode(PersistedArchive.fromSession(session).toJson());
    expect(persisted, isNot(contains('secret')));
    expect(() => BackupPlan.manifest(session, now: when), throwsA(isA<ContractError>()));
  });

  test('merge keeps newest parent copy and hides newer deletion', () {
    final older = ChainSnapshot(
        parent: ParentIdentity.mom,
        prefix: 'life/v1/mom/',
        writer: uuid(70),
        createdAt: 10,
        manifest: textManifest(uuid(1), '旧版', 10));
    final newer = ChainSnapshot(
        parent: ParentIdentity.mom,
        prefix: 'life/v1/mom/$deviceB/',
        writer: uuid(71),
        createdAt: 15,
        manifest: textManifest(uuid(1), '新版', 15));
    final sibling = ChainSnapshot(
        parent: ParentIdentity.dad,
        prefix: 'life/v1/dad/$deviceB/',
        writer: uuid(74),
        createdAt: 10,
        manifest: textManifest(uuid(4), '爸爸另一台', 10));
    final merged = ArchiveMerge.merge([older, newer, sibling]);
    expect(merged.map((m) => m.note).toSet(), {'新版', '爸爸另一台'});
    expect(merged.firstWhere((m) => m.note == '新版').parent, ParentIdentity.mom);
    expect(merged.every((m) => m.readOnly), isTrue);
    final deleted = ChainSnapshot(
        parent: ParentIdentity.mom,
        prefix: 'life/v1/mom/$deviceB/',
        writer: uuid(71),
        createdAt: 20,
        manifest: textManifest(uuid(1), '旧版', 20, trashedAt: 20));
    expect(ArchiveMerge.merge([older, deleted]), isEmpty);
  });

  test('family read skips this device and test backup never touches parents', () async {
    final memory = MemoryCos();
    final selfID = uuid(80);
    publish(memory, ParentIdentity.mom.prefix, uuid(70), 1, '旧版', 1700000000000);
    publish(memory, '${ParentIdentity.mom.prefix}${uuid(71)}/', uuid(71), 1, '新版', 1700000000005);
    publish(memory, '${ParentIdentity.dad.prefix}$selfID/', selfID, 5, '本机', 1700000000000);
    publish(memory, ParentIdentity.dad.prefix, uuid(73), 3, '爸爸旧链', 1700000000000);
    final remote =
        await FamilyReader.read(memoryClient(memory), owner: ParentIdentity.dad, deviceID: selfID, testBuild: false);
    expect(remote.map((m) => m.note).toSet(), {'新版', '爸爸旧链'});
    expect(memory.requests.every((r) => r.method != 'PUT'), isTrue);

    final session = AppSession(
        deviceID: deviceA,
        testBuild: true,
        identity: ParentIdentity.dad,
        link: const CloudVerified(bucket: 'example-1234567890', region: 'ap-shanghai'));
    final when = millis(2026, 10, 18);
    session.beginDraft(now: when);
    session.updateDraft(title: '一句', note: '');
    expect(session.commitDraft(now: when).uploadEligibility, UploadEligibility.testOnly);
    final writer = MemoryCos();
    final client = memoryClient(writer, prefix: session.writerPrefix());
    final first = await BackupPublisher.publishBytes(client, session, files: {}, now: when, requestID: uuid(90));
    expect(first.sequence, 1);
    expect(first.writerDeviceID, deviceA.toUpperCase());
    final puts = writer.requests.where((r) => r.method == 'PUT').toList();
    expect(puts, isNotEmpty);
    for (final request in puts) {
      expect(request.headers['x-cos-forbid-overwrite'], 'true');
      expect(request.headers['x-cos-server-side-encryption'], 'AES256');
      expect(request.path.substring(1), startsWith('life/v1/test/$deviceA/'));
    }
    final second = await BackupPublisher.publishBytes(client, session, files: {}, now: when + 1, requestID: uuid(91));
    expect(second.sequence, 2);
    expect(writer.requests.any((r) => r.method == 'HEAD'), isTrue);
  });
}
