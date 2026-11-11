import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Synthetic picture-book illustrations that stand in for family photos in demos and promo
/// videos. Everything is drawn by code: no photographs, people or third-party artwork.
typedef Scene = void Function(Canvas c, Size s);

class DemoArt {
  final String name;
  final Size size;
  final Scene paint;
  const DemoArt(this.name, this.size, this.paint);

  Future<ui.Image> render() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.clipRect(Offset.zero & size);
    paint(canvas, size);
    _finish(canvas, size, name.hashCode);
    return recorder.endRecording().toImage(size.width.round(), size.height.round());
  }

  static const portrait = Size(900, 1200);
  static const landscape = Size(1200, 900);
  static const square = Size(1000, 1000);

  static final all = <String, DemoArt>{
    for (final art in [
      DemoArt('crib', portrait, _crib),
      DemoArt('storybook', landscape, _storybook),
      DemoArt('teddy', portrait, _teddy),
      DemoArt('snowman', portrait, _snowman),
      DemoArt('cake', square, _cake),
      DemoArt('bunting', landscape, _bunting),
      DemoArt('steps', landscape, _steps),
      DemoArt('picnic', portrait, _picnic),
      DemoArt('beach', landscape, _beach),
      DemoArt('duck', square, _duck),
      DemoArt('kite', portrait, _kite),
      DemoArt('blocks', square, _blocks),
      DemoArt('slide', portrait, _slide),
      DemoArt('balloon', portrait, _balloon),
      DemoArt('boots', portrait, _boots),
      DemoArt('porridge', landscape, _porridge),
    ])
      art.name: art,
  };
}

// Palette.
const _cream = Color(0xFFFDF6E9);
const _gold = Color(0xFFF7C948);
const _navy = Color(0xFF0F2747);
const _coral = Color(0xFFF28B6C);
const _mint = Color(0xFF9ED9C5);
const _skyBlue = Color(0xFFBFE3F5);
const _pink = Color(0xFFF9C6CF);
const _lavender = Color(0xFFC9C3F0);
const _leaf = Color(0xFF7DBE8C);
const _wood = Color(0xFFD9A56B);
const _white = Color(0xFFFFFFFF);

Paint _fill(Color color) => Paint()
  ..color = color
  ..isAntiAlias = true;

Paint _stroke(Color color, double width) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..strokeWidth = width
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round
  ..isAntiAlias = true;

void _gradient(Canvas c, Rect rect, List<Color> colors, {Alignment begin = Alignment.topCenter, Alignment end = Alignment.bottomCenter}) {
  c.drawRect(rect, Paint()..shader = LinearGradient(begin: begin, end: end, colors: colors).createShader(rect));
}

void _sun(Canvas c, Offset center, double radius, {Color color = _gold}) {
  c.drawCircle(
      center,
      radius * 2.4,
      Paint()
        ..shader = RadialGradient(colors: [color.withValues(alpha: 0.45), color.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: center, radius: radius * 2.4)));
  c.drawCircle(center, radius, _fill(color));
}

void _cloud(Canvas c, Offset at, double scale, {Color color = _white}) {
  final paint = _fill(color);
  c.drawCircle(at, 46 * scale, paint);
  c.drawCircle(at + Offset(52 * scale, 10 * scale), 38 * scale, paint);
  c.drawCircle(at + Offset(-50 * scale, 14 * scale), 34 * scale, paint);
  c.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(at.dx - 84 * scale, at.dy + 6 * scale, 172 * scale, 40 * scale), Radius.circular(20 * scale)),
      paint);
}

void _hill(Canvas c, Size s, double top, Color color, {double amp = 40, double phase = 0, double waves = 1.2}) {
  final path = Path()..moveTo(0, s.height);
  for (var x = 0.0; x <= s.width; x += 10) {
    path.lineTo(x, top + math.sin(x / s.width * math.pi * 2 * waves + phase) * amp);
  }
  path
    ..lineTo(s.width, s.height)
    ..close();
  c.drawPath(path, _fill(color));
}

void _shadow(Canvas c, Offset center, double width, {double alpha = 0.14}) {
  c.drawOval(Rect.fromCenter(center: center, width: width, height: width * 0.16), _fill(_navy.withValues(alpha: alpha)));
}

RRect _rr(double l, double t, double w, double h, double r) =>
    RRect.fromRectAndRadius(Rect.fromLTWH(l, t, w, h), Radius.circular(r));

void _star(Canvas c, Offset center, double radius, Color color) {
  final path = Path();
  for (var i = 0; i < 10; i++) {
    final r = i.isEven ? radius : radius * 0.45;
    final a = -math.pi / 2 + i * math.pi / 5;
    final p = center + Offset(math.cos(a) * r, math.sin(a) * r);
    i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
  }
  c.drawPath(path..close(), _fill(color));
}

/// Paper grain and a soft vignette, so the flat shapes sit like a printed picture.
void _finish(Canvas c, Size s, int seed) {
  final random = math.Random(seed);
  final light = _fill(_white.withValues(alpha: 0.05)), dark = _fill(_navy.withValues(alpha: 0.035));
  for (var i = 0; i < 2600; i++) {
    c.drawCircle(Offset(random.nextDouble() * s.width, random.nextDouble() * s.height), 0.8 + random.nextDouble() * 1.4,
        i.isEven ? light : dark);
  }
  final rect = Offset.zero & s;
  c.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(radius: 0.95, colors: [_navy.withValues(alpha: 0), _navy.withValues(alpha: 0.16)], stops: const [0.62, 1])
            .createShader(rect));
}

// Scenes.

