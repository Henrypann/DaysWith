import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/app_model.dart';
import 'package:jinbao_core/jinbao_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _endpoint = 'https://nas.example/DaysWith/';
const _device = '11111111-1111-4111-8111-111111111111';

AppSession _initial() => AppSession(deviceID: _device, testBuild: true)
  ..confirmIdentity(ParentIdentity.dad)
  ..link = const CloudWebDav(name: 'Synthetic NAS', endpoint: _endpoint, accountScope: 'account-a');

void _record(AppSession session, String title) {
  session.beginDraft(now: 1700000000000);
  session.updateDraft(title: title, note: 'Synthetic offline record');
  session.commitDraft(now: 1700000000001);
}

class _MemoryProvider extends StorageProvider {
  @override
  final StorageIdentity identity;
  final Map<String, Uint8List> objects;
  _MemoryProvider(String prefix, this.objects, {String account = 'account-a'})
      : identity = StorageIdentity(providerId: 'webdav', endpoint: _endpoint, prefix: prefix, accountScope: account);
  @override
  StorageCapabilities get capabilities => const StorageCapabilities(
      conditionalWrites: true, versioning: StorageVersioning.unknown, nativePagination: false);
  @override
  Future<void> connect() async {}
  @override
  Future<void> healthCheck() async {}
  @override
  Future<void> verifyImmutableWritesAllowed() async {}
  @override
  Future<StorageListPage> listPage({required String prefix, String? cursor, int limit = 1000}) async =>
      storageSnapshotPage(objects.keys.where((key) => key.startsWith(prefix)).toList(), prefix, cursor, limit);
  @override
  Future<ObjectHead?> stat(String key) async {
    final bytes = objects[key];
    return bytes == null ? null : ObjectHead(byteCount: bytes.length, sha256: Digest.sha256Hex(bytes));
  }
  @override
  Future<Uint8List> get({required String key, int responseLimit = 32 * 1024 * 1024}) async {
    final bytes = objects[key];
    if (bytes == null || bytes.length > responseLimit) {
      throw const StorageProviderFailure(StorageProviderFailureKind.notFound);
    }
    return bytes;
  }
  @override
  Future<void> getFile({required String key, required String destination, required int byteCount, required String sha256}) async {
    final bytes = await get(key: key);
    if (bytes.length != byteCount || Digest.sha256Hex(bytes) != sha256) {
      throw const StorageProviderFailure(StorageProviderFailureKind.integrity);
    }
    await File(destination).writeAsBytes(bytes);
  }
  @override
  Future<void> putImmutable({required String key, required List<int> body, required String contentType}) async {
    final prior = objects[key];
    if (prior != null && Digest.sha256Hex(prior) != Digest.sha256Hex(body)) {
      throw const StorageProviderFailure(StorageProviderFailureKind.conflict);
    }
    objects[key] = Uint8List.fromList(body);
  }
  @override
  Future<void> putImmutableFile({required String key, required String filePath, required int byteCount, required String sha256, required String contentType}) async =>
      putImmutable(key: key, body: await File(filePath).readAsBytes(), contentType: contentType);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late SharedPreferences preferences;
  late Map<String, Uint8List> objects;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('dayswith-upload-intent-');
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    objects = {};
  });
  tearDown(() => folder.delete(recursive: true));

  AppModel model({AppSession? session, Future<List<ConnectivityResult>> Function()? network,
    Future<void> Function(String?)? persist}) {
    final value = AppModel(
      connectivityCheck: network ?? () async => [ConnectivityResult.wifi],
      uploadIntentPersistence: persist,
      providerFactory: (link, prefix) => _MemoryProvider(prefix, objects, account: link.storageIdentity!.accountScope!),
    )..initializeForTesting(path: folder.path, initial: session ?? _initial(), preferences: preferences);
    addTearDown(value.dispose);
    return value;
  }

  test('pause wins while consent persistence is still in flight and survives restart', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var networkCalls = 0;
    final value = model(persist: (target) async {
      if (target != null) { entered.complete(); await release.future; }
    }, network: () async { networkCalls++; return [ConnectivityResult.wifi]; });
    _record(value.session, 'approved');
    final upload = value.backupNow();
    await entered.future;
    value.pauseBackup();
    release.complete();
    await upload;
    await value.pendingUploadIntentWrite;
    expect(preferences.getString('backupRequestedFor'), isNull);
    expect(value.pendingStorageCount, 0);
    expect(networkCalls, 0);
    final restored = ArchiveStore('${folder.path}/archive.json').load()!.session();
    final reopened = model(session: restored, network: () async { networkCalls++; return [ConnectivityResult.wifi]; });
    reopened.activate();
    await Future<void>.delayed(Duration.zero);
    expect(networkCalls, 0, reason: 'Activation cannot resurrect paused consent.');
    expect(objects, isEmpty);
  });

  test('durable pause blocks restart even when preference removal fails', () async {
    var networkCalls = 0;
    final value = model(network: () async => [ConnectivityResult.none], persist: (target) async {
      if (target == null) throw StateError('Synthetic preference failure');
    });
    _record(value.session, 'approved');
    await value.backupNow();
    expect(preferences.getString('backupRequestedFor'), isNotNull);
    value.pauseBackup();
    await value.pendingUploadIntentWrite;
    final paused = ArchiveStore('${folder.path}/archive.json').load()!.session();
    expect(paused.uploadPaused, isTrue);
    expect(preferences.getString('backupRequestedFor'), isNotNull);
    final reopened = model(session: paused, network: () async { networkCalls++; return [ConnectivityResult.wifi]; });
    reopened.activate();
    await reopened.backupNow(includeLocalRecords: false);
    expect(networkCalls, 0);
    expect(reopened.backupStatusTitle, '备份已暂停');
    expect(objects, isEmpty);
  });

  test('synchronous listener pause is not cleared by the starting upload', () async {
    final value = model();
    _record(value.session, 'approved');
    var paused = false;
    value.addListener(() {
      if (value.backupRunning && !paused) {
        paused = true;
        value.pauseBackup();
      }
    });
    await value.backupNow();
    await value.pendingUploadIntentWrite;
    expect(value.session.uploadPaused, isTrue);
    expect(ArchiveStore('${folder.path}/archive.json').load()!.session().uploadPaused, isTrue);
    expect(preferences.getString('backupRequestedFor'), isNull);
    expect(objects, isEmpty);
  });

  test('failed archive pause save never displays a durable success', () async {
    final value = model();
    final archive = File('${folder.path}/archive.json');
    await archive.delete();
    await Directory(archive.path).create();
    value.pauseBackup();
    await value.pendingUploadIntentWrite;
    expect(value.session.uploadPaused, isTrue);
    expect(value.bannerIsError, isTrue);
    expect(value.banner, contains('暂停状态未能保存'));
    expect(objects, isEmpty);
  });

  test('pause during connectivity lookup performs no upload and clears durable consent', () async {
    final entered = Completer<void>();
    final network = Completer<List<ConnectivityResult>>();
    final value = model(network: () { entered.complete(); return network.future; });
    _record(value.session, 'approved');
    final upload = value.backupNow();
    await entered.future;
    value.pauseBackup();
    network.complete([ConnectivityResult.wifi]);
    await upload;
    await value.pendingUploadIntentWrite;
    expect(objects, isEmpty);
    expect(preferences.getString('backupRequestedFor'), isNull);
    expect(value.bannerIsError, isFalse);
  });

  test('same URL account switch during network wait never uploads approved data to new account', () async {
    final entered = Completer<void>();
    final network = Completer<List<ConnectivityResult>>();
    final value = model(network: () { entered.complete(); return network.future; });
    _record(value.session, 'approved for a');
    final upload = value.backupNow();
    await entered.future;
    value.session.link = const CloudWebDav(name: 'Other account', endpoint: _endpoint, accountScope: 'account-b');
    network.complete([ConnectivityResult.wifi]);
    await upload;
    expect(objects, isEmpty);
    expect(value.bannerIsError, isTrue);
    expect(value.backupStatusTitle, '尚未备份');
  });

  test('offline restart resumes only the frozen approved snapshot', () async {
    final value = model(network: () async => [ConnectivityResult.none]);
    _record(value.session, 'approved');
    final approvedID = value.session.moments.single.id;
    await value.backupNow();
    expect(preferences.getString('backupRequestedFor'), isNotNull);
    final pending = ArchiveStore('${folder.path}/pending-upload.json').load()!.session();
    expect(pending.moments.map((m) => m.id), [approvedID]);
    _record(value.session, 'created after approval');
    final reopened = model(session: value.session.copy());
    await reopened.backupNow(includeLocalRecords: false);
    expect(reopened.session.backupJob?.status, BackupJobStatus.completed);
    final frozen = ArchiveStore('${folder.path}/pending-upload.json').load()!.session();
    expect(frozen.moments.map((m) => m.id), [approvedID]);
    expect(reopened.session.moments, hasLength(2));
    expect(reopened.backupStatusTitle, '有新的内容待备份');
    expect(preferences.getString('backupRequestedFor'), isNull);
  });

  test('cancelled connection configuration invalidates an in-flight verification', () async {
    // Cancellation increments the connection generation when verification owns
    // the busy lock. It must not mutate the current approved target or records.
    final value = model();
    _record(value.session, 'kept local');
    final link = value.session.link;
    value.busy = true;
    value.bucket = 'unconfirmed-1234567890';
    value.cancelCloudConfiguration();
    expect(value.session.link, same(link));
    expect(value.session.moments.single.title, 'kept local');
    expect(objects, isEmpty);
    expect(preferences.getString('backupRequestedFor'), isNull);
  });

  test('offline consent cannot resume under a different account after restart', () async {
    final value = model(network: () async => [ConnectivityResult.none]);
    _record(value.session, 'private a');
    await value.backupNow();
    final changed = value.session.copy()
      ..link = const CloudWebDav(name: 'Other account', endpoint: _endpoint, accountScope: 'account-b');
    final reopened = model(session: changed);
    await reopened.backupNow(includeLocalRecords: false);
    expect(objects, isEmpty);
    expect(reopened.bannerIsError, isTrue);
  });
}
