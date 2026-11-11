import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/app_model.dart';
import 'package:jinbao365/child_profile.dart';
import 'package:jinbao365/main.dart';
import 'package:jinbao365/screens/growth_card.dart';
import 'package:jinbao365/screens/timeline.dart';
import 'package:jinbao365/theme.dart';
import 'package:jinbao_core/jinbao_core.dart';

const _device = '12345678-1234-4234-8234-123456789abc';

DateTime _monthsAgo(int months) {
  final now = DateTime.now();
  final total = now.year * 12 + now.month - 1 - months;
  final year = total ~/ 12, month = total % 12 + 1;
  final last = JinbaoCalendar.daysInMonth(year, month);
  return DateTime(year, month, now.day > last ? last : now.day, 9, 30);
}

void main() {
  late Directory directory;

  setUp(() => directory = Directory.systemTemp.createTempSync('dayswith4-'));
  tearDown(() => directory.deleteSync(recursive: true));

  Future<AppModel> pump(WidgetTester tester, AppSession session,
      {ChildProfile? child, bool localFirst = false, Set<String>? localFirstRecords}) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = AppModel.forSession(session,
        directory: directory.path, child: child, localFirst: localFirst, localFirstRecords: localFirstRecords);
    await tester.pumpWidget(AppScope(model: model, child: MaterialApp(theme: jinbaoTheme(), home: const RootView())));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    });
    return model;
  }

  testWidgets('first run explains the app, then records on this phone without a cloud', (tester) async {
    final model = await pump(tester, AppSession(deviceID: _device, testBuild: false));
    expect(find.text('一条属于孩子的时间线'), findsOneWidget);
    expect(find.text('这台手机是谁'), findsNothing);

    await tester.tap(find.text('开始记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('妈妈'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(model.session.identity, ParentIdentity.mom);

    // A release build no longer stops at the storage form.
    expect(find.text('连接云存储'), findsOneWidget);
    await tester.tap(find.text('先在这台手机记录'));
    await tester.pumpAndSettle();
    expect(model.localFirst, isTrue);
    expect(model.session.link, isA<CloudMissing>());
    expect(find.text(TimelineEmptyCopy.title), findsOneWidget);
    expect(model.backupStatusTitle, '仅保存在这台手机');
  });

  testWidgets('records carry the age then, and earlier years come back on this day', (tester) async {
    final yearAgo = _monthsAgo(12);
    final birthday = _monthsAgo(20);
    final session = AppSession(deviceID: _device, testBuild: false)..confirmIdentity(ParentIdentity.mom);
    session.moments.addAll([
      LocalMoment(
          id: newUuid(),
          title: '第一次自己坐稳',
          note: '',
          occurredAt: yearAgo.millisecondsSinceEpoch,
          createdAt: 1,
          updatedAt: 1,
          parent: ParentIdentity.mom,
          assets: []),
      LocalMoment(
          id: newUuid(),
          title: '今天会叫妈妈了',
          note: '',
          occurredAt: DateTime.now().millisecondsSinceEpoch,
          createdAt: 1,
          updatedAt: 1,
          parent: ParentIdentity.dad,
          assets: []),
    ]);
    final child =
        ChildProfile(nickname: '糯米', birthday: DateParts(birthday.year, birthday.month, birthday.day));
    await pump(tester, session, child: child, localFirst: true);

    expect(find.text('糯米 · 1岁8个月'), findsOneWidget);
    expect(find.text('那年今天'), findsOneWidget);
    expect(find.text('1年前的今天'), findsOneWidget);
    expect(find.text('那时 8个月'), findsOneWidget);
    expect(find.widgetWithText(AgeBadge, '1岁8个月'), findsOneWidget);

    await tester.tap(find.descendant(of: find.byType(MemoriesStrip), matching: find.text('第一次自己坐稳')));
    await tester.pumpAndSettle();
    final dayNumber = child.dayNumberOn(DateParts(yearAgo.year, yearAgo.month, yearAgo.day));
    expect(find.text('糯米 8个月 · 第 $dayNumber 天'), findsOneWidget);

    await tester.tap(find.byTooltip('生成成长卡片'));
    await tester.pumpAndSettle();
    expect(find.byType(GrowthCard), findsOneWidget);
    expect(find.text('糯米 · 8个月'), findsOneWidget);
    expect(find.text('分享给家人'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without a child profile the timeline invites adding one and saves it', (tester) async {
    final session = AppSession(deviceID: _device, testBuild: false)..confirmIdentity(ParentIdentity.dad);
    final model = await pump(tester, session, localFirst: true);
    await tester.tap(find.text('添加宝宝生日，每条记录都标上年龄'));
    await tester.pumpAndSettle();
    expect(find.text('宝宝档案'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '糯米');
    await tester.tap(find.text('选择日期'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(model.child?.nickname, '糯米');
    expect(find.text('糯米 · 出生当天'), findsOneWidget);
    // The birthday also became an anniversary signed by this phone, remembered as local-first.
    final birthday = model.session.anniversaryEntries().singleWhere((e) => e.title == '糯米的生日');
    expect(model.localFirstRecords, contains(birthday.id));
  });

  testWidgets('a record written in local-first mode is remembered for a later backup', (tester) async {
    final session = AppSession(deviceID: _device, testBuild: false)..confirmIdentity(ParentIdentity.dad);
    final model = await pump(tester, session, localFirst: true);
    expect(model.beginDraft(), isTrue);
    model.updateDraft('不连云的第一条', '');
    expect(model.commitDraft(), isTrue);
    expect(model.localFirstRecords, {model.session.moments.single.id});
    expect(model.adoptableCount, 0, reason: 'nothing to add before a verified connection');
    await tester.pumpAndSettle();
  });

  testWidgets('local-only records join the backup only after consent', (tester) async {
    final session = AppSession(deviceID: _device, testBuild: false)..confirmIdentity(ParentIdentity.dad);
    session
      ..beginDraft(now: 1000)
      ..updateDraft(title: '连接前的记录', note: '');
    final written = session.commitDraft(now: 1000);
    // Local-only too, but not made in local-first mode: say, imported from an older install.
    session.moments.add(LocalMoment(
        id: newUuid(), title: '旧版导入', note: '', occurredAt: 1, createdAt: 1, updatedAt: 1, parent: ParentIdentity.dad, assets: []));
    session.connectVerified(bucket: 'family-1234567890', region: 'ap-shanghai');
    final model = await pump(tester, session, localFirstRecords: {written.id});
    model.selectTab(ShellTab.my);
    await tester.pumpAndSettle();
    await tester.tap(find.text('云备份'));
    await tester.pumpAndSettle();
    expect(find.text('1条记录仅保存在这台手机'), findsOneWidget);

    await tester.tap(find.text('加入云备份'));
    await tester.pumpAndSettle();
    expect(model.adoptableCount, 1, reason: 'nothing changes before the confirmation');
    await tester.tap(find.text('加入备份'));
    await tester.pump();
    expect(model.adoptableCount, 0);
    expect(model.session.moments.first.uploadEligibility, UploadEligibility.eligible);
    expect(model.session.moments.last.uploadEligibility, UploadEligibility.localOnly);
    // Stop the scheduled backup before it reaches the network.
    model.pauseBackup();
    await tester.pump(const Duration(seconds: 1));
  });

  test('a disposed model ignores late notifications', () {
    final model = AppModel.forSession(AppSession(deviceID: _device, testBuild: false), directory: directory.path);
    model.dispose();
    expect(model.clearBanner, returnsNormally);
    expect(() => model.show(const ContractError('x', 'y')), returnsNormally);
  });
}