void _crib(Canvas c, Size s) {
  _gradient(c, Offset.zero & s, const [Color(0xFFFFE9C7), Color(0xFFFAD7B5)]);
  // Window with the morning sun.
  final window = _rr(s.width * 0.14, s.height * 0.08, s.width * 0.5, s.height * 0.42, 28);
  c.drawRRect(window, _fill(_skyBlue));
  c.save();
  c.clipRRect(window);
  _sun(c, Offset(s.width * 0.5, s.height * 0.4), 90);
  _hill(c, s, s.height * 0.44, _mint, amp: 18);
  c.restore();
  c.drawRRect(window, _stroke(_white, 16));
  c.drawLine(Offset(s.width * 0.39, s.height * 0.08), Offset(s.width * 0.39, s.height * 0.5), _stroke(_white, 12));
  // Mobile.
  final hook = Offset(s.width * 0.76, s.height * 0.05);
  c.drawLine(hook, Offset(s.width * 0.76, s.height * 0.2), _stroke(_wood, 8));
  c.drawLine(Offset(s.width * 0.62, s.height * 0.2), Offset(s.width * 0.9, s.height * 0.2), _stroke(_wood, 8));
  for (final (dx, len, color) in [(0.62, 0.12, _coral), (0.76, 0.17, _gold), (0.9, 0.1, _lavender)]) {
    final end = Offset(s.width * dx, s.height * (0.2 + len));
    c.drawLine(Offset(s.width * dx, s.height * 0.2), end, _stroke(_navy.withValues(alpha: 0.35), 3));
    _star(c, end + const Offset(0, 30), 34, color);
  }
  // Crib.
  c.drawRect(Rect.fromLTWH(0, s.height * 0.86, s.width, s.height * 0.14), _fill(const Color(0xFFE8B98A)));
  final crib = Rect.fromLTWH(s.width * 0.1, s.height * 0.58, s.width * 0.8, s.height * 0.3);
  c.drawRRect(RRect.fromRectAndRadius(crib.deflate(24), const Radius.circular(18)), _fill(_cream));
  c.drawRRect(_rr(crib.left + 40, crib.top + 60, crib.width * 0.5, 120, 60), _fill(_pink));
  for (var x = crib.left; x <= crib.right + 1; x += crib.width / 9) {
    c.drawLine(Offset(x, crib.top), Offset(x, crib.bottom), _stroke(_white, 16));
  }
  c.drawLine(crib.topLeft, crib.topRight, _stroke(_white, 22));
  c.drawLine(crib.bottomLeft, crib.bottomRight, _stroke(_white, 22));
}

void _storybook(Canvas c, Size s) {
  _gradient(c, Offset.zero & s, const [Color(0xFF1B2F55), Color(0xFF32487A)]);
  final random = math.Random(7);
  for (var i = 0; i < 26; i++) {
    _star(c, Offset(random.nextDouble() * s.width, random.nextDouble() * s.height * 0.5), 6 + random.nextDouble() * 9,
        _cream.withValues(alpha: 0.75));
  }
  c.drawCircle(Offset(s.width * 0.82, s.height * 0.2), 70, _fill(_cream));
  c.drawCircle(Offset(s.width * 0.85, s.height * 0.18), 62, _fill(const Color(0xFF22365F)));
  // Lamp glow.
  final lamp = Offset(s.width * 0.16, s.height * 0.42);
  c.drawCircle(
      lamp,
      380,
      Paint()
        ..shader = RadialGradient(colors: [_gold.withValues(alpha: 0.5), _gold.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: lamp, radius: 380)));
  c.drawPath(
      Path()
        ..moveTo(lamp.dx - 90, lamp.dy + 30)
        ..lineTo(lamp.dx + 90, lamp.dy + 30)
        ..lineTo(lamp.dx + 56, lamp.dy - 90)
        ..lineTo(lamp.dx - 56, lamp.dy - 90)
        ..close(),
      _fill(_gold));
  c.drawLine(lamp + const Offset(0, 30), lamp + const Offset(0, 230), _stroke(_wood, 14));
  // Blanket and open book.
  _hill(c, s, s.height * 0.72, _coral, amp: 26, waves: 1.6);
  _hill(c, s, s.height * 0.8, const Color(0xFFE5745A), amp: 18, phase: 2);
  final center = Offset(s.width * 0.56, s.height * 0.64);
  for (final sign in [-1.0, 1.0]) {
    final page = Path()
      ..moveTo(center.dx, center.dy - 120)
      ..quadraticBezierTo(center.dx + sign * 130, center.dy - 170, center.dx + sign * 270, center.dy - 120)
      ..lineTo(center.dx + sign * 270, center.dy + 80)
      ..quadraticBezierTo(center.dx + sign * 130, center.dy + 30, center.dx, center.dy + 80)
      ..close();
    c.drawPath(page, _fill(_cream));
    for (var i = 0; i < 4; i++) {
      final y = center.dy - 70 + i * 34.0;
      c.drawLine(Offset(center.dx + sign * 50, y - 12), Offset(center.dx + sign * 220, y), _stroke(_navy.withValues(alpha: 0.22), 6));
    }
  }
  _star(c, center + const Offset(-150, -70), 30, _gold);
}

