@Timeout(Duration(minutes: 40))
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/app_model.dart';
import 'package:jinbao365/screens/my.dart';
import 'package:jinbao365/screens/shell.dart';
import 'package:jinbao365/theme.dart';
import 'package:jinbao_core/jinbao_core.dart';

import 'support/stage.dart';

const _night = Color(0xFF0B1D38);
const _cream = JinbaoColors.onNavy;

/// Video B 「你的照片，不该交房租」: 16:9, 31 s, for developers and people who want to own
/// their data. Chinese headlines with English subtitles. Every phone frame is the real 4.0 app.
///   flutter test promo/video_b_test.dart
void main() {
  testWidgets('video B', (tester) async {
    const size = Size(1920, 1080);
    await film(tester, size: size, output: '../../promo/out/dayswith-4.0-b-opensource-16x9.mp4', audio: '../../promo/out/music_b.wav',
        shoot: (director, archive) async {
      final dad = archive.model(ParentIdentity.dad,
          link: const CloudVerified(bucket: 'family-album-1250000000', region: 'ap-shanghai'));
      final mom = archive.model(ParentIdentity.mom);
      // A phone straight after choosing who holds it: no storage connected, nothing recorded.
      final fresh = AppModel.forSession(
          AppSession(deviceID: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', testBuild: false, identity: ParentIdentity.mom),
          directory: archive.directory.path);
      final dadKey = GlobalKey(), momKey = GlobalKey(), freshKey = GlobalKey();
      final dadPhone = find.byKey(dadKey), momPhone = find.byKey(momKey), freshPhone = find.byKey(freshKey);

      await tester.pumpWidget(Stage(
        director: director,
        builder: (context, t) {
          final pairIn = easeOut(span(t, 6.9, 7.9)), pairOut = ease(span(t, 13.2, 13.9));
          final freshIn = easeOut(span(t, 13.7, 14.5)), freshOut = ease(span(t, 18.5, 19.1));
          final cloudIn = easeOut(span(t, 18.9, 19.7)), cloudOut = ease(span(t, 23.9, 24.5));
          // The dad phone plays two parts: half of the pair, then the storage scene.
          final dadCenter = t < 16
              ? Offset(640, lerp(1700, 482, pairIn) + pairOut * 1300)
              : Offset(lerp(-400, 470, cloudIn) - cloudOut * 900, 520);
          return Stack(children: [
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_night, Color(0xFF17335C)]),
                ),
              ),
            ),
            // 0-4.2 Hook: the reminders every family album sends sooner or later.
            for (final (index, icon, title, detail) in const [
              (0, Icons.cloud_off_outlined, '云空间已满', '照片和视频已暂停备份'),
              (1, Icons.autorenew, '连续包月即将续费', '家庭共享相册 · ¥68 / 月'),
              (2, Icons.swap_horiz, '换了手机品牌？', '共享相册需要重新搬家'),
            ])
              if (t < 4.6)
                Placed(
                  center: Offset(960 + (index - 1) * 26.0, lerp(-120, 250 + index * 158.0, easeOut(span(t, 0.2 + index * 0.45, 0.9 + index * 0.45)))) +
                      Offset(-1900 * ease(span(t, 3.9 + index * 0.08, 4.6)), 0),
                  angle: (index - 1) * 0.025,
                  child: _Notice(icon: icon, title: title, detail: detail),
                ),
            if (t < 4.6)
              Positioned(
                left: 120,
                right: 120,
                top: 760,
                child: Caption('孩子的照片，为什么要一直交「房租」？',
                    detail: 'Why pay rent on your own family photos?',
                    visible: window(t, 1.9, 4.3),
                    titleSize: 68,
                    detailSize: 34,
                    color: JinbaoColors.gold,
                    detailColor: _cream.withValues(alpha: 0.75)),
              ),
            if (t < 4.6)
              Positioned(
                right: 48,
                bottom: 32,
                child: Opacity(
                  opacity: window(t, 0.4, 4.2) * 0.5,
                  child: const Text('示意画面 · Illustration', style: TextStyle(fontSize: 22, color: _cream)),
                ),
              ),
            // 4.4-7.0 Brand.
            if (t > 4.2 && t < 7.2) ...[
              Placed(
                center: const Offset(960, 380),
                scale: lerp(0.8, 1, easeOut(span(t, 4.5, 5.2))),
                opacity: window(t, 4.5, 6.9),
                child: const BrandMark(size: 170),
              ),
              Positioned(
                left: 120,
                right: 120,
                top: 520,
                child: Caption('DaysWith',
                    detail: '开源的家庭成长记录 · An open-source family journal',
                    visible: window(t, 4.8, 6.9),
                    titleSize: 120,
                    detailSize: 40,
                    color: _cream),
              ),
            ],
            // 6.9-13.9 Two phones, one timeline.
            Placed(center: dadCenter, scale: t < 16 ? 0.92 : 1.0, child: Phone(key: dadKey, model: dad)),
            Placed(
              center: Offset(1280, lerp(1900, 482, easeOut(span(t, 7.1, 8.1))) + pairOut * 1300),
              scale: 0.92,
              child: Phone(key: momKey, model: mom),
            ),
            for (final (x, label) in const [(640.0, '爸爸的手机'), (1280.0, '妈妈的手机')])
              Placed(
                center: Offset(x, 40),
                opacity: window(t, 8.0, 13.2),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
                  decoration: BoxDecoration(color: _cream.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
                  child: Text(label, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: _cream)),
                ),
              ),
            Positioned(
              left: 120,
              right: 120,
              top: 912,
              child: Caption('两台手机，各自署名，一条时间线',
                  detail: 'Two phones. Two signatures. One timeline.',
                  visible: window(t, 8.0, 13.2),
                  titleSize: 52,
                  detailSize: 28,
                  color: _cream),
            ),
            // 13.7-19.1 Local-first.
            Placed(
              center: Offset(lerp(-400, 470, freshIn) - freshOut * 900, 520),
              child: Phone(key: freshKey, model: fresh),
            ),
            Positioned(
              left: 820,
              right: 90,
              top: 250,
              child: _Pitch(
                visible: window(t, 14.2, 18.6),
                title: '先记在本机，\n不连云也能用',
                english: 'Local-first. No account, no cloud required.',
                points: const ['没有账号体系，打开就能记', '记录先保存在这台手机，不会上传', '想备份时，再连接自己的存储'],
              ),
            ),
            // 18.9-24.5 Bring your own bucket.
            Positioned(
              left: 820,
              right: 90,
              top: 170,
              child: _Pitch(
                visible: window(t, 19.4, 24.0),
                title: '想备份？\n连你自己的对象存储',
                english: 'Bring your own bucket. Keys stay on your phone.',
                points: const ['密钥只保存在手机的安全存储里', '连接前的本机记录，由你决定是否上传', 'life/v1/dad/ · life/v1/mom/ 各写各的目录'],
                footnote: '当前适配腾讯云 COS · 暂无端到端加密 · 备份在应用前台进行',
              ),
            ),
            // 24.4-27.7 What it is, plainly.
            if (t > 24.1 && t < 27.9) ...[
              Positioned(
                left: 120,
                right: 120,
                top: 150,
                child: Caption('代码都在这里，欢迎一起把它做好',
                    detail: "It's all in the repo. Come build it with us.",
                    visible: window(t, 24.4, 27.6),
                    titleSize: 60,
                    detailSize: 30,
                    color: _cream),
              ),
              for (final (index, big, label, english) in const [
                (0, 'MIT', '开源许可', 'Open source'),
                (1, '¥0', '会员订阅', 'No subscription'),
                (2, '本地优先', '4.0 新增', 'Local-first'),
                (3, 'Flutter', 'Android · iOS 源码', 'One codebase'),
              ])
                Placed(
                  center: Offset(330 + index * 420.0, lerp(700, 610, easeOut(span(t, 24.6 + index * 0.15, 25.2 + index * 0.15)))),
                  opacity: window(t, 24.6 + index * 0.15, 27.6),
                  child: _Fact(big: big, label: label, english: english),
                ),
            ],
            // 27.7-31 End card.
            if (t > 27.5) ...[
              Placed(
                center: const Offset(960, 300),
                scale: lerp(0.8, 1, easeOut(span(t, 27.8, 28.5))),
                opacity: span(t, 27.8, 28.3),
                child: const BrandMark(size: 150),
              ),
              Positioned(
                left: 120,
                right: 120,
                top: 420,
                child: Caption('DaysWith',
                    detail: 'Keep the days we share · 留住一起度过的日子',
                    visible: span(t, 28.0, 28.5),
                    titleSize: 110,
                    detailSize: 38,
                    color: _cream),
              ),
              Placed(
                center: const Offset(960, 790),
                opacity: span(t, 28.5, 29.0),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 18),
                  decoration: BoxDecoration(color: JinbaoColors.gold, borderRadius: BorderRadius.circular(999)),
                  child: const Text('github.com/Henrypann/DaysWith',
                      style: TextStyle(fontSize: 44, fontWeight: FontWeight.w700, color: JinbaoColors.ink)),
                ),
              ),
              Positioned(
                left: 120,
                right: 120,
                bottom: 60,
                child: Opacity(
                  opacity: span(t, 28.8, 29.3) * 0.6,
                  child: const Text('演示画面为合成插画与虚构记录 · Screens show synthetic demo data · 开发中，需自行构建',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 24, color: _cream)),
                ),
              ),
            ],
          ]);
        },
      ));

      // 0-8.6 Hook, brand, the pair arrives.
      await director.until(8.7);
      scrollOf(tester, dadPhone).animateTo(1250, duration: const Duration(milliseconds: 3800), curve: Curves.easeInOutCubic);
      await director.until(8.9);
      scrollOf(tester, momPhone).animateTo(1250, duration: const Duration(milliseconds: 3800), curve: Curves.easeInOutCubic);
      await director.until(15.5);
      // 15.5 Skip the storage form on the fresh phone and start recording.
      await director.tap(find.descendant(of: freshPhone, matching: find.text('先在这台手机记录')));
      await director.until(17.0);
      await director.tap(find.descendant(of: freshPhone, matching: find.byIcon(Icons.add)));
      // Off screen: put the connected phone on its backup page.
      dad.selectTab(ShellTab.my);
      Navigator.of(tester.element(find.descendant(of: dadPhone, matching: find.byType(MainShell))))
          .push(MaterialPageRoute<void>(builder: (_) => const CloudPage(title: '云备份')));
      await director.until(21.0);
      // 21.0 Down to the write path.
      scrollOf(tester, dadPhone).animateTo(260, duration: const Duration(milliseconds: 1800), curve: Curves.easeInOut);
      await director.until(31);
      expect(fresh.localFirst, isTrue);
    });
  });
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  const _Notice({required this.icon, required this.title, required this.detail});

  @override
  Widget build(BuildContext context) => Container(
        width: 820,
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(32),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 40, offset: const Offset(0, 16))],
        ),
        child: Row(children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(color: JinbaoColors.problemSoft, borderRadius: BorderRadius.circular(22)),
            child: Icon(icon, size: 46, color: JinbaoColors.problem),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w700, height: 1.2)),
              const SizedBox(height: 6),
              Text(detail, style: const TextStyle(fontSize: 28, color: JinbaoColors.inkSecondary, height: 1.2)),
            ]),
          ),
          const Text('现在', style: TextStyle(fontSize: 24, color: JinbaoColors.outline)),
        ]),
      );
}

