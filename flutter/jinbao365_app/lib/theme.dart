import 'package:flutter/material.dart';
import 'package:jinbao_core/jinbao_core.dart';

/// Same palette and components as ios-app/Jinbao365/Theme.swift, so both platforms look alike.
abstract final class JinbaoColors {
  static const background = Color(0xFFF4F4F2);
  static const surface = Colors.white;
  static const ink = Color(0xFF0F2747);
  static const inkSecondary = Color(0xFF6E6E73);
  static const separator = Color(0xFFE5E5EA);
  static const gold = Color(0xFFF7C948);
  static const goldSoft = Color(0xFFFEF4D6);
  static const navy = Color(0xFF0F2747);
  static const onNavy = Color(0xFFFDF6E9);
  static const outline = Color(0xFF8C8C91);
  static const photoPlaceholder = Color(0xFFECECEA);
  static const noteInk = Color(0xFF3A4A5E);
  static const dadBackground = Color(0xFFDEEDF8);
  static const dadInk = Color(0xFF2F5A75);
  static const momBackground = Color(0xFFF9E1E8);
  static const momInk = Color(0xFF86495D);
  static const problem = Color(0xFFA33333);
  static const problemSoft = Color(0xFFF8E8E8);

  static Color parentBackground(ParentIdentity parent) => parent == ParentIdentity.dad ? dadBackground : momBackground;
  static Color parentInk(ParentIdentity parent) => parent == ParentIdentity.dad ? dadInk : momInk;
}

ThemeData jinbaoTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: JinbaoColors.gold,
      primary: JinbaoColors.ink,
      onPrimary: Colors.white,
      secondary: JinbaoColors.gold,
      surface: JinbaoColors.surface,
      error: JinbaoColors.problem,
    ),
    scaffoldBackgroundColor: JinbaoColors.background,
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: JinbaoColors.background,
      foregroundColor: JinbaoColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: JinbaoColors.ink),
    ),
    textTheme: base.textTheme.apply(bodyColor: JinbaoColors.ink, displayColor: JinbaoColors.ink),
    dividerTheme: const DividerThemeData(color: JinbaoColors.separator, space: 1, thickness: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: JinbaoColors.surface,
      contentPadding: const EdgeInsets.all(14),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: JinbaoColors.separator)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: JinbaoColors.separator)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: JinbaoColors.ink)),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: JinbaoColors.ink)),
  );
}

String ageLabel(DateTime now) {
  final parts = JinbaoCalendar.parts(now.millisecondsSinceEpoch, const DeviceZone());
  final age = JinbaoCalendar.age(parts);
  if (age == null) return '留住一起度过的日子';
  return '${age.years}岁${age.months}个月${age.days}天';
}

String twoDigits(int value) => value.toString().padLeft(2, '0');

String clockText(int millis) {
  final date = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${twoDigits(date.hour)}:${twoDigits(date.minute)}';
}

class BrandMark extends StatelessWidget {
  final double size;
  const BrandMark({super.key, this.size = 36});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(size * 2 / 9),
        child: Container(
          color: JinbaoColors.navy,
          width: size,
          height: size,
          child: Image.asset('assets/brand_mark.png', fit: BoxFit.contain),
        ),
      );
}

class BrandWordmark extends StatelessWidget {
  const BrandWordmark({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'DaysWith · 记录成长，收藏美好',
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 230),
          child: const Text('DaysWith', style: TextStyle(fontSize: 36, fontWeight: FontWeight.w700)),
        ),
      );
}

class ParentBadge extends StatelessWidget {
  final ParentIdentity parent;
  const ParentBadge(this.parent, {super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: JinbaoColors.parentBackground(parent), borderRadius: BorderRadius.circular(999)),
        child: Text(parent.label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: JinbaoColors.parentInk(parent))),
      );
}

class BrandCard extends StatelessWidget {
  final Widget child;
  final double padding;
  final Color color;
  const BrandCard({super.key, required this.child, this.padding = 16, this.color = JinbaoColors.surface});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(padding),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
        child: child,
      );
}

class GoldButton extends StatelessWidget {
  final String title;
  final bool enabled;
  final VoidCallback? onPressed;
  const GoldButton({super.key, required this.title, this.enabled = true, required this.onPressed});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: enabled ? onPressed : null,
          style: FilledButton.styleFrom(
            backgroundColor: JinbaoColors.gold,
            foregroundColor: JinbaoColors.ink,
            disabledBackgroundColor: JinbaoColors.separator,
            disabledForegroundColor: JinbaoColors.inkSecondary,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          child: Text(title),
        ),
      );
}

class FeatureRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback? onTap;
  const FeatureRow({super.key, required this.title, this.subtitle, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              SizedBox(width: 28, child: Icon(icon, color: JinbaoColors.ink)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(subtitle!, style: const TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
                  ],
                ]),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, size: 18, color: JinbaoColors.inkSecondary),
            ]),
          ),
        ),
      );
}

class FeatureEmptyState extends StatelessWidget {
  final String title;
  final String detail;
  final IconData icon;
  const FeatureEmptyState({super.key, required this.title, required this.detail, required this.icon});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(32),
        child: Column(children: [
          Icon(icon, size: 42, color: JinbaoColors.inkSecondary),
          const SizedBox(height: 14),
          Text(title,
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 14),
          Text(detail, textAlign: TextAlign.center, style: const TextStyle(color: JinbaoColors.inkSecondary)),
        ]),
      );
}

class StatusBanner extends StatelessWidget {
  final String text;
  final bool isError;
  const StatusBanner({super.key, required this.text, required this.isError});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: isError ? JinbaoColors.problemSoft : JinbaoColors.goldSoft,
        child: Text(text, style: TextStyle(fontSize: 14, color: isError ? JinbaoColors.problem : JinbaoColors.ink)),
      );
}

Future<bool> confirmAction(BuildContext context,
    {required String title, required String message, required String confirm, bool destructive = false}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          style: TextButton.styleFrom(foregroundColor: destructive ? JinbaoColors.problem : JinbaoColors.ink),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return result ?? false;
}