void _teddy(Canvas c, Size s) {
  _gradient(c, Offset.zero & s, const [Color(0xFFDDEBF7), Color(0xFFF4E3D3)]);
  c.drawRect(Rect.fromLTWH(0, s.height * 0.7, s.width, s.height * 0.3), _fill(const Color(0xFFF7D9C4)));
  // Play mat.
  c.drawOval(Rect.fromCenter(center: Offset(s.width / 2, s.height * 0.82), width: s.width * 0.92, height: 300), _fill(_mint));
  c.drawOval(Rect.fromCenter(center: Offset(s.width / 2, s.height * 0.82), width: s.width * 0.72, height: 220), _fill(const Color(0xFFB7E6D6)));
  final body = Offset(s.width * 0.5, s.height * 0.62);
  const fur = Color(0xFFC98F5A), light = Color(0xFFEBC79B);
  _shadow(c, body + const Offset(0, 250), 480);
  // Legs, arms, body, head.
  for (final sign in [-1.0, 1.0]) {
    c.drawOval(Rect.fromCenter(center: body + Offset(sign * 150, 190), width: 180, height: 130), _fill(fur));
    c.drawOval(Rect.fromCenter(center: body + Offset(sign * 160, 196), width: 90, height: 70), _fill(light));
    c.drawOval(Rect.fromCenter(center: body + Offset(sign * 190, 10), width: 110, height: 190), _fill(fur));
    c.drawCircle(body + Offset(sign * 150, -330), 70, _fill(fur));
    c.drawCircle(body + Offset(sign * 150, -330), 38, _fill(light));
  }
  c.drawOval(Rect.fromCenter(center: body, width: 340, height: 400), _fill(fur));
  c.drawOval(Rect.fromCenter(center: body + const Offset(0, 30), width: 200, height: 250), _fill(light));
  c.drawCircle(body + const Offset(0, -230), 170, _fill(fur));
  c.drawOval(Rect.fromCenter(center: body + const Offset(0, -180), width: 150, height: 110), _fill(light));
  c.drawCircle(body + const Offset(-64, -260), 16, _fill(_navy));
  c.drawCircle(body + const Offset(64, -260), 16, _fill(_navy));
  c.drawOval(Rect.fromCenter(center: body + const Offset(0, -204), width: 44, height: 30), _fill(_navy));
  c.drawArc(Rect.fromCenter(center: body + const Offset(0, -176), width: 70, height: 50), 0.3, math.pi - 0.6, false, _stroke(_navy, 6));
  // Bow.
  c.drawPath(
      Path()
        ..moveTo(body.dx, body.dy - 70)
        ..lineTo(body.dx - 80, body.dy - 110)
        ..lineTo(body.dx - 80, body.dy - 30)
        ..close()
        ..moveTo(body.dx, body.dy - 70)
        ..lineTo(body.dx + 80, body.dy - 110)
        ..lineTo(body.dx + 80, body.dy - 30)
        ..close(),
      _fill(_coral));
  c.drawCircle(body + const Offset(0, -70), 20, _fill(const Color(0xFFE5745A)));
}

void _snowman(Canvas c, Size s) {
  _gradient(c, Offset.zero & s, const [Color(0xFFB9D4EC), Color(0xFFE6F0F8)]);
  _hill(c, s, s.height * 0.66, const Color(0xFFDCE9F4), amp: 30);
  _hill(c, s, s.height * 0.76, _white, amp: 22, phase: 1.4);
  // Pines.
  for (final (x, h) in [(0.12, 300.0), (0.86, 360.0), (0.74, 220.0)]) {
    final base = Offset(s.width * x, s.height * 0.72);
    c.drawRect(Rect.fromCenter(center: base, width: 26, height: 60), _fill(_wood));
    for (var i = 0; i < 3; i++) {
      final top = base.dy - h + i * h * 0.26, half = 60.0 + i * 34;
      c.drawPath(
          Path()
            ..moveTo(base.dx, top)
            ..lineTo(base.dx - half, top + h * 0.42)
            ..lineTo(base.dx + half, top + h * 0.42)
            ..close(),
          _fill(const Color(0xFF5E9C7B)));
    }
  }
  final base = Offset(s.width * 0.46, s.height * 0.8);
  _shadow(c, base + const Offset(20, 150), 420, alpha: 0.1);
  c.drawCircle(base, 170, _fill(_white));
  c.drawCircle(base + const Offset(0, -230), 125, _fill(_white));
  c.drawCircle(base + const Offset(0, -410), 88, _fill(_white));
  c.drawCircle(base, 170, _stroke(const Color(0xFFD5E3EF), 5));
  // Face, scarf, hat, arms.
  c.drawCircle(base + const Offset(-30, -430), 10, _fill(_navy));
  c.drawCircle(base + const Offset(30, -430), 10, _fill(_navy));
  c.drawPath(
      Path()
        ..moveTo(base.dx, base.dy - 410)
        ..lineTo(base.dx + 86, base.dy - 396)
        ..lineTo(base.dx, base.dy - 388)
        ..close(),
      _fill(_coral));
  c.drawRRect(_rr(base.dx - 100, base.dy - 352, 200, 44, 22), _fill(_coral));
  c.drawRRect(_rr(base.dx + 40, base.dy - 340, 44, 130, 20), _fill(const Color(0xFFE5745A)));
  c.drawRRect(_rr(base.dx - 70, base.dy - 600, 140, 120, 16), _fill(_navy));
  c.drawRRect(_rr(base.dx - 110, base.dy - 500, 220, 26, 13), _fill(_navy));
  c.drawLine(base + const Offset(-110, -260), base + const Offset(-250, -360), _stroke(_wood, 12));
  c.drawLine(base + const Offset(110, -260), base + const Offset(250, -350), _stroke(_wood, 12));
  for (var i = 0; i < 3; i++) {
    c.drawCircle(base + Offset(0, -290 + i * 60.0), 12, _fill(_navy));
  }
  final random = math.Random(3);
  for (var i = 0; i < 70; i++) {
    c.drawCircle(Offset(random.nextDouble() * s.width, random.nextDouble() * s.height), 4 + random.nextDouble() * 6,
        _fill(_white.withValues(alpha: 0.9)));
  }
}

