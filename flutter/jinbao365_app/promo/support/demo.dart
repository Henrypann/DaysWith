import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/app_model.dart';
import 'package:jinbao365/child_profile.dart';
import 'package:jinbao365/main.dart';
import 'package:jinbao365/theme.dart';
import 'package:jinbao_core/jinbao_core.dart';

import 'art.dart';

/// A made-up family archive for demos and promo videos. All dates are relative to today, so
/// 「那年今天」 and the anniversary countdown always have something to show.
class DemoRecord {
  final String title;
  final String note;
  final int monthsAgo;
  final int daysAgo;
  final int hour;
  final int minute;
  final ParentIdentity parent;
  final List<String> art;
  const DemoRecord(this.title, this.parent,
      {this.note = '', this.monthsAgo = 0, this.daysAgo = 0, this.hour = 10, this.minute = 0, this.art = const []});
}

const demoNickname = '糯米';

const demoRecords = [
  DemoRecord('第一口自己吃的粥', ParentIdentity.mom, art: ['porridge'], hour: 8, minute: 20, note: '勺子拿反了，也吃得很认真。'),
  DemoRecord('雨后踩水坑', ParentIdentity.dad, daysAgo: 2, art: ['boots'], hour: 16, minute: 45),
  DemoRecord('滑梯滑了十一次', ParentIdentity.mom, daysAgo: 5, art: ['slide', 'balloon'], hour: 15, minute: 10),
  DemoRecord('', ParentIdentity.dad, daysAgo: 9, hour: 21, minute: 30, note: '今天下班刚进门，她突然说了一句「爸爸抱」。站在门口愣了好几秒。'),
  DemoRecord('搭了五层积木', ParentIdentity.mom, daysAgo: 16, art: ['blocks'], hour: 19, minute: 5),
  DemoRecord('第一次放风筝', ParentIdentity.dad, monthsAgo: 1, art: ['kite'], hour: 17, minute: 20),
  DemoRecord('洗澡和小黄鸭', ParentIdentity.mom, monthsAgo: 1, daysAgo: 9, art: ['duck'], hour: 20, minute: 15),
  DemoRecord('海边，第一次踩沙子', ParentIdentity.dad, monthsAgo: 2, daysAgo: 4, art: ['beach'], hour: 18, minute: 2),
  DemoRecord('草地上的野餐', ParentIdentity.mom, monthsAgo: 6, art: ['picnic'], hour: 11, minute: 40, note: '吃到了人生第一颗草莓。'),
  DemoRecord('迈出第一步！', ParentIdentity.dad, monthsAgo: 7, daysAgo: 3, art: ['steps'], hour: 19, minute: 48),
  DemoRecord('一岁啦', ParentIdentity.mom, monthsAgo: 8, daysAgo: 6, art: ['cake', 'bunting'], hour: 18, minute: 30),
  DemoRecord('第一场雪', ParentIdentity.dad, monthsAgo: 10, daysAgo: 2, art: ['snowman'], hour: 9, minute: 15),
  DemoRecord('第一次自己坐稳', ParentIdentity.mom, monthsAgo: 12, art: ['teddy'], hour: 10, minute: 26, note: '坐了整整十秒，然后笑着倒进小熊怀里。'),
  DemoRecord('睡前故事', ParentIdentity.dad, monthsAgo: 14, daysAgo: 5, art: ['storybook'], hour: 21, minute: 0),
  DemoRecord('回家的第一个早晨', ParentIdentity.mom, monthsAgo: 19, daysAgo: 12, art: ['crib'], hour: 6, minute: 50),
];

DateTime _shift(DateTime today, {int months = 0, int days = 0, int hour = 0, int minute = 0}) {
  final total = today.year * 12 + today.month - 1 - months;
  final year = total ~/ 12, month = total % 12 + 1;
  final last = JinbaoCalendar.daysInMonth(year, month);
  return DateTime(year, month, today.day > last ? last : today.day, hour, minute).subtract(Duration(days: days));
}

class DemoArchive {
  final Directory directory;
  final ChildProfile child;
  final List<LocalMoment> moments;
  final List<String> imagePaths;
  DemoArchive._(this.directory, this.child, this.moments, this.imagePaths);

  static const dadDevice = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  static const momDevice = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

