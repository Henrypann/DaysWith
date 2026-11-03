import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/app_model.dart';
import 'package:jinbao365/main.dart';
import 'package:jinbao365/theme.dart';
import 'package:jinbao_core/jinbao_core.dart';

const _deviceID = '12345678-1234-4234-8234-123456789abc';

AppSession _session() => AppSession(deviceID: _deviceID, testBuild: true);

void main() {
  test('offline text, originals and anniversary survive restart and optional storage connection', () async {
    final folder = await Directory.systemTemp.createTemp(
      'dayswith-local-first-',
    );
    addTearDown(() => folder.delete(recursive: true));
    final store = ArchiveStore('${folder.path}/archive.json');
    final session = _session()..confirmIdentity(ParentIdentity.dad);
    expect(session.phase, AppPhase.timeline);
    expect(session.link, isA<CloudMissing>());
    session.beginDraft(now: 1700000000000);
    session.updateDraft(title: '离线的一天', note: '没有连接存储也能记录。');
    for (final (index, kind, role, contentType, suffix) in [
      (1, 'photo', 'photo', 'image/jpeg', 'jpg'),
      (2, 'video', 'video', 'video/mp4', 'mp4'),
    ]) {
      final bytes = utf8.encode('synthetic original $kind bytes');
      final relative = 'media/original-$index.$suffix';
      final file = File('${folder.path}/$relative');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      session.addAsset(
        LocalAsset(
          id: '00000000-0000-4000-8000-00000000000$index',
          kind: kind,
          capturedAt: 1700000000000,
          provenance: ImportProvenance.verifiedOriginal.rawValue,
          resources: [
            LocalResource(
              id: '00000000-0000-4000-8000-00000000001$index',
              role: role,
              contentType: contentType,
              originalFilename: 'original-$index.$suffix',
              byteCount: bytes.length,
              sha256: Digest.sha256Hex(bytes),
              relativePath: relative,
            ),
          ],
        ),
      );
    }
    final record = session.commitDraft(now: 1700000000001);
    final anniversary = session.saveAnniversary(
      title: '值得纪念的一天',
      date: '2026-11-03',
      now: 1700000000001,
    );
    store.save(PersistedArchive.fromSession(session));

    final reopened = store.load()!.session();
    expect(reopened.phase, AppPhase.timeline);
    expect(reopened.timelineEntries().single.id, record.id);
    expect(reopened.moments.single.assets.map((a) => a.kind), [
      'photo',
      'video',
    ]);
    expect(reopened.anniversaries.single.id, anniversary.id);
    for (final resource in reopened.moments.single.assets.expand(
      (a) => a.resources,
    )) {
      final bytes = await File('${folder.path}/${resource.relativePath}')
          .readAsBytes();
      expect(bytes.length, resource.byteCount);
      expect(Digest.sha256Hex(bytes), resource.sha256);
    }
    reopened.beginEdit(id: record.id, now: 1700000000002);
    reopened.updateDraft(title: '离线修改', note: '编辑保留同一个记录编号。');
    reopened.commitDraft(now: 1700000000003);
    reopened.connectVerified(
      bucket: 'fixture-1234567890',
      region: 'ap-shanghai',
    );
    store.save(PersistedArchive.fromSession(reopened));
    final connected = store.load()!.session();
    expect(connected.moments, hasLength(1));
    expect(connected.moments.single.id, record.id);
    expect(connected.moments.single.title, '离线修改');
    expect(
      connected.moments.single.uploadEligibility,
      UploadEligibility.localOnly,
      reason:
          'Connecting alone must not silently upload historical local records.',
    );
    expect(connected.anniversaries.single.id, anniversary.id);
  });

  testWidgets(
    'first entry offers local recording and never grants unavailable family access',
    (tester) async {
      final model = AppModel()
        ..session = _session()
        ..ready = true;
      addTearDown(model.dispose);
      await tester.pumpWidget(AppScope(model: model, child: const JinbaoApp()));
      await tester.pumpAndSettle();
      expect(find.text('开始记录'), findsOneWidget);
      expect(find.text('加入家庭'), findsOneWidget);
      await tester.tap(find.text('加入家庭'));
      await tester.pumpAndSettle();
      expect(find.text('加入家庭暂未开放'), findsOneWidget);
      expect(model.session.identity, isNull);
      expect(model.session.link, isA<CloudMissing>());
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始记录'));
      await tester.pumpAndSettle();
      expect(find.text('这台手机是谁'), findsOneWidget);
      expect(find.text('爸爸'), findsOneWidget);
      expect(find.text('妈妈'), findsOneWidget);
      expect(find.text('验证并继续'), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('加入家庭'), findsOneWidget);
    },
  );

  testWidgets(
    'offline four-entry shell and record actions support large text',
    (tester) async {
      tester.view.physicalSize = const Size(720, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = _session()..confirmIdentity(ParentIdentity.dad);
      final model = AppModel()
        ..session = session
        ..ready = true;
      addTearDown(model.dispose);
      await tester.pumpWidget(
        AppScope(
          model: model,
          child: MaterialApp(
            theme: jinbaoTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: const RootView(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('仅保存在本机 · 可稍后连接存储'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('记录'));
      await tester.pumpAndSettle();
      expect(find.text('添加照片或视频'), findsOneWidget);
      expect(find.text('写文字'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('我的').last);
      await tester.pumpAndSettle();
      expect(find.text('家庭空间'), findsOneWidget);
      expect(find.text('纪念日'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