void _cake(Canvas c, Size s) {
  _gradient(c, Offset.zero & s, const [Color(0xFFFFE3D6), Color(0xFFFFD0C2)]);
  final random = math.Random(11);
  for (var i = 0; i < 46; i++) {
    final at = Offset(random.nextDouble() * s.width, random.nextDouble() * s.height * 0.62);
    c.save();
    c.translate(at.dx, at.dy);
    c.rotate(random.nextDouble() * math.pi);
    c.drawRRect(_rr(-14, -5, 28, 10, 5), _fill([_gold, _mint, _lavender, _white, _coral][i % 5]));
    c.restore();
  }
  c.drawRect(Rect.fromLTWH(0, s.height * 0.78, s.width, s.height * 0.22), _fill(_cream));
  final center = Offset(s.width / 2, s.height * 0.78);
  _shadow(c, center + const Offset(0, 16), 760);
  c.drawRRect(_rr(center.dx - 370, center.dy - 16, 740, 34, 17), _fill(_white));
  c.drawRRect(_rr(center.dx - 300, center.dy - 250, 600, 240, 36), _fill(const Color(0xFFF7B7A3)));
  // Icing with drips.
  final icing = Path()..addRRect(_rr(center.dx - 300, center.dy - 290, 600, 90, 40));
  for (var i = 0; i < 7; i++) {
    icing.addRRect(_rr(center.dx - 280 + i * 84.0, center.dy - 240, 52, 60 + (i % 3) * 34.0, 26));
  }
  c.drawPath(icing, _fill(_white));
  for (var i = 0; i < 6; i++) {
    c.drawCircle(Offset(center.dx - 240 + i * 96.0, center.dy - 300), 30, _fill(_coral));
  }
  // One candle.
  c.drawRRect(_rr(center.dx - 16, center.dy - 470, 32, 170, 12), _fill(_gold));
  for (var i = 0; i < 4; i++) {
    c.drawLine(Offset(center.dx - 16, center.dy - 440 + i * 40.0), Offset(center.dx + 16, center.dy - 460 + i * 40.0), _stroke(_white, 8));
  }
  final flame = Offset(center.dx, center.dy - 520);
  c.drawCircle(
      flame,
      150,
      Paint()
        ..shader = RadialGradient(colors: [_gold.withValues(alpha: 0.6), _gold.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: flame, radius: 150)));
  c.drawOval(Rect.fromCenter(center: flame, width: 46, height: 80), _fill(const Color(0xFFFFA24C)));
  c.drawOval(Rect.fromCenter(center: flame + const Offset(0, 10), width: 22, height: 40), _fill(_cream));
}

void _bunting(Canvas c, Size s) {
  _gradient(c, Offset.zero & s, const [Color(0xFFFFF1D6), Color(0xFFFFE0C7)]);
  for (final (y, sag) in [(0.14, 110.0), (0.3, 70.0)]) {
    final start = Offset(-20, s.height * y), end = Offset(s.width + 20, s.height * y);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..quadraticBezierTo(s.width / 2, start.dy + sag * 2, end.dx, end.dy);
    c.drawPath(path, _stroke(_navy.withValues(alpha: 0.5), 5));
    final metric = path.computeMetrics().first;
    for (var i = 1; i < 11; i++) {
      final at = metric.getTangentForOffset(metric.length * i / 11)!.position;
      c.drawPath(
          Path()
            ..moveTo(at.dx - 44, at.dy)
            ..lineTo(at.dx + 44, at.dy)
            ..lineTo(at.dx, at.dy + 96)
            ..close(),
          _fill([_coral, _gold, _mint, _lavender, _pink][i % 5]));
    }
  }
  // Balloons and gifts.
  for (final (x, y, color) in [(0.2, 0.52, _coral), (0.32, 0.44, _gold), (0.44, 0.54, _lavender)]) {
    final at = Offset(s.width * x, s.height * y);
    c.drawLine(at + const Offset(0, 90), Offset(s.width * 0.32, s.height * 0.95), _stroke(_navy.withValues(alpha: 0.3), 3));
    c.drawOval(Rect.fromCenter(center: at, width: 150, height: 180), _fill(color));
    c.drawOval(Rect.fromCenter(center: at + const Offset(-30, -40), width: 34, height: 50), _fill(_white.withValues(alpha: 0.5)));
  }
  c.drawRect(Rect.fromLTWH(0, s.height * 0.84, s.width, s.height * 0.16), _fill(_cream));
  for (final (x, w, h, color) in [(0.6, 230.0, 190.0, _mint), (0.78, 180.0, 260.0, _pink)]) {
    final left = s.width * x, top = s.height * 0.86 - h;
    _shadow(c, Offset(left + w / 2, s.height * 0.865), w * 1.2);
    c.drawRRect(_rr(left, top, w, h, 14), _fill(color));
    c.drawRect(Rect.fromLTWH(left + w / 2 - 14, top, 28, h), _fill(_coral));
    c.drawOval(Rect.fromCenter(center: Offset(left + w / 2 - 36, top - 14), width: 70, height: 44), _fill(_coral));
    c.drawOval(Rect.fromCenter(center: Offset(left + w / 2 + 36, top - 14), width: 70, height: 44), _fill(_coral));
  }
}

void _steps(Canvas c, Size s) {
  _gradient(c, Offset.zero & s, const [Color(0xFFF6E7D4), Color(0xFFEFD3B2)]);
  // Wooden floor boards in perspective.
  final horizon = s.height * 0.34;
  c.drawRect(Rect.fromLTWH(0, horizon, s.width, s.height - horizon), _fill(const Color(0xFFE3B581)));
  for (var i = -8; i <= 8; i++) {
    c.drawLine(Offset(s.width / 2 + i * 40, horizon), Offset(s.width / 2 + i * 240, s.height), _stroke(const Color(0xFFCB9A64), 5));
  }
  c.drawRect(Rect.fromLTWH(0, horizon - 26, s.width, 26), _fill(_white));
  // Sunlit patch from a door.
  c.drawPath(
      Path()
        ..moveTo(s.width * 0.56, horizon)
        ..lineTo(s.width * 0.8, horizon)
        ..lineTo(s.width * 1.1, s.height)
        ..lineTo(s.width * 0.5, s.height)
        ..close(),
      _fill(_gold.withValues(alpha: 0.28)));
  // Footprints leading to a pair of small shoes.
  for (var i = 0; i < 6; i++) {
    final t = i / 6, left = i.isEven;
    final at = Offset(s.width * (0.16 + t * 0.44) , s.height * (0.9 - t * 0.34) + (left ? -26 : 26));
    final scale = 1.0 - t * 0.35;
    c.save();
    c.translate(at.dx, at.dy);
    c.rotate(-0.5);
    c.drawOval(Rect.fromCenter(center: Offset.zero, width: 46 * scale, height: 78 * scale), _fill(_navy.withValues(alpha: 0.13)));
    c.restore();
  }
  for (final (dx, dy) in [(0.66, 0.6), (0.76, 0.66)]) {
    final at = Offset(s.width * dx, s.height * dy);
    _shadow(c, at + const Offset(0, 62), 250);
    c.drawRRect(_rr(at.dx - 110, at.dy - 20, 220, 84, 42), _fill(_coral));
    c.drawRRect(_rr(at.dx - 110, at.dy - 70, 120, 100, 44), _fill(_coral));
    c.drawRRect(_rr(at.dx - 112, at.dy + 44, 224, 24, 12), _fill(_white));
    c.drawCircle(at + const Offset(52, 14), 14, _fill(_white));
    c.drawRRect(_rr(at.dx - 96, at.dy - 62, 92, 30, 15), _fill(const Color(0xFFE5745A)));
  }
}

