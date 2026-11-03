import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/app_model.dart';
import 'package:jinbao365/main.dart';
import 'package:jinbao365/screens/storage_center.dart';
import 'package:jinbao365/theme.dart';
import 'package:jinbao_core/jinbao_core.dart';

class _Model extends AppModel {
  int backupRequests = 0;
  int restoreRequests = 0;
  Map<String, String>? nasRequest;
  _Model({bool connected = true}) {
    session = AppSession(
      deviceID: '11111111-1111-4111-8111-111111111111',
      testBuild: true,
    )..confirmIdentity(ParentIdentity.dad);
    if (connected) {
      session.connectVerified(
        bucket: 'example-1234567890',
        region: 'ap-shanghai',
      );
    }
    storageHealthLabel = connected ? '连接正常；等待备份' : '尚未连接';
  }

  @override
  String get backupStatusTitle => '等待手动备份';
  @override
  String get backupStatusDetail => '本机原件保留，上传后仍需完成独立恢复验证。';
  @override
  double? get backupProgress => null;
  @override
  int get backupRecordCount => 3;
  @override
  int get backupMediaCount => 10;
  @override
  int get backupByteCount => 5 * 1024 * 1024;
  @override
  int get pendingStorageCount => 10;
  @override
  int get failedStorageCount => 1;

  @override
  Future<void> backupNow({bool includeLocalRecords = true}) async {
    backupRequests++;
  }

  @override
  Future<void> verifyWebDav({
    required String name,
    required String url,
    required String username,
    required String password,
  }) async {
    nasRequest = {
      'name': name,
      'url': url,
      'username': username,
      'password': password,
    };
    banner = '合成服务不可达';
    bannerIsError = true;
    notifyListeners();
  }

  @override
  Future<void> restoreToIsolatedCopy() async {
    restoreRequests++;
    final restored =
        AppSession(
            deviceID: '22222222-2222-4222-8222-222222222222',
            testBuild: true,
          )
          ..confirmIdentity(ParentIdentity.dad)
          ..beginDraft(now: 1800000000000)
          ..updateDraft(title: '合成恢复文字', note: '用于界面核对的合成内容')
          ..commitDraft(now: 1800000000001);
    lastRestoreResult = ArchiveRestoreResult(
      directory: '/synthetic/isolated-copy',
      session: restored,
      sources: const [],
      verifiedObjectCount: 0,
      verifiedBytes: 0,
      originalResourceCount: 0,
    );
    restoreError = null;
    notifyListeners();
  }

