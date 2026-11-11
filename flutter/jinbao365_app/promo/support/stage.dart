import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/app_model.dart';
import 'package:jinbao365/theme.dart';

import 'demo.dart';

const promoFont = 'PromoSans';

/// 0 before [from], 1 after [to], linear in between.
double span(double t, double from, double to) => ((t - from) / (to - from)).clamp(0.0, 1.0);

double ease(double x) => Curves.easeInOutCubic.transform(x.clamp(0.0, 1.0));
double easeOut(double x) => Curves.easeOutCubic.transform(x.clamp(0.0, 1.0));
double lerp(double a, double b, double x) => a + (b - a) * x;

/// Visible between [from] and [to], fading over [fade] seconds at both ends.
double window(double t, double from, double to, {double fade = 0.35}) =>
    math.min(span(t, from, from + fade), 1 - span(t, to - fade, to));

class Touch {
  final Offset at;
  final double time;
  const Touch(this.at, this.time);
}

/// Drives a widget test as a film: every pumped frame is piped to ffmpeg as raw RGBA.
class Director {
  final WidgetTester tester;
  final Size size;
  final int fps;
  final clock = ValueNotifier<double>(0);
  final touches = ValueNotifier<List<Touch>>(const []);
  final stageKey = GlobalKey();
  Process? _ffmpeg;
  int frames = 0;

  Director(this.tester, {required this.size, this.fps = 30});

  double get now => frames / fps;

  /// [ffmpeg] comes from the PROMO_FFMPEG environment variable, or PATH.
  Future<void> start(String output, {String? audio}) async {
    final executable = Platform.environment['PROMO_FFMPEG'] ?? 'ffmpeg';
    await tester.runAsync(() async {
      File(output).parent.createSync(recursive: true);
      _ffmpeg = await Process.start(executable, [
        '-y', '-loglevel', 'error',
        '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '${size.width.round()}x${size.height.round()}', '-r', '$fps', '-i', '-',
        if (audio != null) ...['-i', audio],
        '-c:v', 'libx264', '-preset', 'medium', '-crf', '17', '-pix_fmt', 'yuv420p',
        if (audio != null) ...['-c:a', 'aac', '-b:a', '192k', '-shortest'],
        '-movflags', '+faststart', output,
      ]);
      _ffmpeg!.stderr.listen(stderr.add);
      _ffmpeg!.stdout.listen((_) {});
    });
  }

  Future<void> frame() async {
    clock.value = now;
    await tester.pump(Duration(microseconds: 1000000 ~/ fps));
    final boundary = stageKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData();
      image.dispose();
      _ffmpeg!.stdin.add(data!.buffer.asUint8List());
      await _ffmpeg!.stdin.flush();
    });
    frames++;
    if (frames % (fps * 4) == 0) debugPrint('  rendered ${now.toStringAsFixed(0)}s');
  }

  /// Renders frames until the film clock reaches [seconds].
  Future<void> until(double seconds) async {
    while (now < seconds - 1e-9) {
      await frame();
    }
  }

  /// Shows a finger at [finder], then taps it.
  Future<void> tap(Finder finder, {double lead = 0.3}) async {
    final at = tester.getCenter(finder);
    touches.value = [...touches.value, Touch(at, now)];
    await until(now + lead);
    await tester.tapAt(at);
  }

  Future<void> finish() async {
    await tester.runAsync(() async {
      await _ffmpeg!.stdin.close();
      final code = await _ffmpeg!.exitCode;
      if (code != 0) throw StateError('ffmpeg exited with $code');
    });
  }
}

/// The film frame: everything drawn here ends up in the video.
class Stage extends StatelessWidget {
  final Director director;
  final Widget Function(BuildContext context, double t) builder;
  const Stage({super.key, required this.director, required this.builder});

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: director.stageKey,
            child: SizedBox.fromSize(
              size: director.size,
              child: DefaultTextStyle(
                style: const TextStyle(fontFamily: promoFont, color: JinbaoColors.ink, fontSize: 32, height: 1.25),
                child: Stack(clipBehavior: Clip.hardEdge, children: [
                  Positioned.fill(
                    child: ValueListenableBuilder<double>(
                      valueListenable: director.clock,
                      builder: (context, t, _) => builder(context, t),
                    ),
                  ),
                  Positioned.fill(child: IgnorePointer(child: _Touches(director: director))),
                ]),
              ),
            ),
          ),
        ),
      );
}

class _Touches extends StatelessWidget {
  final Director director;
  const _Touches({required this.director});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
        valueListenable: director.clock,
        builder: (context, t, _) => CustomPaint(painter: _TouchPainter(director.touches.value, t)),
      );
}

class _TouchPainter extends CustomPainter {
  final List<Touch> touches;
  final double t;
  _TouchPainter(this.touches, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    for (final touch in touches) {
      final age = t - touch.time;
      if (age < 0 || age > 0.75) continue;
      final appear = easeOut(span(age, 0, 0.2)), leave = 1 - span(age, 0.45, 0.75);
      final radius = lerp(44, 30, appear) + span(age, 0.3, 0.75) * 18;
      canvas.drawCircle(touch.at, radius, Paint()..color = JinbaoColors.ink.withValues(alpha: 0.20 * appear * leave));
      canvas.drawCircle(
          touch.at,
          radius,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4
            ..color = Colors.white.withValues(alpha: 0.9 * appear * leave));
    }
  }

