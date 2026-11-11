@Timeout(Duration(minutes: 40))
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/app_model.dart';
import 'package:jinbao365/main.dart';
import 'package:jinbao365/screens/growth_card.dart';
import 'package:jinbao365/screens/timeline.dart';
import 'package:jinbao365/theme.dart';
import 'package:jinbao_core/jinbao_core.dart';

import 'support/stage.dart';

/// Video A 「她的每一天」: 9:16, 32 s, for parents. Every phone frame is the real 4.0 app.
///   flutter test promo/video_a_test.dart
void main() {
  testWidgets('video A', (tester) async {
    const size = Size(1080, 1920);
    await film(tester, size: size, output: '../../promo/out/dayswith-4.0-a-parents-9x16.mp4', audio: '../../promo/out/music_a.wav',
        shoot: (director, archive) async {
      final model = archive.model(ParentIdentity.mom);
      final phoneKey = GlobalKey();
      final phone = find.byKey(phoneKey);
      final memory = archive.moments.firstWhere((m) => m.title == '第一次自己坐稳');
      Rect? cardRect; // Where the growth card sits inside the phone, in stage coordinates.
      final random = math.Random(4);
      final tiles = [
        for (final (index, path) in archive.imagePaths.take(14).indexed)
          (
            path: path,
            from: Offset(140 + (index % 4) * 270 + random.nextDouble() * 60, 250 + (index ~/ 4) * 420 + random.nextDouble() * 120),
            angle: (random.nextDouble() - 0.5) * 0.5,
            drift: Offset((random.nextDouble() - 0.5) * 90, (random.nextDouble() - 0.5) * 90),
            portrait: index.isEven,
          ),
      ];

      await tester.pumpWidget(Stage(
        director: director,
        builder: (context, t) {
          final night = 1 - span(t, 3.6, 4.6) + span(t, 28.2, 29.0);
          final phoneIn = easeOut(span(t, 3.9, 5.1)), phoneOut = ease(span(t, 27.9, 28.9));
          final pop = easeOut(span(t, 17.3, 18.0)) * (1 - ease(span(t, 20.3, 20.8)));
          final phoneCenter = Offset(540, lerp(2900, 1130, phoneIn) + phoneOut * 1900);
          return Stack(children: [
            // Warm paper for the product, night for the hook and the end card.
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                      begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFFFF8EA), Color(0xFFF9E3BD)]),
                ),
              ),
            ),
            Positioned.fill(
              child: Opacity(
                opacity: night.clamp(0.0, 1.0),
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                        begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF0B1D38), Color(0xFF17335C)]),
                  ),
                ),
              ),
            ),
            // 0.0-4.6 Hook: a pile of pictures that nobody can find anything in.
            for (final (index, tile) in tiles.indexed)
              if (t < 4.7)
                Placed(
                  center: Offset.lerp(tile.from + tile.drift * (t / 3.6), const Offset(540, 1150), ease(span(t, 3.5 + index * 0.02, 4.5)))!,
                  angle: tile.angle + math.sin(t * 0.9 + index) * 0.04,
                  scale: lerp(0.6, 1, easeOut(span(t, index * 0.05, 0.5 + index * 0.05))) * lerp(1, 0.25, ease(span(t, 3.5, 4.5))),
                  opacity: span(t, index * 0.05, 0.3 + index * 0.05) * (1 - span(t, 4.2, 4.6)) * 0.92,
                  child: PhotoTile(path: tile.path, width: tile.portrait ? 250 : 320, height: tile.portrait ? 330 : 240),
                ),
            if (t < 3.9) ...[
              Positioned.fill(
                child: Opacity(
                  opacity: span(t, 0.2, 0.8) * (1 - span(t, 3.4, 3.8)) * 0.55,
                  child: const ColoredBox(color: Color(0xFF0B1D38)),
                ),
              ),
              Placed(
                center: const Offset(540, 900),
                child: SizedBox(
                  width: 940,
                  child: Caption('手机里有两万张照片', visible: window(t, 0.3, 1.9), titleSize: 84, color: JinbaoColors.onNavy),
                ),
              ),
              Placed(
                center: const Offset(540, 900),
                child: SizedBox(
                  width: 940,
                  child: Caption('哪一张，\n是她第一次自己坐稳？',
                      visible: window(t, 1.9, 3.8), titleSize: 84, color: JinbaoColors.gold),
                ),
              ),
            ],
            // 3.9-28.9 The real app.
            Placed(
              center: phoneCenter,
              scale: 1.7 * lerp(1, 0.94, pop),
              child: Phone(key: phoneKey, model: model),
            ),
            if (pop > 0) Positioned.fill(child: ColoredBox(color: const Color(0xFF0B1D38).withValues(alpha: 0.72 * pop))),
            // 17.3-20.8 The growth card leaves the phone.
            if (pop > 0 && cardRect != null)
              Placed(
                center: Offset.lerp(cardRect.center, const Offset(540, 1110), pop)!,
                scale: lerp(cardRect.width / 320, 2.5, pop),
                angle: -0.035 * pop,
                opacity: span(pop, 0, 0.15),
                child: Container(
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 40, offset: const Offset(0, 18)),
                  ]),
                  child: AppScope(
                    model: model,
                    child: Theme(
                      data: jinbaoTheme(),
                      child: GrowthCard(entry: model.session.timelineEntries().firstWhere((e) => e.id == memory.id)),
                    ),
                  ),
                ),
              ),
            // Captions above the phone.
            for (final (from, to, title, detail) in const [
              (4.4, 10.3, '把成长，排成一条时间线', '每一条，都标着她当时多大'),
              (10.6, 15.4, '那年今天', '一年前的今天，她刚学会自己坐稳'),
              (15.7, 20.6, '一键生成成长卡片', '发给爷爷奶奶，不带位置信息'),
              (21.0, 24.4, '重要的日子，提前想起', '纪念日倒数，就在这周'),
              (24.7, 27.9, '每个月，一起回看', '爸爸几条，妈妈几条，都在这里'),
            ])
              Positioned(
                left: 60,
                right: 60,
                top: 96,
                child: Caption(title,
                    detail: detail,
                    visible: window(t, from, to),
                    color: pop > 0.5 ? JinbaoColors.onNavy : JinbaoColors.ink,
                    titleSize: 70,
                    detailSize: 38),
              ),
            // 28.9-32 End card.
            if (t > 28.6) ...[
              Placed(
                center: const Offset(540, 700),
                scale: lerp(0.8, 1, easeOut(span(t, 28.8, 29.5))),
                opacity: span(t, 28.8, 29.3),
                child: const BrandMark(size: 190),
              ),
              Positioned(
                left: 60,
                right: 60,
                top: 860,
                child: Caption('DaysWith',
                    detail: '留住一起度过的日子',
                    visible: span(t, 29.1, 29.6),
                    titleSize: 120,
                    detailSize: 48,
                    color: JinbaoColors.onNavy),
              ),
              Positioned(
                left: 60,
                right: 60,
                top: 1210,
                child: Opacity(
                  opacity: span(t, 29.6, 30.1),
                  child: Wrap(alignment: WrapAlignment.center, spacing: 18, runSpacing: 18, children: [
                    for (final label in const ['开源 · MIT', '没有会员订阅', '可连接自己的云存储'])
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
                        decoration: BoxDecoration(color: JinbaoColors.gold, borderRadius: BorderRadius.circular(999)),
                        child: Text(label, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: JinbaoColors.ink)),
                      ),
                  ]),
                ),
              ),
              Positioned(
                left: 60,
                right: 60,
                top: 1460,
                child: Opacity(
                  opacity: span(t, 30.0, 30.5),
                  child: const Text('github.com/Henrypann/DaysWith',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 40, fontWeight: FontWeight.w600, color: JinbaoColors.onNavy)),
                ),
              ),
              Positioned(
                left: 60,
                right: 60,
                bottom: 90,
                child: Opacity(
                  opacity: span(t, 30.0, 30.5) * 0.6,
                  child: const Text('演示画面为合成插画与虚构记录 · 开发中的开源项目，需自行构建',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 26, color: JinbaoColors.onNavy)),
                ),
              ),
            ],
          ]);
        },
      ));

      // 0-5.4 Hook, then the phone arrives.
      await director.until(5.6);
      // 5.6-9.4 Scroll through the months.
      final timeline = scrollOf(tester, phone);
      timeline.animateTo(1500, duration: const Duration(milliseconds: 3600), curve: Curves.easeInOutCubic);
      await director.until(9.5);
      timeline.animateTo(0, duration: const Duration(milliseconds: 900), curve: Curves.easeInOutCubic);
      await director.until(12.4);
      // 12.4 Open the memory from a year ago.
      await director.tap(find.descendant(of: find.byType(MemoriesStrip), matching: find.text('第一次自己坐稳')));
      await director.until(15.6);
      // 15.6 Make its growth card.
      await director.tap(find.byTooltip('生成成长卡片'));
      await director.until(17.2);
      cardRect = tester.getRect(find.byType(GrowthCard).first);
      await director.until(20.4);
      // Behind the card: back to the tabs.
      Navigator.of(tester.element(find.text('成长卡片'))).popUntil((route) => route.isFirst);
      await director.until(20.9);
      await director.tap(find.descendant(of: phone, matching: find.text('纪念')));
      await director.until(24.5);
      await director.tap(find.descendant(of: phone, matching: find.text('回顾')));
      await director.until(25.6);
      scrollOf(tester, phone).animateTo(330, duration: const Duration(milliseconds: 2200), curve: Curves.easeInOut);
      await director.until(32);
      expect(model.tab, ShellTab.review);
    });
  });
}