  void switchTarget() {
    session.connectVerified(
      bucket: 'different-1234567890',
      region: 'ap-shanghai',
    );
    notifyListeners();
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Model model,
  Widget page, {
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(720, 1600);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(model.dispose);
  await tester.pumpWidget(
    AppScope(
      model: model,
      child: MaterialApp(
        theme: jinbaoTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _review(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('备份 / 重试'),
    240,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('备份 / 重试'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'storage center reports unknown capacity and needs confirmation before uploading',
    (tester) async {
      final model = _Model();
      await _pump(tester, model, const StorageCenterPage());
      expect(find.text('可用空间：未知'), findsOneWidget);
      expect(find.text('待处理 10 项 · 失败 1 项'), findsOneWidget);
      await _review(tester);
      expect(find.text('确认备份'), findsOneWidget);
      expect(find.text('共 3 条记录，10 项照片或视频'), findsOneWidget);
      expect(find.text('总大小：5.0 MiB（包含预览）'), findsOneWidget);
      expect(find.text('目标：腾讯云 COS · example-1234567890'), findsOneWidget);
      expect(find.text('网络策略：Wi-Fi 优先'), findsOneWidget);
      expect(model.backupRequests, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(model.backupRequests, 0);
      await _review(tester);
      await tester.tap(find.text('开始备份'));
      await tester.pumpAndSettle();
      expect(model.backupRequests, 1);
    },
  );

  testWidgets(
    'changing the target during review cannot authorize uploading to the new target',
    (tester) async {
      final model = _Model();
      await _pump(tester, model, const StorageCenterPage());
      await _review(tester);
      model.switchTarget();
      await tester.pump();
      await tester.tap(find.text('开始备份'));
      await tester.pumpAndSettle();
      expect(model.backupRequests, 0);
      expect(model.banner, '存储目标或记录已变化，请重新确认备份。');
    },
  );

  testWidgets(
    'offline storage page and backup review support double text size',
    (tester) async {
      final model = _Model(connected: false);
      await _pump(tester, model, const StorageCenterPage(), scale: 2);
      expect(find.text('仅保存在本机'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('NAS · HTTPS WebDAV'),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('NAS · HTTPS WebDAV'));
      await tester.pumpAndSettle();
      expect(find.text('连接 NAS'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large text review keeps cancellation and confirmation reachable',
    (tester) async {
      final model = _Model();
      await _pump(tester, model, const StorageCenterPage(), scale: 2);
      await _review(tester);
      expect(find.text('取消').hitTestable(), findsOneWidget);
      expect(find.text('开始备份').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(model.backupRequests, 0);
    },
  );

  testWidgets(
    'isolated restoration requires confirmation and displays a separate result',
    (tester) async {
      final model = _Model();
      await _pump(tester, model, const StorageCenterPage());
      Future<void> reviewRestore() async {
        await tester.scrollUntilVisible(
          find.text('下载独立恢复副本'),
          240,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('下载独立恢复副本'));
        await tester.pumpAndSettle();
      }

      await reviewRestore();
      expect(find.text('下载一份独立恢复副本？'), findsOneWidget);
      expect(model.restoreRequests, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(model.restoreRequests, 0);
      await reviewRestore();
      await tester.tap(find.text('下载并校验'));
      await tester.pumpAndSettle();
      expect(model.restoreRequests, 1);
      expect(find.text('独立恢复副本'), findsOneWidget);
      expect(find.text('合成恢复文字'), findsOneWidget);
      expect(model.session.moments, isEmpty);
      expect(model.session.link.isVerified, isTrue);
    },
  );

  testWidgets('restoration source change needs a new confirmation', (
    tester,
  ) async {
    final model = _Model();
    await _pump(tester, model, const StorageCenterPage());
    await tester.scrollUntilVisible(
      find.text('下载独立恢复副本'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载独立恢复副本'));
    await tester.pumpAndSettle();
    model.switchTarget();
    await tester.pump();
    await tester.tap(find.text('下载并校验'));
    await tester.pumpAndSettle();
    expect(model.restoreRequests, 0);
    expect(model.banner, '存储目标已变化，请重新确认恢复来源。');
  });

  testWidgets(
    'NAS form keeps passwords obscured and hides fields in app switcher',
    (tester) async {
      final model = _Model(connected: false);
      await _pump(tester, model, const WebDavConnectPage());
      final fields = find.byType(TextField);
      await tester.enterText(
        fields.at(1),
        'https://nas.example.com/dav/DaysWith/',
      );
      await tester.enterText(fields.at(2), 'synthetic-user');
      await tester.enterText(fields.at(3), 'SyntheticPassword');
      final password = tester.widget<TextField>(fields.at(3));
      expect(password.obscureText, isTrue);
      expect(password.enableSuggestions, isFalse);
      expect(password.enableIMEPersonalizedLearning, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(find.text('连接信息已隐藏'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('验证并连接'));
      await tester.tap(find.text('验证并连接'));
      await tester.pumpAndSettle();
      expect(model.nasRequest?['password'], 'SyntheticPassword');
      expect(find.text('合成服务不可达'), findsOneWidget);
      expect(model.session.link.isVerified, isFalse);
      expect(model.backupRequests, 0);
    },
  );
}