void _picnic(Canvas c, Size s) {
  _gradient(c, Offset.zero & s, const [_skyBlue, Color(0xFFE5F4E3)]);
  _sun(c, Offset(s.width * 0.8, s.height * 0.14), 64);
  _cloud(c, Offset(s.width * 0.26, s.height * 0.14), 1.1);
  _hill(c, s, s.height * 0.42, const Color(0xFFA8D8A0), amp: 36);
  _hill(c, s, s.height * 0.52, _leaf, amp: 24, phase: 2.2);
  // Tree.
  final trunk = Offset(s.width * 0.2, s.height * 0.5);
  c.drawRRect(_rr(trunk.dx - 22, trunk.dy - 150, 44, 190, 16), _fill(_wood));
  for (final (dx, dy, r) in [(0.0, -250.0, 130.0), (-100.0, -180.0, 96.0), (100.0, -190.0, 100.0)]) {
    c.drawCircle(trunk + Offset(dx, dy), r, _fill(const Color(0xFF5FAF76)));
  }
  // Checked blanket.
  final blanket = Path()
    ..moveTo(s.width * 0.14, s.height * 0.7)
    ..lineTo(s.width * 0.8, s.height * 0.62)
    ..lineTo(s.width * 0.96, s.height * 0.88)
    ..lineTo(s.width * 0.08, s.height * 0.96)
    ..close();
  c.drawPath(blanket, _fill(_cream));
  c.save();
  c.clipPath(blanket);
  for (var i = -4; i < 14; i++) {
    c.drawLine(Offset(i * 110.0, s.height * 0.58), Offset(i * 110.0 - 120, s.height), _stroke(_coral.withValues(alpha: 0.55), 34));
    c.drawLine(Offset(0, s.height * 0.6 + i * 70.0), Offset(s.width, s.height * 0.52 + i * 70.0), _stroke(_coral.withValues(alpha: 0.3), 26));
  }
  c.restore();
  // Basket and strawberries.
  final basket = Offset(s.width * 0.42, s.height * 0.74);
  c.drawArc(Rect.fromCenter(center: basket + const Offset(0, -40), width: 250, height: 260), math.pi, math.pi, false, _stroke(_wood, 18));
  c.drawRRect(_rr(basket.dx - 150, basket.dy - 40, 300, 170, 30), _fill(const Color(0xFFC98F5A)));
  for (var i = 0; i < 4; i++) {
    c.drawLine(Offset(basket.dx - 150, basket.dy + i * 40.0), Offset(basket.dx + 150, basket.dy + i * 40.0), _stroke(_wood, 8));
  }
  for (final (dx, dy) in [(0.68, 0.8), (0.76, 0.84), (0.7, 0.88)]) {
    final at = Offset(s.width * dx, s.height * dy);
    c.drawPath(
        Path()
          ..moveTo(at.dx - 34, at.dy - 20)
          ..quadraticBezierTo(at.dx, at.dy - 44, at.dx + 34, at.dy - 20)
          ..quadraticBezierTo(at.dx + 30, at.dy + 30, at.dx, at.dy + 46)
          ..quadraticBezierTo(at.dx - 30, at.dy + 30, at.dx - 34, at.dy - 20)
          ..close(),
        _fill(const Color(0xFFE5574F)));
    _star(c, at + const Offset(0, -28), 20, _leaf);
  }
}

