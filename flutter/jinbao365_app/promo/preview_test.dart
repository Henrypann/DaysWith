import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/app_model.dart';
import 'package:jinbao_core/jinbao_core.dart';

import 'support/demo.dart';

/// Renders still screenshots of the real 4.0 screens over the synthetic demo archive:
///   flutter test promo/preview_test.dart
/// Output: ../../promo/out/screens/*.png
void main() {
  testWidgets('screenshots', (tester) async {
    debugDisableShadows = false;
    final out = Directory('../../promo/out/screens')..createSync(recursive: true);
    final work = Directory.systemTemp.createTempSync('dayswith-demo-');
    late DemoArchive archive;
    await tester.runAsync(() async {
      await loadPromoFonts();
      archive = await DemoArchive.create(work);
    });
    // Before the first frame: a picture a widget already asked for would stay pending forever.
    await precacheDemoImages(tester, archive.imagePaths);
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    final model = archive.model(ParentIdentity.mom);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: key, child: DemoApp(model: model)));

    await tester.pumpAndSettle();

    Future<void> shot(String name) async {
      await tester.pumpAndSettle();
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 3);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${out.path}/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    await shot('01-timeline');
    await tester.tap(find.text('第一次自己坐稳').first);
    await shot('02-detail');
    await tester.tap(find.byTooltip('生成成长卡片'));
    await shot('03-growth-card');
    Navigator.of(tester.element(find.text('成长卡片'))).popUntil((route) => route.isFirst);
    model.selectTab(ShellTab.anniversaries);
    await shot('04-anniversaries');
    model.selectTab(ShellTab.review);
    await shot('05-review');
    model.selectTab(ShellTab.my);
    await shot('06-my');

    await tester.pumpWidget(const SizedBox());
    model.dispose();
    debugDisableShadows = true;
    await tester.runAsync(() => work.delete(recursive: true));
  });
}
