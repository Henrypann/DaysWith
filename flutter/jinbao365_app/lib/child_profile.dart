import 'package:jinbao_core/jinbao_core.dart';

/// DaysWith 4.0: the child this archive is about. Kept in this phone's preferences only;
/// it is never written to the archive or uploaded.
class ChildProfile {
  final String nickname;
  final DateParts birthday;
  const ChildProfile({required this.nickname, required this.birthday});

  static const maxNicknameLength = 12;

  /// `yyyy-mm-dd`, the same shape anniversaries use.
  String get storedBirthday =>
      '${birthday.year.toString().padLeft(4, '0')}-${birthday.month.toString().padLeft(2, '0')}-${birthday.day.toString().padLeft(2, '0')}';

  static DateParts? parseDate(String? stored) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(stored ?? '');
    if (match == null) return null;
    final year = int.parse(match[1]!), month = int.parse(match[2]!), day = int.parse(match[3]!);
    if (year < 1900 || month < 1 || month > 12 || day < 1 || day > JinbaoCalendar.daysInMonth(year, month)) return null;
    return DateParts(year, month, day);
  }

  static ChildProfile? decode({required String? nickname, required String? birthday}) {
    final date = parseDate(birthday);
    final name = swiftTrim(nickname ?? '');
    if (date == null || name.isEmpty) return null;
    return ChildProfile(nickname: name, birthday: date);
  }

  /// Full age on [date], or null before the birthday.
  String? ageOn(DateParts date) {
    final age = JinbaoCalendar.age(date, birthday: birthday);
    return age == null ? null : formatAge(age);
  }

  /// Short age for cards: years and months, or months and days in the first year.
  String? shortAgeOn(DateParts date) {
    final age = JinbaoCalendar.age(date, birthday: birthday);
    return age == null ? null : formatAge(age, short: true);
  }

  /// The birthday is day 1.
  int? dayNumberOn(DateParts date) {
    final days = JinbaoCalendar.julian(date) - JinbaoCalendar.julian(birthday);
    return days < 0 ? null : days + 1;
  }

  String? ageAt(int millis, [ZoneRules zone = const DeviceZone()]) =>
      millis <= 0 ? null : ageOn(JinbaoCalendar.parts(millis, zone));

  String? shortAgeAt(int millis, [ZoneRules zone = const DeviceZone()]) =>
      millis <= 0 ? null : shortAgeOn(JinbaoCalendar.parts(millis, zone));
}

String formatAge(({int years, int months, int days}) age, {bool short = false}) {
  if (age.years == 0 && age.months == 0) return age.days == 0 ? '出生当天' : '${age.days}天';
  if (age.years == 0) return age.days == 0 ? '${age.months}个月' : '${age.months}个月${age.days}天';
  final months = age.months == 0 ? '' : '${age.months}个月';
  if (short) return '${age.years}岁$months';
  final days = age.days == 0 ? '' : '${age.days}天';
  return '${age.years}岁$months$days';
}