void _beach(Canvas c, Size s) {
  _gradient(c, Offset.zero & s, const [Color(0xFFFFD9A8), Color(0xFFBFE3F5)]);
  _sun(c, Offset(s.width * 0.72, s.height * 0.3), 80, color: const Color(0xFFFFB45E));
  c.drawRect(Rect.fromLTWH(0, s.height * 0.4, s.width, s.height * 0.3), _fill(const Color(0xFF6FB7D6)));
  for (var i = 0; i < 4; i++) {
    _hill(c, s, s.height * (0.47 + i * 0.05), [const Color(0xFF63ABCB), const Color(0xFF7DC3DE)][i % 2].withValues(alpha: 0.8),
        amp: 9, waves: 3.5, phase: i * 1.3);
  }
  _hill(c, s, s.height * 0.64, _white, amp: 12, waves: 2.2, phase: 0.6);
  _hill(c, s, s.height * 0.66, const Color(0xFFF6DFB4), amp: 12, waves: 2.2, phase: 0.6);
  // Small footprints.
  for (var i = 0; i < 7; i++) {
    final at = Offset(s.width * (0.1 + i * 0.065), s.height * (0.92 - i * 0.022) + (i.isEven ? -16 : 16));
    c.drawOval(Rect.fromCenter(center: at, width: 44, height: 26), _fill(const Color(0xFFDDBF8C)));
  }
  // Bucket, spade and sandcastle.
  final bucket = Offset(s.width * 0.68, s.height * 0.8);
  _shadow(c, bucket + const Offset(0, 96), 300);
  c.drawPath(
      Path()
        ..moveTo(bucket.dx - 110, bucket.dy - 90)
        ..lineTo(bucket.dx + 110, bucket.dy - 90)
        ..lineTo(bucket.dx + 84, bucket.dy + 90)
        ..lineTo(bucket.dx - 84, bucket.dy + 90)
        ..close(),
      _fill(_coral));
  c.drawRRect(_rr(bucket.dx - 122, bucket.dy - 110, 244, 34, 17), _fill(const Color(0xFFE5745A)));
  c.drawArc(Rect.fromCenter(center: bucket + const Offset(0, -100), width: 220, height: 200), math.pi, math.pi, false, _stroke(_white, 10));
  _star(c, bucket + const Offset(0, 6), 40, _gold);
  final castle = Offset(s.width * 0.42, s.height * 0.78);
  for (final (dx, w, h) in [(-90.0, 90.0, 150.0), (0.0, 110.0, 210.0), (90.0, 90.0, 150.0)]) {
    c.drawRRect(_rr(castle.dx + dx - w / 2, castle.dy + 90 - h, w, h, 10), _fill(const Color(0xFFE9C98F)));
    for (var i = 0; i < 3; i++) {
      c.drawRect(Rect.fromLTWH(castle.dx + dx - w / 2 + i * w / 2.6, castle.dy + 72 - h, w / 5, 20), _fill(const Color(0xFFE9C98F)));
    }
  }
  c.drawLine(castle + const Offset(0, -120), castle + const Offset(0, -200), _stroke(_wood, 6));
  c.drawPath(
      Path()
        ..moveTo(castle.dx, castle.dy - 200)
        ..lineTo(castle.dx + 60, castle.dy - 180)
        ..lineTo(castle.dx, castle.dy - 160)
        ..close(),
      _fill(_coral));
}

void _duck(Canvas c, Size s) {
  _gradient(c, Offset.zero & s, const [Color(0xFFD7EEF5), Color(0xFFBFE3F5)]);
  // Tiles.
  for (var i = 1; i < 6; i++) {
    c.drawLine(Offset(i * s.width / 6, 0), Offset(i * s.width / 6, s.height * 0.5), _stroke(_white.withValues(alpha: 0.7), 6));
    if (i < 4) c.drawLine(Offset(0, i * s.height / 7), Offset(s.width, i * s.height / 7), _stroke(_white.withValues(alpha: 0.7), 6));
  }
  c.drawRect(Rect.fromLTWH(0, s.height * 0.56, s.width, s.height * 0.44), _fill(const Color(0xFF8CCBE3)));
  _hill(c, s, s.height * 0.56, const Color(0xFF8CCBE3), amp: 10, waves: 3);
  final random = math.Random(5);
  for (var i = 0; i < 26; i++) {
    final at = Offset(random.nextDouble() * s.width, s.height * (0.5 + random.nextDouble() * 0.14));
    final r = 30 + random.nextDouble() * 56;
    c.drawCircle(at, r, _fill(_white.withValues(alpha: 0.92)));
    c.drawCircle(at + Offset(-r * 0.3, -r * 0.3), r * 0.18, _fill(_skyBlue.withValues(alpha: 0.8)));
  }
  final duck = Offset(s.width * 0.5, s.height * 0.62);
  c.drawOval(Rect.fromCenter(center: duck + const Offset(0, 120), width: 520, height: 70), _fill(const Color(0xFF79BAD4)));
  c.drawOval(Rect.fromCenter(center: duck + const Offset(10, 40), width: 430, height: 250), _fill(_gold));
  c.drawPath(
      Path()
        ..moveTo(duck.dx + 150, duck.dy - 10)
        ..quadraticBezierTo(duck.dx + 290, duck.dy - 80, duck.dx + 250, duck.dy + 40)
        ..close(),
      _fill(_gold));
  c.drawCircle(duck + const Offset(-110, -130), 130, _fill(_gold));
  c.drawOval(Rect.fromCenter(center: duck + const Offset(40, 50), width: 190, height: 110), _fill(const Color(0xFFEFB830)));
  c.drawRRect(_rr(duck.dx - 310, duck.dy - 140, 110, 50, 25), _fill(_coral));
  c.drawCircle(duck + const Offset(-150, -160), 18, _fill(_navy));
  c.drawCircle(duck + const Offset(-156, -166), 6, _fill(_white));
  for (var i = 0; i < 9; i++) {
    final at = Offset(random.nextDouble() * s.width, s.height * (0.74 + random.nextDouble() * 0.22));
    c.drawCircle(at, 22 + random.nextDouble() * 30, _fill(_white.withValues(alpha: 0.85)));
  }
}

void _kite(Canvas c, Size s) {
  _gradient(c, Offset.zero & s, const [Color(0xFF9FD3F0), Color(0xFFE6F5FB)]);
  _cloud(c, Offset(s.width * 0.22, s.height * 0.2), 1.2);
  _cloud(c, Offset(s.width * 0.8, s.height * 0.42), 0.9);
  _hill(c, s, s.height * 0.78, const Color(0xFFA8D8A0), amp: 40);
  _hill(c, s, s.height * 0.86, _leaf, amp: 26, phase: 2.6);
  final kite = Offset(s.width * 0.6, s.height * 0.24);
  // String with bows.
  final line = Path()
    ..moveTo(kite.dx, kite.dy + 150)
    ..cubicTo(kite.dx - 60, kite.dy + 380, kite.dx - 320, kite.dy + 420, s.width * 0.18, s.height * 0.86);
  c.drawPath(line, _stroke(_navy.withValues(alpha: 0.55), 4));
  final metric = line.computeMetrics().first;
  for (var i = 1; i < 5; i++) {
    final at = metric.getTangentForOffset(metric.length * i / 9)!.position;
    c.drawPath(
        Path()
          ..moveTo(at.dx, at.dy)
          ..lineTo(at.dx - 30, at.dy - 18)
          ..lineTo(at.dx - 30, at.dy + 18)
          ..close()
          ..moveTo(at.dx, at.dy)
          ..lineTo(at.dx + 30, at.dy - 18)
          ..lineTo(at.dx + 30, at.dy + 18)
          ..close(),
        _fill([_coral, _gold, _lavender, _pink][i % 4]));
  }
  c.save();
  c.translate(kite.dx, kite.dy);
  c.rotate(0.28);
  for (final (path, color) in [
    (Path()..moveTo(0, -190)..lineTo(-130, -20)..lineTo(0, -20)..close(), _coral),
    (Path()..moveTo(0, -190)..lineTo(130, -20)..lineTo(0, -20)..close(), _gold),
    (Path()..moveTo(-130, -20)..lineTo(0, 170)..lineTo(0, -20)..close(), _gold),
    (Path()..moveTo(130, -20)..lineTo(0, 170)..lineTo(0, -20)..close(), const Color(0xFFE5745A)),
  ]) {
    c.drawPath(path, _fill(color));
  }
  c.restore();
}

