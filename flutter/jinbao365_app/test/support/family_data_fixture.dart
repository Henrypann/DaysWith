import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:jinbao365/family_data_controller.dart';
import 'package:jinbao_core/jinbao_core.dart';

String familyTestID(int value) => '00000000-0000-4000-8000-${value.toRadixString(16).padLeft(12, '0').toUpperCase()}';

class FamilyDataFixture {
  final Directory root;
  late AppSession session;
  late FamilyGatewayClient client;
  final gateway = SyntheticFamilyTransport();
  final archive = SyntheticArchiveTransport();
  final Family family = Family(id: familyTestID(1), name: '合成家庭');
  List<ConnectivityResult> network = [ConnectivityResult.wifi];
  String? sessionToken = 'synthetic-session';
  FamilyDataFixture(this.root) {
    session = AppSession(deviceID: familyTestID(3), testBuild: true, identity: ParentIdentity.dad,
      moments: [moment(10, '本机冻结记录')], anniversaries: [LocalAnniversary(
        id: familyTestID(20), owner: ParentIdentity.dad, title: '合成纪念日', date: '0004-02-29', updatedAt: 1)]);
    client = FamilyGatewayClient(origin: Uri.parse('https://family.example.invalid'),
      accessToken: () async => sessionToken, transport: gateway);
  }
  static LocalMoment moment(int id, String title, {ParentIdentity parent = ParentIdentity.dad}) => LocalMoment(
    id: familyTestID(id), title: title, note: '合成文字', occurredAt: 1700000000000,
    createdAt: 1700000000000, updatedAt: 1700000000001, parent: parent, assets: []);
  FamilyDataController controller({bool wifiOnlyUploads = true,
      Future<List<ConnectivityResult>> Function()? connectivityCheck, String? localDirectory}) => FamilyDataController(
    client: client, selectedFamily: family, currentLocalSession: () => session,
    localDirectory: localDirectory ?? root.path,
    archiveClient: client.createArchiveClient(transport: archive),
    wifiOnlyUploads: wifiOnlyUploads, connectivityCheck: connectivityCheck ?? () async => network);
  void addSyntheticMedia({int count = 1}) {
    final assets = <LocalAsset>[];
    Directory('${root.path}/media').createSync();
    for (var n = 0; n < count; n++) {
      final resources = <LocalResource>[];
      for (var variant = 0; variant < 2; variant++) {
        final role = variant == 1 ? 'preview' : n == 10 ? 'video' : 'photo';
        final bytes = utf8.encode('synthetic-original-$n-$variant');
        final relative = 'media/source-$n-$variant';
        File('${root.path}/$relative').writeAsBytesSync(bytes);
        resources.add(LocalResource(id: familyTestID(100 + n * 2 + variant), role: role,
          contentType: role == 'video' ? 'video/mp4' : 'image/jpeg', originalFilename: 'synthetic-$n-$variant',
          byteCount: bytes.length, sha256: Digest.sha256Hex(bytes), relativePath: relative));
      }
      assets.add(LocalAsset(id: familyTestID(50 + n), kind: n == 10 ? 'video' : 'photo',
        capturedAt: 1700000000000, provenance: ImportProvenance.verifiedOriginal.rawValue, resources: resources));
    }
    session.moments.first.assets = assets;
  }
  File stateFile(String name) => root.listSync(recursive: true).whereType<File>()
      .firstWhere((file) => file.path.endsWith('/$name'));
}

class SyntheticFamilyTransport implements FamilyGatewayTransport {
  bool offline = false;
  int responseStatus = 200;
  String memberID = familyTestID(2);
  String subjectID = 'synthetic-parent';
  String storageID = 'gateway:${familyTestID(1000)}';
  String role = 'admin';
  FutureOr<void> Function(FamilyGatewayRequest)? before;
  Map<String, Object?> member({String? id, String? name}) => {
    'id': id ?? memberID, 'familyID': familyTestID(1), 'subjectID': subjectID,
    'displayName': name ?? '合成家人', 'relationshipLabel': '爸爸', 'role': role,
    'status': 'active', 'deviceIDs': [familyTestID(3)],
  };
  @override
  Future<FamilyGatewayResponse> send(FamilyGatewayRequest request) async {
    await before?.call(request);
    if (offline) throw const SocketException('synthetic offline');
    if (responseStatus != 200) return FamilyGatewayResponse(statusCode: responseStatus,
      body: JsonWire.encode({'error': responseStatus == 401 ? 'unauthenticated' : 'denied'}));
    return FamilyGatewayResponse(statusCode: 200, body: JsonWire.encode({
      'family': {'id': familyTestID(1), 'name': '合成家庭', 'primaryStorageID': storageID},
      'members': [member()], 'currentMember': member(),
    }));
  }
}