class _Pitch extends StatelessWidget {
  final double visible;
  final String title;
  final String english;
  final List<String> points;
  final String? footnote;
  const _Pitch({required this.visible, required this.title, required this.english, required this.points, this.footnote});

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: visible.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset((1 - easeOut(visible)) * 40, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 76, fontWeight: FontWeight.w800, color: _cream, height: 1.2)),
            const SizedBox(height: 18),
            Text(english, style: const TextStyle(fontSize: 32, color: JinbaoColors.gold, fontWeight: FontWeight.w500)),
            const SizedBox(height: 40),
            for (final point in points)
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 6, right: 18),
                    child: Icon(Icons.check_circle, size: 36, color: JinbaoColors.gold),
                  ),
                  Expanded(child: Text(point, style: const TextStyle(fontSize: 36, color: _cream, height: 1.3))),
                ]),
              ),
            if (footnote != null) ...[
              const SizedBox(height: 18),
              Text(footnote!, style: TextStyle(fontSize: 24, color: _cream.withValues(alpha: 0.6))),
            ],
          ]),
        ),
      );
}

class _Fact extends StatelessWidget {
  final String big;
  final String label;
  final String english;
  const _Fact({required this.big, required this.label, required this.english});

  @override
  Widget build(BuildContext context) => Container(
        width: 380,
        height: 330,
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: _cream.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(36),
          border: Border.all(color: _cream.withValues(alpha: 0.18), width: 2),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          FittedBox(
            child: Text(big, style: const TextStyle(fontSize: 84, fontWeight: FontWeight.w800, color: JinbaoColors.gold, height: 1.1)),
          ),
          const SizedBox(height: 18),
          Text(label, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w600, color: _cream)),
          const SizedBox(height: 6),
          Text(english, style: TextStyle(fontSize: 26, color: _cream.withValues(alpha: 0.65))),
        ]),
      );
}