void _blocks(Canvas c, Size s) {
  _gradient(c, Offset.zero & s, const [Color(0xFFEDE7FA), Color(0xFFF9E8EE)]);
  c.drawRect(Rect.fromLTWH(0, s.height * 0.8, s.width, s.height * 0.2), _fill(_cream));
  final colors = [_coral, _gold, _mint, _lavender, const Color(0xFF8CCBE3)];
  final letters = ['A', 'B', 'C', 'D', 'E'];
  var top = s.height * 0.8;
  for (var i = 0; i < 5; i++) {
    final size = 170.0 - i * 6, left = s.width * 0.5 - size / 2 + [0.0, 18.0, -14.0, 10.0, -6.0][i];
    top -= size;
    if (i == 0) _shadow(c, Offset(s.width / 2, s.height * 0.805), 300);
    c.drawRRect(_rr(left, top, size, size, 18), _fill(colors[i]));
    c.drawRRect(_rr(left + 16, top + 16, size - 32, size - 32, 12), _stroke(_white.withValues(alpha: 0.7), 6));
    final painter = TextPainter(
        text: TextSpan(text: letters[i], style: TextStyle(fontSize: size * 0.52, fontWeight: FontWeight.w900, color: _white)),
        textDirection: TextDirection.ltr)
      ..layout();
    painter.paint(c, Offset(left + (size - painter.width) / 2, top + (size - painter.height) / 2));
  }
  // Loose blocks and a ball.
  for (final (x, color, angle) in [(0.16, _mint, -0.2), (0.82, _coral, 0.3)]) {
    c.save();
    c.translate(s.width * x, s.height * 0.76);
    c.rotate(angle);
    c.drawRRect(_rr(-60, -60, 120, 120, 14), _fill(color));
    c.restore();
  }
  c.drawCircle(Offset(s.width * 0.3, s.height * 0.77), 46, _fill(_gold));
  c.drawArc(Rect.fromCircle(center: Offset(s.width * 0.3, s.height * 0.77), radius: 46), 0.4, 2.2, false, _stroke(_white, 8));
}

void _slide(Canvas c, Size s) {
  _gradient(c, Offset.zero & s, const [Color(0xFFAEDCF4), Color(0xFFE9F6EC)]);
  _sun(c, Offset(s.width * 0.18, s.height * 0.14), 70);
  _cloud(c, Offset(s.width * 0.68, s.height * 0.16), 1.2);
  _hill(c, s, s.height * 0.7, const Color(0xFFA8D8A0), amp: 30);
  _hill(c, s, s.height * 0.8, _leaf, amp: 20, phase: 1.8);
  final top = Offset(s.width * 0.3, s.height * 0.4), ground = s.height * 0.86;
  // Ladder and platform.
  c.drawLine(Offset(top.dx - 90, ground), Offset(top.dx - 40, top.dy), _stroke(_navy, 14));
  c.drawLine(Offset(top.dx - 10, ground), Offset(top.dx + 40, top.dy), _stroke(_navy, 14));
  for (var i = 1; i < 6; i++) {
    final y = ground - i * (ground - top.dy) / 6, shift = i * 50 / 6;
    c.drawLine(Offset(top.dx - 90 + shift, y), Offset(top.dx - 10 + shift, y), _stroke(_navy, 10));
  }
  c.drawRRect(_rr(top.dx - 60, top.dy - 20, 190, 30, 12), _fill(_gold));
  c.drawArc(Rect.fromLTWH(top.dx - 50, top.dy - 150, 170, 260), math.pi, math.pi, false, _stroke(_coral, 16));
  // Chute.
  final chute = Path()
    ..moveTo(top.dx + 120, top.dy - 10)
    ..cubicTo(s.width * 0.6, top.dy + 40, s.width * 0.62, ground - 60, s.width * 0.88, ground - 30);
  c.drawPath(chute, _stroke(const Color(0xFFE5745A), 70));
  c.drawPath(chute, _stroke(_coral, 46));
  _shadow(c, Offset(s.width * 0.6, ground + 12), 560, alpha: 0.1);
  // Flowers.
  for (final (x, color) in [(0.1, _pink), (0.52, _white), (0.9, _gold), (0.72, _pink)]) {
    final at = Offset(s.width * x, s.height * 0.93);
    c.drawLine(at, at + const Offset(0, 50), _stroke(const Color(0xFF4F9B66), 6));
    for (var i = 0; i < 5; i++) {
      c.drawCircle(at + Offset(math.cos(i * 1.257) * 20, math.sin(i * 1.257) * 20), 14, _fill(color));
    }
    c.drawCircle(at, 10, _fill(_gold));
  }
}