  @override
  bool shouldRepaint(_TouchPainter old) => true;
}

/// A neutral phone body around the real app. Keep one [GlobalKey] per phone so the app state
/// survives while the frame moves around the stage.
class Phone extends StatelessWidget {
  final AppModel model;
  static const screen = Size(390, 844);
  static const bezel = 12.0;
  static const body = Size(390 + bezel * 2, 844 + bezel * 2);
  const Phone({super.key, required this.model});

  @override
  Widget build(BuildContext context) => Container(
        width: body.width,
        height: body.height,
        padding: const EdgeInsets.all(bezel),
        decoration: BoxDecoration(
          color: const Color(0xFF14181F),
          borderRadius: BorderRadius.circular(58),
          border: Border.all(color: const Color(0xFF3A404A), width: 2),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 60, offset: const Offset(0, 30)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(46),
          child: Stack(children: [
            DemoApp(model: model, size: screen),
            const Positioned(top: 0, left: 0, right: 0, child: IgnorePointer(child: _StatusBar())),
          ]),
        ),
      );
}

class _StatusBar extends StatelessWidget {
  const _StatusBar();

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 47,
        child: Stack(alignment: Alignment.center, children: [
          Container(
            width: 104,
            height: 30,
            decoration: BoxDecoration(color: const Color(0xFF14181F), borderRadius: BorderRadius.circular(15)),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 30),
            child: Row(children: [
              Text('9:41',
                  style: TextStyle(fontFamily: promoFont, fontSize: 15, height: 1, fontWeight: FontWeight.w700, color: JinbaoColors.ink)),
              Spacer(),
              Icon(Icons.signal_cellular_alt, size: 16, color: JinbaoColors.ink),
              SizedBox(width: 5),
              Icon(Icons.wifi, size: 16, color: JinbaoColors.ink),
              SizedBox(width: 5),
              Icon(Icons.battery_full, size: 17, color: JinbaoColors.ink),
            ]),
          ),
        ]),
      );
}

/// Places [child] with its centre at [center], scaled, rotated and faded.
class Placed extends StatelessWidget {
  final Offset center;
  final double scale;
  final double angle;
  final double opacity;
  final Widget child;
  const Placed({super.key, required this.center, this.scale = 1, this.angle = 0, this.opacity = 1, required this.child});

  @override
  Widget build(BuildContext context) => Positioned(
        left: center.dx,
        top: center.dy,
        child: FractionalTranslation(
          translation: const Offset(-0.5, -0.5),
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..scaleByDouble(scale, scale, 1, 1)
              ..rotateZ(angle),
            child: Opacity(opacity: opacity.clamp(0.0, 1.0), child: child),
          ),
        ),
      );
}

/// A headline with an optional second line, rising into place.
class Caption extends StatelessWidget {
  final String title;
  final String? detail;
  final double visible;
  final double titleSize;
  final double detailSize;
  final Color color;
  final Color? detailColor;
  final TextAlign align;
  const Caption(this.title,
      {super.key,
      this.detail,
      required this.visible,
      this.titleSize = 68,
      this.detailSize = 36,
      this.color = JinbaoColors.ink,
      this.detailColor,
      this.align = TextAlign.center});

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: visible.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - easeOut(visible)) * 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: align == TextAlign.center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              Text(title,
                  textAlign: align,
                  style: TextStyle(fontSize: titleSize, fontWeight: FontWeight.w800, color: color, height: 1.22, letterSpacing: 1)),
              if (detail != null) ...[
                SizedBox(height: titleSize * 0.26),
                Text(detail!,
                    textAlign: align,
                    style: TextStyle(
                        fontSize: detailSize, fontWeight: FontWeight.w500, color: detailColor ?? color.withValues(alpha: 0.66), height: 1.4)),
              ],
            ],
          ),
        ),
      );
}

/// A rounded picture tile from the demo archive.
class PhotoTile extends StatelessWidget {
  final String path;
  final double width;
  final double height;
  const PhotoTile({super.key, required this.path, required this.width, required this.height});

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white, width: 6),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 30, offset: const Offset(0, 14))],
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.file(File(path), fit: BoxFit.cover),
      );
}

/// Shared setup and teardown for a film.
Future<void> film(
  WidgetTester tester, {
  required Size size,
  required String output,
  required String audio,
  required Future<void> Function(Director director, DemoArchive archive) shoot,
}) async {
  debugDisableShadows = false;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  final work = Directory.systemTemp.createTempSync('dayswith-promo-');
  late DemoArchive archive;
  await tester.runAsync(() async {
    await loadPromoFonts();
    archive = await DemoArchive.create(work);
  });
  await precacheDemoImages(tester, archive.imagePaths);
  final director = Director(tester, size: size);
  await director.start(output, audio: File(audio).existsSync() ? audio : null);
  try {
    await shoot(director, archive);
    await director.finish();
  } finally {
    await tester.pumpWidget(const SizedBox());
    debugDisableShadows = true;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.runAsync(() => work.delete(recursive: true));
  }
  debugPrint('wrote $output (${director.frames} frames)');
}

ScrollPosition scrollOf(WidgetTester tester, Finder within) =>
    tester.state<ScrollableState>(find.descendant(of: within, matching: find.byType(Scrollable)).first).position;

ui.Rect rectOf(WidgetTester tester, Finder finder) => tester.getRect(finder);