class SyntheticArchiveTransport implements FamilyArchiveTransport {
  final requests = <FamilyArchiveRequest>[];
  final descriptors = <FamilyArchiveSnapshot>[];
  final manifests = <String, List<int>>{};
  final objects = <String, List<int>>{};
  final moderationEvents = <Map<String, Object?>>[];
  int moderationVersion = 0;
  bool offline = false;
  int downloads = 0;
  int? failDownload;
  FutureOr<void> Function(FamilyArchiveRequest)? before;

  void seed(FamilyArchiveManifest manifest) {
    final descriptor = FamilyArchiveSnapshot(scope: manifest.scope, sequence: manifest.sequence,
      sha256: manifest.sha256, byteCount: manifest.encode().length);
    if (!descriptors.any((d) => d.key == descriptor.key)) descriptors.add(descriptor);
    manifests[_path(descriptor)] = manifest.encode();
  }
  String _path(FamilyArchiveSnapshot snapshot) => '/v1/families/${snapshot.scope.familyID}/members/'
      '${snapshot.scope.memberID}/devices/${snapshot.scope.deviceID}/snapshots/${snapshot.sequence}/${snapshot.sha256}';
  FamilyArchiveResponse json(Object? data, {int status = 200}) => FamilyArchiveResponse(statusCode: status, body: JsonWire.encode(data));
  @override
  Future<FamilyArchiveResponse> send(FamilyArchiveRequest request) async {
    requests.add(request);
    await before?.call(request);
    if (offline) throw const SocketException('synthetic archive offline');
    if (request.shouldPause?.call() ?? false) throw const FamilyArchiveClientException(FamilyArchiveClientFailure.paused);
    final path = request.uri.path;
    if (path.endsWith('/archive')) return json({'snapshots': descriptors.map((d) => d.toJson()).toList(),
      'nextCursor': null, 'moderations': moderationEvents, 'moderationVersion': moderationVersion});
    if (path.endsWith('/moderation')) {
      final parts = path.split('/');
      final body = jsonDecode(utf8.decode(request.body)) as Map;
      final event = <String, Object?>{'id': ++moderationVersion, 'familyID': parts[3],
        'ownerMemberID': parts[5], 'recordID': parts[7], 'hidden': body['hidden'],
        'recordRevision': body['expectedRevision'], 'at': 1700000000000, 'actorMemberID': familyTestID(2)};
      moderationEvents.removeWhere((old) => old['ownerMemberID'] == parts[5] && old['recordID'] == parts[7]);
      moderationEvents.add(event);
      return json(event);
    }
    if (path.contains('/objects/')) {
      if (request.method == 'PUT') {
        final bytes = File(request.sourceFile!).readAsBytesSync();
        objects[path] = bytes;
        return json({'ok': true});
      }
      final bytes = objects[path];
      if (bytes == null) return json({'error': 'notFound'}, status: 404);
      final headers = {'Content-Length': '${bytes.length}', 'X-Content-SHA256': Digest.sha256Hex(bytes)};
      if (request.method == 'HEAD') return FamilyArchiveResponse(statusCode: 200, headers: headers);
      downloads++;
      if (downloads == failDownload) throw const SocketException('synthetic interrupted download');
      File(request.destinationFile!).writeAsBytesSync(bytes, flush: true);
      return FamilyArchiveResponse(statusCode: 200, headers: headers);
    }
    if (path.contains('/snapshots/')) {
      if (request.method == 'PUT') {
        final data = jsonDecode(utf8.decode(request.body)) as Map;
        final manifest = FamilyArchiveManifest.decode(request.body, expectedScope: FamilyArchiveScope(
          familyID: data['familyID'] as String, memberID: data['memberID'] as String, deviceID: data['deviceID'] as String));
        seed(manifest);
        return json(descriptors.firstWhere((d) => d.key == '${manifest.scope.memberID}/${manifest.scope.deviceID}/${manifest.sequence}').toJson());
      }
      final body = manifests[path];
      return body == null ? json({'error': 'notFound'}, status: 404) : FamilyArchiveResponse(statusCode: 200, body: body);
    }
    if (request.method == 'POST' && path.contains('/devices/')) return json({'ok': true});
    return json({'error': 'notFound'}, status: 404);
  }
}
