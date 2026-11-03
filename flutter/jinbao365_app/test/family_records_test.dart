import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/family_data_controller.dart';
import 'package:jinbao365/screens/family_records.dart';
import 'package:jinbao365/screens/family_media.dart';
import 'package:jinbao_core/jinbao_core.dart';

import 'support/family_data_fixture.dart';

class _ScreenController extends FamilyDataController {
  final FamilyDataFixture fixture;
  bool pending = false;
  bool cached = false;
  bool contributor = true;
  bool admin = true;
  int uploads = 0, cancelled = 0, restores = 0, copies = 0, moderated = 0;
  Set<String>? copiedRecordIDs;
  bool? copiedAnniversaries;
  final hiddenIDs = <String>{};
  late final FamilyCopySummary summary = FamilyCopySummary(familyName: selectedFamily.name,
    recordCount: 1, mediaCount: 2, anniversaryCount: 1, byteCount: 2048);
  _ScreenController(this.fixture, {Family? family}) : super(client: fixture.client,
    selectedFamily: family ?? fixture.family, currentLocalSession: () => fixture.session,
    localDirectory: fixture.root.path);
  @override
  bool get canContribute => contributor && !cached;
  @override
  bool get canModerate => admin && !cached;
  @override
  bool canEdit(FamilyArchiveRecord record) => canContribute && record.ownerMemberID == familyTestID(2) && !isHidden(record);
  @override
  bool isHidden(FamilyArchiveRecord record) => hiddenIDs.contains(record.id);
  @override
  bool get hasPendingUpload => pending;
  @override
  bool get hasUnpreparedSource => false;
  @override
  FamilyCopySummary? get pendingCopy => pending ? summary : null;
  @override
  String? get pendingConfirmationID => pending ? 'synthetic-review-${selectedFamily.id}' : null;
  @override
  Future<void> initialize() async {
    familySnapshot = cached ? null : await fixture.client.getFamily(fixture.family.id);
    showingCachedMetadata = cached;
    ownerNames = {familyTestID(2): '本人', familyTestID(8): '合成外婆'};
    records = [
      FamilyArchiveRecord(id: familyTestID(10), ownerMemberID: familyTestID(2),
        writerDeviceID: fixture.session.deviceID, revision: 1, occurredAt: 1700000000000,
        updatedAt: 1700000000000, title: '本人记录', note: '写下共同的日常'),
      FamilyArchiveRecord(id: familyTestID(11), ownerMemberID: familyTestID(8),
        writerDeviceID: familyTestID(9), revision: 1, occurredAt: 1700000000001,
        updatedAt: 1700000000001, title: '外婆的记录', note: '署名保留'),
    ];
    notifyListeners();
  }
  @override
  Future<void> refresh() async { notifyListeners(); }
  @override
  Future<void> prepareLocalCopy({Set<String>? recordIDs, bool includeAnniversaries = true}) async {
    copies++;
    copiedRecordIDs = recordIDs == null ? null : Set.of(recordIDs);
    copiedAnniversaries = includeAnniversaries;
    pending = true;
    status = FamilyDataStatus.prepared;
    notifyListeners();
  }
  @override
  Future<void> prepareText({FamilyArchiveRecord? editing, required String title,
    required String note, required int occurredAt}) async {
    pending = true;
    status = FamilyDataStatus.prepared;
    notifyListeners();
  }
  @override
  Future<void> confirmAndUpload() async {
    uploads++;
    pending = false;
    status = FamilyDataStatus.verified;
    notifyListeners();
  }
  @override
  Future<void> restoreIsolated() async { restores++; notifyListeners(); }
  @override
  Future<void> moderateRecord(FamilyArchiveRecord record, {required bool hidden}) async {
    moderated++;
    if (hidden) { hiddenIDs.add(record.id); } else { hiddenIDs.remove(record.id); }
    status = FamilyDataStatus.verified;
    notifyListeners();
  }
  @override
  void cancel() { pending = false; cancelled++; status = FamilyDataStatus.cancelled; notifyListeners(); }
  @override
  void dispose() { super.dispose(); }
}

Widget _screen(FamilyDataFixture fixture, _ScreenController controller, {Future<void> Function()? onAddPhotos}) =>
    MaterialApp(home: FamilyRecordsScreen(client: fixture.client, selectedFamily: controller.selectedFamily,
      currentLocalSession: () => fixture.session, localDirectory: fixture.root.path,
      controller: controller, onAddPhotos: onAddPhotos));

