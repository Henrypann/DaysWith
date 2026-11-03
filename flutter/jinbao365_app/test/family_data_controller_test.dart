import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/family_data_controller.dart';
import 'package:jinbao_core/jinbao_core.dart';

import 'support/family_data_fixture.dart';

FamilyArchiveManifest latest(FamilyDataFixture fixture, {String? deviceID}) {
  final descriptors = fixture.archive.descriptors.where((d) => d.scope.deviceID == (deviceID ?? fixture.session.deviceID)).toList()
    ..sort((a, b) => a.sequence.compareTo(b.sequence));
  final descriptor = descriptors.last;
  final bytes = fixture.archive.manifests.values.firstWhere((bytes) => Digest.sha256Hex(bytes) == descriptor.sha256);
  return FamilyArchiveManifest.decode(bytes, expectedScope: descriptor.scope);
}

void main() {
  late Directory workspace;
  late FamilyDataFixture fixture;
  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('dayswith-family-app-');
    fixture = FamilyDataFixture(workspace);
  });
  tearDown(() => workspace.delete(recursive: true));

  test('starting another draft preserves cancelled upload text in a byte-exact local recovery copy', () async {
    final controller = fixture.controller();
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.prepareText(title: 'Only local cancelled text', note: 'Keep these bytes', occurredAt: 1700000000000);
    controller.cancel();
    final working = fixture.stateFile('frozen-source.json');
    final cancelled = working.readAsBytesSync();
    await controller.prepareText(title: 'Another draft', note: 'New selection', occurredAt: 1700000000001);
    final retained = File('${working.parent.path}/retained-drafts/${Digest.sha256Hex(cancelled)}.json');
    expect(retained.readAsBytesSync(), cancelled);
    expect(utf8.decode(retained.readAsBytesSync()), contains('Only local cancelled text'));
    expect(fixture.archive.descriptors, isEmpty);
  });

  test('explicitly clearing unreadable frozen source preserves its original recovery bytes', () async {
    final controller = fixture.controller();
    await controller.initialize();
    await controller.prepareText(title: 'Before damage', note: '', occurredAt: 1700000000000);
    controller.dispose();
    final working = fixture.stateFile('frozen-source.json');
    final unreadable = utf8.encode('{unreadable local text: retained,');
    working.writeAsBytesSync(unreadable);
    final reopened = fixture.controller();
    addTearDown(reopened.dispose);
    await reopened.initialize();
    reopened.cancel();
    final retained = File('${working.parent.path}/retained-drafts/${Digest.sha256Hex(unreadable)}.json');
    expect(retained.readAsBytesSync(), unreadable);
    expect(fixture.archive.descriptors, isEmpty);
  });

  test('replacing an unreadable intent journal keeps a separate byte-exact copy', () async {
    final controller = fixture.controller();
    await controller.initialize();
    await controller.prepareText(title: 'Original local task', note: '', occurredAt: 1700000000000);
    controller.dispose();
    final journal = fixture.stateFile('intent.json');
    final unreadable = utf8.encode('{old local task: not yet readable,');
    journal.writeAsBytesSync(unreadable);
    final reopened = fixture.controller();
    addTearDown(reopened.dispose);
    await reopened.initialize();
    reopened.cancel();
    await reopened.refresh();
    await reopened.prepareText(title: 'New task after explicit discard', note: '', occurredAt: 1700000000001);
    final retained = File('${journal.parent.path}/retained-intents/${Digest.sha256Hex(unreadable)}.json');
    expect(retained.readAsBytesSync(), unreadable);
    expect(fixture.archive.descriptors, isEmpty);
  });

  test('own source is frozen durably before first network and later edits are excluded', () async {
    fixture.session.moments.add(FamilyDataFixture.moment(11, '另一署名', parent: ParentIdentity.mom));
    final controller = fixture.controller();
    addTearDown(controller.dispose);
    var inspected = false;
    fixture.gateway.before = (_) {
      if (inspected) return;
      inspected = true;
      final data = jsonDecode(fixture.stateFile('frozen-source.json').readAsStringSync()) as Map;
      final source = data['source'] as Map;
      expect((source['moments'] as List), hasLength(1));
      expect((source['moments'] as List).single['title'], '本机冻结记录');
      fixture.session.moments.first.title = '稍后修改不在这次选择';
      fixture.session.moments.add(FamilyDataFixture.moment(12, '稍后新增'));
    };
    await controller.prepareLocalCopy();
    expect(controller.status, FamilyDataStatus.prepared);
    expect(fixture.archive.requests.where((r) => r.method == 'PUT'), isEmpty);
    await controller.confirmAndUpload();
    expect(controller.status, FamilyDataStatus.verified);
    expect(latest(fixture).records.single.title, '本机冻结记录');
    expect(fixture.session.moments.first.title, '稍后修改不在这次选择');
    expect(fixture.session.moments, hasLength(3));
  });

  test('pause while connectivity awaits is durable and restart never auto uploads', () async {
    final checked = Completer<void>();
    final network = Completer<List<ConnectivityResult>>();
    final controller = fixture.controller(connectivityCheck: () { checked.complete(); return network.future; });
    await controller.prepareLocalCopy();
    final confirmation = controller.pendingConfirmationID;
    final upload = controller.confirmAndUpload();
    await checked.future;
    controller.pause();
    expect((jsonDecode(fixture.stateFile('intent.json').readAsStringSync()) as Map)['state'], 'paused');
    network.complete([ConnectivityResult.wifi]);
    await upload;
    expect(controller.status, FamilyDataStatus.paused);
    expect(fixture.archive.requests.where((r) => r.method == 'PUT'), isEmpty);
    controller.dispose();
    final reopened = fixture.controller();
    addTearDown(reopened.dispose);
    await reopened.initialize();
    expect(reopened.pendingConfirmationID, confirmation);
    expect(fixture.archive.requests.where((r) => r.method == 'PUT'), isEmpty);
    await reopened.confirmAndUpload();
    expect(reopened.status, FamilyDataStatus.verified);
  });

  test('Wi-Fi-first persists waiting intent and none never becomes a successful transfer', () async {
    fixture.network = [ConnectivityResult.mobile];
    final controller = fixture.controller();
    addTearDown(controller.dispose);
    await controller.prepareLocalCopy();
    final confirmation = controller.pendingConfirmationID;
    await controller.confirmAndUpload();
    expect(controller.status, FamilyDataStatus.waitingForNetwork);
    expect(fixture.archive.requests.where((r) => r.method == 'PUT'), isEmpty);
    fixture.network = [ConnectivityResult.none];
    await controller.confirmAndUpload();
    expect(controller.status, FamilyDataStatus.waitingForNetwork);
    expect(controller.pendingConfirmationID, confirmation);
    fixture.network = [ConnectivityResult.wifi];
    await controller.confirmAndUpload();
    expect(controller.status, FamilyDataStatus.verified);
  });

  test('explicitly allowing cellular still rejects no network', () async {
    final controller = fixture.controller(wifiOnlyUploads: false);
    addTearDown(controller.dispose);
    fixture.network = [ConnectivityResult.none];
    await controller.prepareLocalCopy();
    await controller.confirmAndUpload();
    expect(controller.status, FamilyDataStatus.waitingForNetwork);
    fixture.network = [ConnectivityResult.mobile];
    await controller.confirmAndUpload();
    expect(controller.status, FamilyDataStatus.verified);
  });

  test('cancel during async preflight cannot be resurrected by a late response', () async {
    final controller = fixture.controller();
    await controller.prepareLocalCopy();
    final entered = Completer<void>();
    final release = Completer<void>();
    fixture.gateway.before = (_) async { entered.complete(); await release.future; };
    final upload = controller.confirmAndUpload();
    await entered.future;
    controller.cancel();
    release.complete();
    await upload;
    fixture.gateway.before = null;
    controller.dispose();
    final reopened = fixture.controller();
    addTearDown(reopened.dispose);
    await reopened.initialize();
    expect(reopened.hasPendingUpload, isFalse);
    expect(fixture.archive.requests.where((r) => r.method == 'PUT'), isEmpty);
  });

  test('retry fails closed for changed authenticated member, subject or backend', () async {
    final controller = fixture.controller();
    addTearDown(controller.dispose);
    await controller.prepareLocalCopy();
    fixture.gateway.memberID = familyTestID(8);
    fixture.gateway.subjectID = 'different-synthetic-subject';
    await controller.confirmAndUpload();
    expect(controller.status, FamilyDataStatus.failed);
    expect(fixture.archive.requests.where((r) => r.method == 'PUT'), isEmpty);
    fixture.gateway.memberID = familyTestID(2);
    fixture.gateway.subjectID = 'synthetic-parent';
    fixture.gateway.storageID = 'gateway:${familyTestID(999)}';
    await controller.confirmAndUpload();
    expect(controller.status, FamilyDataStatus.failed);
    expect(fixture.archive.requests.where((r) => r.method == 'PUT'), isEmpty);
  });

  test('text draft survives failed preparation and restart without silent overwrite', () async {
    final controller = fixture.controller();
    await controller.initialize();
    fixture.gateway.offline = true;
    await controller.prepareText(title: '尚未上传的草稿', note: '保存当时的内容', occurredAt: 1700000000000);
    expect(controller.hasUnpreparedSource, isTrue);
    controller.dispose();
    final reopened = fixture.controller();
    addTearDown(reopened.dispose);
    await reopened.initialize();
    expect(reopened.pendingDraftDescription, contains('尚未上传的草稿'));
    expect(fixture.archive.requests.where((r) => r.method == 'PUT'), isEmpty);
    fixture.gateway.offline = false;
    await expectLater(reopened.prepareLocalCopy(), throwsA(isA<FamilyDataException>()));
    await reopened.retryFrozenSource();
    expect(reopened.status, FamilyDataStatus.prepared);
    await reopened.confirmAndUpload();
    expect(latest(fixture).records.single.title, '尚未上传的草稿');
    expect(fixture.session.moments.single.title, '本机冻结记录');
  });

  test('unprepared draft binds the first authenticated account before catalog awaits', () async {
    fixture.archive.offline = true;
    final controller = fixture.controller();
    await controller.prepareLocalCopy();
    final frozen = jsonDecode(fixture.stateFile('frozen-source.json').readAsStringSync()) as Map;
    expect(frozen['boundSubjectID'], 'synthetic-parent');
    controller.dispose();
    fixture.archive.offline = false;
    fixture.gateway.memberID = familyTestID(9);
    fixture.gateway.subjectID = 'another-account';
    final reopened = fixture.controller();
    addTearDown(reopened.dispose);
    await reopened.initialize();
    await reopened.retryFrozenSource();
    expect(reopened.status, FamilyDataStatus.failed);
    expect(reopened.pendingConfirmationID, isNull);
    expect(fixture.archive.requests.where((r) => r.method == 'PUT'), isEmpty);
  });

  test('new snapshots retain highest own cross-device revisions and local trash never deletes remote', () async {
    final scope = FamilyArchiveScope(familyID: fixture.family.id, memberID: familyTestID(2), deviceID: fixture.session.deviceID);
    FamilyArchiveRecord record(int revision, String device) => FamilyArchiveRecord(id: familyTestID(10),
      ownerMemberID: scope.memberID, writerDeviceID: device, revision: revision,
      occurredAt: 1700000000000, updatedAt: 1700000000000 + revision,
      title: '远端版本 $revision', note: '原件保持');
    fixture.archive.seed(FamilyArchiveManifest(scope: scope, sequence: 1, records: [record(1, scope.deviceID)]));
    final other = FamilyArchiveScope(familyID: scope.familyID, memberID: scope.memberID, deviceID: familyTestID(4));
    fixture.archive.seed(FamilyArchiveManifest(scope: other, sequence: 1, records: [record(3, other.deviceID)]));
    fixture.session.moments.first.trashedAt = 1700000000010;
    fixture.session.moments.add(FamilyDataFixture.moment(11, '新记录'));
    final controller = fixture.controller();
    addTearDown(controller.dispose);
    await controller.prepareLocalCopy();
    await controller.confirmAndUpload();
    final manifest = latest(fixture);
    expect(manifest.sequence, 2);
    expect(manifest.records.firstWhere((r) => r.id == familyTestID(10)).revision, 3);
    expect(manifest.records.firstWhere((r) => r.id == familyTestID(10)).deletedAt, isNull);
    expect(manifest.records, hasLength(2));
  });

  test('descendant symlinks are rejected while the trusted root alias is canonicalized', () async {
    fixture.addSyntheticMedia();
    final original = File('${workspace.path}/media/source-0-0');
    final bytes = original.readAsBytesSync();
    final external = File('${workspace.path}/outside-original')..writeAsBytesSync(bytes);
    original.deleteSync();
    Link(original.path).createSync(external.path);
    final alias = Link('${workspace.path}-alias')..createSync(workspace.path);
    addTearDown(alias.deleteSync);
    final controller = fixture.controller(localDirectory: alias.path);
    addTearDown(controller.dispose);
    await controller.prepareLocalCopy();
    await controller.confirmAndUpload();
    expect(controller.status, FamilyDataStatus.failed);
    expect(fixture.archive.requests.where((r) => r.method == 'PUT'), isEmpty);
    expect(external.readAsBytesSync(), bytes);
  }, skip: Platform.isWindows);

  test('verified metadata cache is readable offline without an upload or edit grant', () async {
    final controller = fixture.controller();
    await controller.prepareLocalCopy();
    await controller.confirmAndUpload();
    await controller.refresh();
    controller.dispose();
    fixture.gateway.offline = true;
    final reopened = fixture.controller();
    addTearDown(reopened.dispose);
    await reopened.initialize();
    expect(reopened.records.single.title, '本机冻结记录');
    expect(reopened.showingCachedMetadata, isTrue);
    expect(reopened.canContribute, isFalse);
    expect(reopened.canEdit(reopened.records.single), isFalse);
  });

  test('10 synthetic photos and one video restore separately and interrupted stage survives restart', () async {
    fixture.addSyntheticMedia(count: 11);
    final active = File('${workspace.path}/archive.json')..writeAsStringSync('active archive unchanged');
    final originals = {for (final f in Directory('${workspace.path}/media').listSync().whereType<File>()) f.path: f.readAsBytesSync()};
    final controller = fixture.controller();
    await controller.prepareLocalCopy();
    await controller.confirmAndUpload();
    fixture.archive.failDownload = 2;
    await controller.restoreIsolated();
    expect(controller.hasIncompleteRestore, isTrue);
    final pointer = jsonDecode(fixture.stateFile('restore-intent.json').readAsStringSync()) as Map;
    expect(pointer['state'], 'incomplete');
    expect(pointer['stageDirectory'], isA<String>());
    final downloaded = fixture.archive.downloads;
    controller.dispose();
    final reopened = fixture.controller();
    addTearDown(reopened.dispose);
    await reopened.initialize();
    expect(reopened.hasIncompleteRestore, isTrue);
    expect(fixture.archive.downloads, downloaded, reason: 'Opening must never resume a transfer.');
    fixture.archive.failDownload = null;
    await reopened.restoreIsolated();
    expect(reopened.lastRestore!.verifiedResourceCount, 22);
    expect(reopened.lastRestore!.records.single.assets, hasLength(11));
    expect(reopened.lastRestore!.anniversaries.single.date, '0004-02-29');
    expect(active.readAsStringSync(), 'active archive unchanged');
    for (final entry in originals.entries) { expect(File(entry.key).readAsBytesSync(), entry.value); }
    expect((jsonDecode(fixture.stateFile('restore-intent.json').readAsStringSync()) as Map)['state'], 'completed');
  });

  test('text creation and own edit require separate manual confirmation and keep legacy data unchanged', () async {
    final controller = fixture.controller();
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.prepareText(title: '家庭文字', note: '手动确认', occurredAt: 1700000000000);
    expect(fixture.archive.descriptors, isEmpty);
    await controller.confirmAndUpload();
    await controller.refresh();
    final first = controller.records.single;
    await controller.prepareText(editing: first, title: '本人修改', note: first.note, occurredAt: first.occurredAt);
    await controller.confirmAndUpload();
    expect(latest(fixture).records.single.revision, 2);
    expect(latest(fixture).records.single.title, '本人修改');
    expect(fixture.session.moments.single.title, '本机冻结记录');
  });

  test('admin moderation hides independently without rewriting author snapshot or original bytes', () async {
    final controller = fixture.controller();
    addTearDown(controller.dispose);
    await controller.prepareLocalCopy();
    await controller.confirmAndUpload();
    await controller.refresh();
    final record = controller.records.single;
    final snapshotBytes = List<int>.of(fixture.archive.manifests.values.single);
    await controller.moderateRecord(record, hidden: true);
    await controller.refresh();
    expect(controller.isHidden(record), isTrue);
    expect(controller.canEdit(record), isFalse);
    expect(fixture.archive.manifests.values.single, snapshotBytes);
    await controller.moderateRecord(record, hidden: false);
    await controller.refresh();
    expect(controller.isHidden(record), isFalse);
    expect(controller.canEdit(record), isTrue);
  });

  test('preview and original loaders verify scoped bytes and require one-shot cellular permission', () async {
    fixture.addSyntheticMedia();
    final controller = fixture.controller();
    addTearDown(controller.dispose);
    await controller.prepareLocalCopy();
    await controller.confirmAndUpload();
    await controller.refresh();
    final record = controller.records.single;
    final asset = record.assets.single;
    final preview = await controller.loadPreview(record, asset);
    final previewResource = asset.resources.singleWhere((r) => r.role == 'preview');
    expect(Digest.sha256Hex(File(preview).readAsBytesSync()), previewResource.sha256);
    fixture.network = [ConnectivityResult.mobile];
    final downloads = fixture.archive.downloads;
    await expectLater(controller.loadOriginal(record, asset), throwsA(isA<FamilyCellularDownloadRequired>()));
    expect(fixture.archive.downloads, downloads);
    final original = await controller.loadOriginal(record, asset, allowCellular: true);
    expect(Digest.sha256Hex(File(original).readAsBytesSync()), asset.resources.singleWhere((r) => r.role == 'photo').sha256);
  });

  test('changing authenticated identity cannot expose an existing media cache', () async {
    fixture.addSyntheticMedia();
    final controller = fixture.controller();
    addTearDown(controller.dispose);
    await controller.prepareLocalCopy();
    await controller.confirmAndUpload();
    await controller.refresh();
    final record = controller.records.single;
    final cached = await controller.loadPreview(record, record.assets.single);
    final epoch = controller.authorizationEpoch;
    fixture.gateway.subjectID = 'different-synthetic-subject';
    await expectLater(controller.loadPreview(record, record.assets.single), throwsA(isA<FamilyDataException>()));
    expect(controller.authorizationEpoch, greaterThan(epoch));
    expect(controller.familySnapshot, isNull);
    expect(File(cached).existsSync(), isTrue, reason: 'Revocation hides access; cached bytes cannot be recalled.');
  });

  test('damaged frozen text remains untouched until an explicit discard', () async {
    final controller = fixture.controller();
    await controller.initialize();
    fixture.gateway.offline = true;
    await controller.prepareText(title: '仅在草稿中的文字', note: '不能被新草稿静默覆盖', occurredAt: 1700000000000);
    final source = fixture.stateFile('frozen-source.json');
    final damaged = utf8.encode('{"version":1,"state":"pending","source":"damaged synthetic text');
    source.writeAsBytesSync(damaged, flush: true);
    controller.dispose();
    fixture.gateway.offline = false;
    final reopened = fixture.controller();
    addTearDown(reopened.dispose);
    await reopened.initialize();
    expect(reopened.hasPendingUpload, isTrue);
    await expectLater(reopened.prepareText(title: '新草稿', note: '不得覆盖旧内容', occurredAt: 1700000000000),
      throwsA(isA<FamilyDataException>()));
    expect(source.readAsBytesSync(), damaged);
    reopened.cancel();
    expect(reopened.hasPendingUpload, isFalse);
  });

  test('logout and a different token never flash another session metadata while offline', () async {
    final original = fixture.controller();
    await original.prepareLocalCopy();
    await original.confirmAndUpload();
    await original.refresh();
    final cache = fixture.stateFile('verified-metadata.json');
    final saved = cache.readAsBytesSync();
    expect(cache.readAsStringSync(), isNot(contains('synthetic-session')));
    original.dispose();
    fixture.gateway.offline = true;
    for (final token in [null, 'different-synthetic-session']) {
      fixture.sessionToken = token;
      final reopened = fixture.controller();
      final visible = <String>[];
      reopened.addListener(() => visible.addAll(reopened.records.map((r) => r.title)));
      await reopened.initialize();
      expect(reopened.records, isEmpty);
      expect(reopened.ownerNames, isEmpty);
      expect(reopened.familySnapshot, isNull);
      expect(visible, isEmpty, reason: 'Even the first observable frame must not show the old partition.');
      expect(cache.readAsBytesSync(), saved);
      reopened.dispose();
    }
  });

  test('explicit 401 and 403 hide cache before first publication and preserve disk bytes', () async {
    final original = fixture.controller();
    await original.prepareLocalCopy();
    await original.confirmAndUpload();
    await original.refresh();
    final cache = fixture.stateFile('verified-metadata.json');
    final saved = cache.readAsBytesSync();
    original.dispose();
    for (final status in [401, 403]) {
      fixture.gateway.responseStatus = status;
      final reopened = fixture.controller();
      final visible = <String>[];
      reopened.addListener(() => visible.addAll(reopened.records.map((r) => r.title)));
      await reopened.initialize();
      expect(visible, isEmpty);
      expect(reopened.records, isEmpty);
      expect(reopened.ownerNames, isEmpty);
      expect(reopened.moderations, isEmpty);
      expect(reopened.familySnapshot, isNull);
      expect(cache.readAsBytesSync(), saved);
      reopened.dispose();
    }
  });

  test('token changes after final HTTP cannot write old data into a new session cache', () async {
    final original = fixture.controller();
    await original.prepareLocalCopy();
    await original.confirmAndUpload();
    await original.refresh();
    final cache = fixture.stateFile('verified-metadata.json');
    final saved = cache.readAsBytesSync();
    original.dispose();
    var calls = 0;
    fixture.gateway.before = (_) {
      if (++calls == 2) fixture.sessionToken = 'new-session-after-final-member-response';
    };
    final reopened = fixture.controller();
    addTearDown(reopened.dispose);
    final visible = <String>[];
    reopened.addListener(() => visible.addAll(reopened.records.map((r) => r.title)));
    await reopened.initialize();
    expect(reopened.records, isEmpty);
    expect(visible, isEmpty);
    expect(cache.readAsBytesSync(), saved);
  });

  test('pause cancel and destructor survive journal failure without claiming durable success', () async {
    final controller = fixture.controller();
    await controller.prepareLocalCopy();
    final journal = fixture.stateFile('intent.json');
    final bytes = journal.readAsBytesSync();
    final preserved = journal.renameSync('${journal.path}.preserved');
    Directory(journal.path).createSync();
    expect(controller.pause, returnsNormally);
    expect(controller.status, FamilyDataStatus.paused);
    expect(controller.errorMessage, contains('尚未写入磁盘'));
    expect(controller.cancel, returnsNormally);
    expect(controller.errorMessage, contains('尚未写入磁盘'));
    expect(controller.dispose, returnsNormally);
    expect(preserved.readAsBytesSync(), bytes);
    Directory(journal.path).deleteSync();
    preserved.renameSync(journal.path);
    final reopened = fixture.controller();
    addTearDown(reopened.dispose);
    await reopened.initialize();
    expect(reopened.status, FamilyDataStatus.paused);
    expect(fixture.archive.requests.where((r) => r.method == 'PUT'), isEmpty);
  });

  test('operation failure does not throw another uncaught journal persistence error', () async {
    final controller = fixture.controller();
    await controller.prepareLocalCopy();
    final journal = fixture.stateFile('intent.json');
    final preserved = journal.renameSync('${journal.path}.preserved');
    Directory(journal.path).createSync();
    fixture.gateway.offline = true;
    await expectLater(controller.confirmAndUpload(), completes);
    expect(controller.errorMessage, contains('本机保存未完成'));
    expect(controller.dispose, returnsNormally);
    Directory(journal.path).deleteSync();
    preserved.renameSync(journal.path);
  });

  test('late restore postflight failure never leaves a missing pending stage to resume', () async {
    fixture.addSyntheticMedia();
    final controller = fixture.controller();
    await controller.prepareLocalCopy();
    await controller.confirmAndUpload();
    await controller.refresh();
    fixture.gateway.before = (_) {
      final restores = Directory('${workspace.path}/family-restores');
      if (restores.existsSync() && restores.listSync().whereType<Directory>().any((d) =>
          d.path.split(Platform.pathSeparator).last.startsWith('family-restore-'))) {
        fixture.gateway.offline = true;
      }
    };
    await controller.restoreIsolated();
    expect(controller.lastRestore, isNull);
    expect(controller.hasIncompleteRestore, isFalse);
    final receipt = jsonDecode(fixture.stateFile('restore-intent.json').readAsStringSync()) as Map;
    expect(receipt['state'], 'completedUnconfirmed');
    expect(receipt['stageDirectory'], isNull);
    final completed = Directory(receipt['completedDirectory'] as String);
    expect(File('${completed.path}/RESTORE_COMPLETE.json').existsSync(), isTrue);
    controller.dispose();
    fixture.gateway.before = null;
    fixture.gateway.offline = false;
    final reopened = fixture.controller();
    addTearDown(reopened.dispose);
    await reopened.initialize();
    expect(reopened.hasIncompleteRestore, isFalse);
    await reopened.restoreIsolated();
    expect(reopened.lastRestore, isNotNull);
    expect(reopened.lastRestore!.directory, isNot(completed.path));
    expect(File('${completed.path}/RESTORE_COMPLETE.json').existsSync(), isTrue);
  });

  test('a joined member imports media without assigning any Dad or Mom identity', () async {
    fixture.addSyntheticMedia();
    final asset = fixture.session.moments.single.assets.single.copy();
    fixture.session.identity = null;
    fixture.session.moments.clear();
    fixture.gateway.memberID = familyTestID(8);
    fixture.gateway.subjectID = 'synthetic-grandparent';
    fixture.gateway.role = 'contributor';
    final controller = fixture.controller();
    await controller.initialize();
    controller.beginMediaImport();
    controller.retainImportedAsset(asset);
    expect(controller.retainedMediaCount, 1);
    expect(fixture.session.identity, isNull);
    expect(fixture.archive.requests.where((r) => r.method == 'PUT'), isEmpty);
    controller.dispose();
    final reopened = fixture.controller();
    addTearDown(reopened.dispose);
    await reopened.initialize();
    expect(reopened.hasRetainedMediaDraft, isTrue);
    expect(reopened.retainedMediaCount, 1);
    await reopened.prepareRetainedMedia();
    expect(reopened.status, FamilyDataStatus.prepared);
    expect(fixture.archive.requests.where((r) => r.method == 'PUT'), isEmpty);
    await reopened.confirmAndUpload();
    final manifest = latest(fixture);
    expect(manifest.scope.memberID, familyTestID(8));
    expect(manifest.records.single.assets, hasLength(1));
    expect(fixture.session.identity, isNull);
    expect(fixture.session.moments, isEmpty);
  });

  test('an import completing after controller disposal still retains its old-bound draft metadata', () async {
    fixture.addSyntheticMedia();
    final asset = fixture.session.moments.single.assets.single.copy();
    final controller = fixture.controller();
    await controller.initialize();
    controller.beginMediaImport();
    controller.dispose();
    expect(() => controller.retainImportedAsset(asset), returnsNormally);
    final source = jsonDecode(fixture.stateFile('frozen-source.json').readAsStringSync()) as Map;
    expect((source['source'] as Map)['assets'], hasLength(1));
    expect(source['boundMemberID'], familyTestID(2));
    expect(fixture.archive.requests.where((r) => r.method == 'PUT'), isEmpty);
  });
}