  /// Draws every illustration into [directory] and builds the records. Call inside `runAsync`.
  static Future<DemoArchive> create(Directory directory, {UploadEligibility dadEligibility = UploadEligibility.localOnly}) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final birthday = _shift(today, months: 20, days: 6);
    final child = ChildProfile(nickname: demoNickname, birthday: DateParts(birthday.year, birthday.month, birthday.day));
    final moments = <LocalMoment>[];
    final paths = <String>[];
    for (final record in demoRecords) {
      var occurred = _shift(today, months: record.monthsAgo, days: record.daysAgo, hour: record.hour, minute: record.minute);
      if (occurred.isAfter(now)) occurred = now.subtract(const Duration(minutes: 5));
      final assets = <LocalAsset>[];
      for (final name in record.art) {
        final id = newUuid();
        final relative = 'media/$id/original.png';
        final file = File('${directory.path}/$relative');
        await file.parent.create(recursive: true);

        final image = await DemoArt.all[name]!.render();

        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
        image.dispose();
        await file.writeAsBytes(bytes, flush: true);

        final digest = await Digest.sha256File(file.path, maximumBytes: bytes.length);
        paths.add(file.path);
        assets.add(LocalAsset(
          id: id,
          kind: 'photo',
          capturedAt: occurred.millisecondsSinceEpoch,
          provenance: null,
          resources: [
            LocalResource(
                id: newUuid(),
                role: 'photo',
                contentType: 'image/png',
                originalFilename: 'demo-$name.png',
                byteCount: bytes.length,
                sha256: digest.hash,
                relativePath: relative),
          ],
        ));
      }
      final millis = occurred.millisecondsSinceEpoch;
      moments.add(LocalMoment(
        id: newUuid(),
        title: record.title,
        note: record.note,
        occurredAt: millis,
        createdAt: millis,
        updatedAt: millis,
        parent: record.parent,
        assets: assets,
        uploadEligibility: record.parent == ParentIdentity.dad ? dadEligibility : UploadEligibility.localOnly,
      ));
    }
    return DemoArchive._(directory, child, moments, paths);
  }

  /// One phone's view of the family archive. The other parent's records are read-only there.
  AppSession session(ParentIdentity identity, {CloudLink link = const CloudMissing()}) {
    final now = DateTime.now();
    final soon = now.add(const Duration(days: 3));
    final session = AppSession(
      deviceID: identity == ParentIdentity.dad ? dadDevice : momDevice,
      testBuild: false,
      identity: identity,
      link: link,
      moments: moments.map((m) => m.copy()).toList(),
    );
    final at = now.millisecondsSinceEpoch;
    session
      ..saveAnniversary(title: '$demoNickname的生日', date: child.storedBirthday, now: at)
      ..saveAnniversary(
          title: '我们成为一家人',
          date: '${soon.year - 4}-${soon.month.toString().padLeft(2, '0')}-${soon.day.toString().padLeft(2, '0')}',
          now: at);
    return session;
  }

  /// The phone recorded everything in local-first mode, so its own records can join a backup.
  AppModel model(ParentIdentity identity, {CloudLink link = const CloudMissing(), bool withChild = true}) {
    final archive = session(identity, link: link);
    return AppModel.forSession(archive,
        directory: directory.path,
        child: withChild ? child : null,
        localFirst: true,
        localFirstRecords: {
          for (final moment in archive.moments)
            if (moment.parent == identity) moment.id,
        });
  }
}

/// Text in widget tests uses a placeholder font. The promo renderer registers real fonts under
/// the family names the app theme resolves to, so frames look like a phone.
Future<void> loadPromoFonts() async {
  final windows = Platform.environment['WINDIR'] ?? r'C:\Windows';
  final text = [
    Platform.environment['PROMO_FONT'],
    '$windows/Fonts/NotoSansSC-VF.ttf',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/System/Library/Fonts/PingFang.ttc',
  ].whereType<String>().map(File.new).firstWhere((f) => f.existsSync(),
      orElse: () => throw StateError('Set PROMO_FONT to a CJK font file (for example Noto Sans SC).'));
  final bytes = await text.readAsBytes();
  // Styles that name no family resolve to the host platform's default family names.
  for (final family in const ['Roboto', 'PromoSans', 'Segoe UI', 'Arial', 'sans-serif', 'Helvetica', 'Ubuntu', 'monospace']) {
    final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final icons = [
    if (flutterRoot != null) '$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    '${File(Platform.resolvedExecutable).parent.path}/../../artifacts/material_fonts/materialicons-regular.otf',
  ].map(File.new).firstWhere((f) => f.existsSync(), orElse: () => throw StateError('Material icon font not found.'));
  final iconBytes = await icons.readAsBytes();
  await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(iconBytes)))).load();
}

/// Decodes every picture ahead of time: inside a test, frames never wait for real I/O.
Future<void> precacheDemoImages(WidgetTester tester, Iterable<String> paths) async {
  imageCache.maximumSizeBytes = 1 << 30;
  imageCache.maximumSize = 1000;
  await tester.runAsync(() async {
    Future<void> put(Object key, File file) async {
      final codec = await ui.instantiateImageCodec(await file.readAsBytes());
      final frame = await codec.getNextFrame();
      imageCache.putIfAbsent(key, () => OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: frame.image))));
    }

    await put(AssetBundleImageKey(bundle: rootBundle, name: 'assets/brand_mark.png', scale: 1), File('assets/brand_mark.png'));
    for (final path in paths) {
      await put(FileImage(File(path)), File(path));
    }
  });
}

/// The app exactly as shipped, inside a phone-sized MediaQuery.
class DemoApp extends StatelessWidget {
  final AppModel model;
  final Size size;
  final EdgeInsets padding;
  const DemoApp({super.key, required this.model, this.size = const Size(390, 844), this.padding = const EdgeInsets.only(top: 47, bottom: 16)});

  @override
  Widget build(BuildContext context) => SizedBox.fromSize(
        size: size,
        child: AppScope(
          model: model,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: jinbaoTheme(),
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (context, child) => MediaQuery(
              data: MediaQueryData(size: size, padding: padding, viewPadding: padding, devicePixelRatio: 3),
              child: child!,
            ),
            home: const RootView(),
          ),
        ),
      );
}