/// ensureVisible jumps on a later microtask. Pump before hit testing, and
/// require the target — especially 「确认隐藏」 — to sit inside the surface.
Future<void> _tapOnScreen(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  final rect = tester.getRect(finder);
  final surface = tester.view.physicalSize / tester.view.devicePixelRatio;
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.bottom, lessThanOrEqualTo(surface.height));
  expect(rect.right, lessThanOrEqualTo(surface.width));
  await tester.tap(finder);
}

final _syntheticPng = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==');
FamilyArchiveAsset _visualAsset({bool video = false}) => FamilyArchiveAsset(
  id: familyTestID(50), kind: video ? 'video' : 'photo', capturedAt: 1700000000000,
  resources: [
    for (var variant = 0; variant < 2; variant++) FamilyArchiveResource(
      id: familyTestID(100 + variant), role: variant == 1 ? 'preview' : video ? 'video' : 'photo',
      contentType: variant == 0 && video ? 'video/mp4' : 'image/png',
      originalFilename: variant == 0 && video ? 'synthetic.mp4' : 'synthetic.png',
      byteCount: _syntheticPng.length, sha256: Digest.sha256Hex(_syntheticPng)),
  ],
);

void main() {
  late Directory root;
  late FamilyDataFixture fixture;
  setUp(() async { root = await Directory.systemTemp.createTemp('dayswith-family-screen-'); fixture = FamilyDataFixture(root); });
  tearDown(() => root.delete(recursive: true));

  testWidgets('family records keep owner names and offer editing only for own records', (tester) async {
    final controller = _ScreenController(fixture);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_screen(fixture, controller));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('本人记录'), 200);
    expect(find.text('编辑我的文字'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('外婆的记录'), 200);
    expect(find.text('外婆的记录'), findsOneWidget);
    expect(find.textContaining('合成外婆'), findsOneWidget);
  });

  testWidgets('copy count and network rules require explicit upload confirmation', (tester) async {
    final controller = _ScreenController(fixture);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_screen(fixture, controller));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('复制本机照片与记录'));
    await tester.tap(find.text('复制本机照片与记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('准备复制'));
    await tester.pumpAndSettle();
    expect(controller.copies, 1);
    expect(controller.uploads, 0);
    expect(find.textContaining('2 项照片/视频'), findsOneWidget);
    expect(find.textContaining('仅在 Wi-Fi 或有线网络上传'), findsOneWidget);
    await tester.tap(find.text('确认上传'));
    await tester.pumpAndSettle();
    expect(controller.uploads, 1);
  });

  testWidgets('cancelling the copy confirmation creates no upload consent', (tester) async {
    final controller = _ScreenController(fixture);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_screen(fixture, controller));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('复制本机照片与记录'));
    await tester.tap(find.text('复制本机照片与记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('准备复制'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(controller.uploads, 0);
    expect(controller.cancelled, 1);
  });

  testWidgets('legacy copy freezes an explicit own-record subset and optional anniversary choice', (tester) async {
    fixture.session.moments.add(FamilyDataFixture.moment(12, '新本机照片'));
    fixture.session.moments.add(FamilyDataFixture.moment(13, '另一署名记录', parent: ParentIdentity.mom));
    final controller = _ScreenController(fixture);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_screen(fixture, controller));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('复制本机照片与记录'));
    await tester.tap(find.text('复制本机照片与记录'));
    await tester.pumpAndSettle();
    expect(find.text('另一署名记录'), findsNothing);
    await tester.tap(find.byKey(ValueKey('local-family-copy:${familyTestID(10)}')));
    await tester.tap(find.text('同时复制 1 个本人纪念日'));
    await tester.tap(find.text('准备复制'));
    await tester.pumpAndSettle();
    expect(controller.copiedRecordIDs, {familyTestID(12)});
    expect(controller.copiedAnniversaries, isFalse);
    expect(controller.uploads, 0);
  });

  testWidgets('a joined member needs no legacy identity to see direct family media import', (tester) async {
    fixture.session.identity = null;
    final controller = _ScreenController(fixture);
    addTearDown(controller.dispose);
    var additions = 0;
    await tester.pumpWidget(_screen(fixture, controller, onAddPhotos: () async { additions++; }));
    await tester.pumpAndSettle();
    expect(find.text('添加照片或视频'), findsOneWidget);
    expect(find.text('复制本机照片与记录'), findsNothing);
    await tester.tap(find.text('添加照片或视频'));
    await tester.pumpAndSettle();
    expect(additions, 1);
    expect(fixture.session.identity, isNull);
  });

  testWidgets('family switch while consent dialog is open cannot authorize another intent', (tester) async {
    final first = _ScreenController(fixture)..pending = true;
    final second = _ScreenController(fixture, family: Family(id: familyTestID(7), name: '另一合成家庭'))..pending = true;
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(_screen(fixture, first));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('确认并重试上传'));
    await tester.tap(find.text('确认并重试上传'));
    await tester.pumpAndSettle();
    expect(find.textContaining('目标家庭：合成家庭'), findsOneWidget);
    await tester.pumpWidget(_screen(fixture, second));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认上传'));
    await tester.pumpAndSettle();
    expect(first.uploads, 0);
    expect(second.uploads, 0);
    expect(second.pending, isTrue);
  });

  testWidgets('offline verified cache is labelled and never enables editing or uploads', (tester) async {
    final controller = _ScreenController(fixture)..cached = true;
    addTearDown(controller.dispose);
    await tester.pumpWidget(_screen(fixture, controller));
    await tester.pumpAndSettle();
    expect(find.textContaining('本机清单缓存'), findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(find.ancestor(of: find.text('写一条家庭记录'),
      matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton)).first).onPressed, isNull);
    expect(tester.widget<ButtonStyleButton>(find.ancestor(of: find.text('复制本机照片与记录'),
      matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton)).first).onPressed, isNull);
    await tester.scrollUntilVisible(find.text('本人记录'), 200);
    expect(find.text('编辑我的文字'), findsNothing);
  });

  testWidgets('adding media saves locally and does not invoke family upload', (tester) async {
    final controller = _ScreenController(fixture);
    addTearDown(controller.dispose);
    var additions = 0;
    await tester.pumpWidget(_screen(fixture, controller, onAddPhotos: () async { additions++; }));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('添加照片或视频'));
    await tester.tap(find.text('添加照片或视频'));
    await tester.pumpAndSettle();
    expect(additions, 1);
    expect(controller.copies, 0);
    expect(controller.uploads, 0);
    expect(find.textContaining('先保存在本机'), findsOneWidget);
  });

  testWidgets('restore is a separate confirmation and family changes cannot redirect it', (tester) async {
    final first = _ScreenController(fixture);
    final second = _ScreenController(fixture, family: Family(id: familyTestID(7), name: '另一合成家庭'));
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(_screen(fixture, first));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('验证完整恢复'));
    await tester.tap(find.text('验证完整恢复'));
    await tester.pumpAndSettle();
    expect(first.restores, 0);
    await tester.pumpWidget(_screen(fixture, second));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始验证恢复'));
    await tester.pumpAndSettle();
    expect(first.restores, 0);
    expect(second.restores, 0);
  });

  testWidgets('admin hides another member record only after explicit confirmation and can restore display', (tester) async {
    final controller = _ScreenController(fixture);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_screen(fixture, controller));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('外婆的记录'), 250);
    final otherCard = find.ancestor(of: find.text('外婆的记录'), matching: find.byType(Card)).first;
    final hide = find.descendant(of: otherCard, matching: find.text('从家庭时光隐藏'));
    await _tapOnScreen(tester, hide);
    await tester.pumpAndSettle();
    expect(controller.moderated, 0);
    expect(find.textContaining('不会删除或改写原件'), findsOneWidget);
    await _tapOnScreen(tester, find.text('确认隐藏'));
    await tester.pumpAndSettle();
    expect(controller.moderated, 1);
    await tester.scrollUntilVisible(find.text('恢复家庭展示'), 250);
    await _tapOnScreen(tester, find.text('恢复家庭展示'));
    await tester.pumpAndSettle();
    await _tapOnScreen(tester, find.text('确认恢复展示'));
    await tester.pumpAndSettle();
    expect(controller.moderated, 2);
  });

  testWidgets('hide confirmation stays on screen at iPhone SE width', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _ScreenController(fixture);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_screen(fixture, controller));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('外婆的记录'), 200);
    final otherCard = find.ancestor(of: find.text('外婆的记录'), matching: find.byType(Card)).first;
    final hide = find.descendant(of: otherCard, matching: find.text('从家庭时光隐藏'));
    await tester.scrollUntilVisible(hide, 120);
    await _tapOnScreen(tester, hide);
    await tester.pumpAndSettle();
    expect(find.textContaining('不会删除或改写原件'), findsOneWidget);
    await _tapOnScreen(tester, find.text('确认隐藏'));
    await tester.pumpAndSettle();
    expect(controller.moderated, 1);
    expect(find.text('确认隐藏'), findsNothing);
  });

  testWidgets('verified synthetic photo preview opens the original image viewer', (tester) async {
    final controller = _ScreenController(fixture);
    addTearDown(controller.dispose);
    await controller.initialize();
    final path = File('${root.path}/synthetic.png')..writeAsBytesSync(_syntheticPng);
    var originalLoads = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: FamilyAssetPreview(
      controller: controller, record: controller.records.first, asset: _visualAsset(),
      previewLoader: () async => path.path,
      originalLoader: (_) async { originalLoads++; return path.path; },
    ))));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.text('查看照片原件'));
    await tester.pumpAndSettle();
    expect(originalLoads, 1);
    expect(find.text('照片原件'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    controller.dispose();
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('已停止显示原件'), findsOneWidget);
  });

  testWidgets('preview identity changes clear old images even when asset UUID and revision match', (tester) async {
    final controller = _ScreenController(fixture);
    addTearDown(controller.dispose);
    await controller.initialize();
    final path = File('${root.path}/synthetic.png')..writeAsBytesSync(_syntheticPng);
    final next = Completer<String>();
    var newLoads = 0;
    Widget preview(FamilyArchiveRecord record, Future<String> Function() loader) => MaterialApp(
      home: Scaffold(body: FamilyAssetPreview(controller: controller, record: record,
        asset: _visualAsset(), previewLoader: loader)),
    );
    await tester.pumpWidget(preview(controller.records.first, () async => path.path));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(preview(controller.records.last, () { newLoads++; return next.future; }));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(newLoads, 1);
    next.complete(path.path);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('a failed thumbnail displays a safe retry action and can recover', (tester) async {
    final controller = _ScreenController(fixture);
    addTearDown(controller.dispose);
    await controller.initialize();
    final path = File('${root.path}/synthetic.png')..writeAsBytesSync(_syntheticPng);
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: FamilyAssetPreview(
      controller: controller, record: controller.records.first, asset: _visualAsset(),
      previewLoader: () async {
        if (++attempts == 1) throw StateError('synthetic-private-provider-detail');
        return path.path;
      },
    ))));
    await tester.pumpAndSettle();
    expect(find.text('重试缩略图'), findsOneWidget);
    expect(find.textContaining('synthetic-private-provider-detail'), findsNothing);
    await tester.tap(find.text('重试缩略图'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('original cellular download waits for a separate one-shot confirmation', (tester) async {
    final controller = _ScreenController(fixture);
    addTearDown(controller.dispose);
    await controller.initialize();
    final path = File('${root.path}/synthetic.png')..writeAsBytesSync(_syntheticPng);
    final permissions = <bool>[];
    await tester.pumpWidget(MaterialApp(home: FamilyMediaViewer(
      controller: controller, record: controller.records.first, asset: _visualAsset(),
      originalLoader: (allowed) async {
        permissions.add(allowed);
        if (!allowed) throw const FamilyCellularDownloadRequired();
        return path.path;
      },
    )));
    await tester.pumpAndSettle();
    expect(permissions, [false]);
    expect(find.byType(Image), findsNothing);
    await tester.tap(find.text('选择这次的网络许可'));
    await tester.pumpAndSettle();
    expect(permissions, [false]);
    await tester.tap(find.text('允许这一次'));
    await tester.pumpAndSettle();
    expect(permissions, [false, true]);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('synthetic video surface is disposed when family authorization is cleared', (tester) async {
    final controller = _ScreenController(fixture);
    addTearDown(controller.dispose);
    await controller.initialize();
    final path = File('${root.path}/synthetic-video-body')..writeAsBytesSync([1, 2, 3]);
    var disposals = 0;
    await tester.pumpWidget(MaterialApp(home: FamilyMediaViewer(
      controller: controller, record: controller.records.first, asset: _visualAsset(video: true),
      originalLoader: (_) async => path.path,
      videoBuilder: (_, _) => _TrackedVideo(onDispose: () => disposals++),
    )));
    await tester.pumpAndSettle();
    expect(find.text('合成视频表面，未验证设备播放'), findsOneWidget);
    controller.dispose();
    await tester.pumpAndSettle();
    expect(disposals, 1);
    expect(find.text('合成视频表面，未验证设备播放'), findsNothing);
  });
}

class _TrackedVideo extends StatefulWidget {
  final VoidCallback onDispose;
  const _TrackedVideo({required this.onDispose});
  @override
  State<_TrackedVideo> createState() => _TrackedVideoState();
}
class _TrackedVideoState extends State<_TrackedVideo> {
  @override
  void dispose() { widget.onDispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => const Text('合成视频表面，未验证设备播放');
}