void _balloon(Canvas c, Size s) {
  _gradient(c, Offset.zero & s, const [Color(0xFF8CC8EE), Color(0xFFDFF1FA)]);
  _cloud(c, Offset(s.width * 0.2, s.height * 0.62), 1.3);
  _cloud(c, Offset(s.width * 0.82, s.height * 0.3), 1.0);
  _cloud(c, Offset(s.width * 0.6, s.height * 0.86), 1.5);
  final at = Offset(s.width * 0.48, s.height * 0.36);
  c.drawPath(
      Path()
        ..moveTo(at.dx, at.dy + 210)
        ..cubicTo(at.dx + 50, at.dy + 380, at.dx - 70, at.dy + 520, at.dx + 10, at.dy + 720),
      _stroke(_navy.withValues(alpha: 0.5), 4));
  c.drawOval(Rect.fromCenter(center: at, width: 340, height: 410), _fill(const Color(0xFFE5574F)));
  c.drawOval(Rect.fromCenter(center: at + const Offset(26, 16), width: 290, height: 370), _fill(_coral.withValues(alpha: 0.45)));
  c.drawOval(Rect.fromCenter(center: at + const Offset(-76, -96), width: 70, height: 110), _fill(_white.withValues(alpha: 0.55)));
  c.drawPath(
      Path()
        ..moveTo(at.dx, at.dy + 200)
        ..lineTo(at.dx - 24, at.dy + 232)
        ..lineTo(at.dx + 24, at.dy + 232)
        ..close(),
      _fill(const Color(0xFFE5574F)));
}

void _boots(Canvas c, Size s) {
  _gradient(c, Offset.zero & s, const [Color(0xFFB7C7D8), Color(0xFFD9E3EA)]);
  final random = math.Random(9);
  for (var i = 0; i < 60; i++) {
    final at = Offset(random.nextDouble() * s.width, random.nextDouble() * s.height * 0.7);
    c.drawLine(at, at + const Offset(-10, 46), _stroke(_white.withValues(alpha: 0.7), 5));
  }
  c.drawRect(Rect.fromLTWH(0, s.height * 0.72, s.width, s.height * 0.28), _fill(const Color(0xFF9DB0C2)));
  // Puddle with ripples.
  final puddle = Offset(s.width / 2, s.height * 0.86);
  c.drawOval(Rect.fromCenter(center: puddle, width: s.width * 0.9, height: 240), _fill(const Color(0xFF7FA3BF)));
  for (var i = 1; i < 4; i++) {
    c.drawOval(Rect.fromCenter(center: puddle, width: s.width * 0.26 * i, height: 64.0 * i), _stroke(_white.withValues(alpha: 0.5), 5));
  }
  for (final sign in [-1.0, 1.0]) {
    final at = Offset(s.width / 2 + sign * 120, s.height * 0.62);
    c.drawRRect(_rr(at.dx - 78, at.dy - 250, 156, 400, 44), _fill(_gold));
    c.drawRRect(_rr(at.dx - 84 + (sign > 0 ? 0 : -70), at.dy + 60, 238, 110, 52), _fill(_gold));
    c.drawRRect(_rr(at.dx - 90 + (sign > 0 ? 0 : -70), at.dy + 146, 250, 30, 15), _fill(const Color(0xFFD9A520)));
    c.drawRRect(_rr(at.dx - 86, at.dy - 262, 172, 54, 22), _fill(const Color(0xFFEFB830)));
    // Splash drops.
    for (var i = 0; i < 4; i++) {
      c.drawCircle(at + Offset(sign * (150 + i * 44), 110 - i * 46.0 + (i * i * 6)), 16 - i * 2.0, _fill(_white.withValues(alpha: 0.85)));
    }
  }
}

void _porridge(Canvas c, Size s) {
  _gradient(c, Offset.zero & s, const [Color(0xFFFFF3DF), Color(0xFFFCE3C4)]);
  // Table cloth dots.
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 11; x++) {
      c.drawCircle(Offset(60 + x * 110.0 + (y.isEven ? 0 : 55), 60 + y * 110.0), 12, _fill(_white.withValues(alpha: 0.7)));
    }
  }
  final bowl = Offset(s.width * 0.46, s.height * 0.52);
  _shadow(c, bowl + const Offset(20, 250), 760, alpha: 0.12);
  c.drawOval(Rect.fromCenter(center: bowl, width: 640, height: 500), _fill(_mint));
  c.drawOval(Rect.fromCenter(center: bowl + const Offset(0, -16), width: 560, height: 420), _fill(_white));
  c.drawOval(Rect.fromCenter(center: bowl + const Offset(0, -10), width: 500, height: 360), _fill(const Color(0xFFFFE9B8)));
  // Toppings and steam.
  for (final (dx, dy, color, r) in [
    (-90.0, -40.0, _coral, 34.0),
    (40.0, 50.0, _coral, 28.0),
    (110.0, -60.0, const Color(0xFF8E5BA8), 22.0),
    (-20.0, 90.0, const Color(0xFF8E5BA8), 20.0),
    (-150.0, 60.0, _leaf, 18.0),
  ]) {
    c.drawCircle(bowl + Offset(dx, dy), r, _fill(color));
  }
  for (var i = 0; i < 3; i++) {
    final x = bowl.dx - 120 + i * 120;
    c.drawPath(
        Path()
          ..moveTo(x, bowl.dy - 250)
          ..cubicTo(x - 40, bowl.dy - 310, x + 40, bowl.dy - 350, x, bowl.dy - 410),
        _stroke(_white.withValues(alpha: 0.9), 12));
  }
  // Spoon.
  c.save();
  c.translate(s.width * 0.84, s.height * 0.56);
  c.rotate(0.5);
  c.drawRRect(_rr(-16, -60, 32, 330, 16), _fill(_coral));
  c.drawOval(Rect.fromCenter(center: const Offset(0, -120), width: 110, height: 160), _fill(_coral));
  c.drawOval(Rect.fromCenter(center: const Offset(0, -120), width: 76, height: 120), _fill(const Color(0xFFE5745A)));
  c.restore();
}
