import 'package:collection/collection.dart';

import 'app_session.dart';
import 'archive_merge.dart';
import 'text.dart';
import 'time_zone.dart';
import 'v1_layout.dart';

const _deep = DeepCollectionEquality();

class DateParts {
  final int year;
  final int month;
  final int day;
  const DateParts(this.year, this.month, this.day);

  @override
  bool operator ==(Object other) => other is DateParts && other.year == year && other.month == month && other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => '$year-$month-$day';
}

class TimelineDay {
  final DateParts date;
  final String title;
  final List<TimelineEntry> moments;
  const TimelineDay({required this.date, required this.title, required this.moments});
  String get id => '${date.year}-${date.month}-${date.day}';
}

class TimelineMonth {
  final int year;
  final int month;
  final List<TimelineDay> days;
  const TimelineMonth({required this.year, required this.month, required this.days});
  String get id => '$year-$month';

  /// Always four-digit year, including months in the current year.
  String get title => titleFor(year: year, month: month);
  static String titleFor({required int year, required int month}) => '$year年$month月';
}

class TimelinePhoto {
  final String id;
  final String? localPath;
  final String? fullSizePath;
  final RemotePreview? remote;
  final String kind;
  final List<LocalResource> localResources;
  final List<RemoteResource> remoteResources;

  const TimelinePhoto({
    required this.id,
    this.localPath,
    this.fullSizePath,
    this.remote,
    this.kind = 'photo',
    this.localResources = const [],
    this.remoteResources = const [],
  });

  List<Object?> get _props => [id, localPath, fullSizePath, remote, kind, localResources, remoteResources];

  @override
  bool operator ==(Object other) => other is TimelinePhoto && _deep.equals(_props, other._props);

  @override
  int get hashCode => _deep.hash(_props);
}

class TimelineEntry {
  final String id;
  final String title;
  final String note;
  final int occurredAt;
  final ParentIdentity parent;
  final bool readOnly;
  final int mediaCount;
  final String? previewPath;
  final String? provenanceLabel;
  final List<TimelinePhoto> photos;

  const TimelineEntry({
    required this.id,
    required this.title,
    required this.note,
    required this.occurredAt,
    required this.parent,
    required this.readOnly,
    required this.mediaCount,
    required this.previewPath,
    required this.provenanceLabel,
    this.photos = const [],
  });

  String get displayTitle {
    final trimmed = swiftTrim(title);
    if (trimmed.isNotEmpty) return trimmed;
    final noteText = swiftTrim(note);
    if (noteText.isNotEmpty) return noteText;
    return '值得留住的小日常';
  }

  List<Object?> get _props =>
      [id, title, note, occurredAt, parent, readOnly, mediaCount, previewPath, provenanceLabel, photos];

  @override
  bool operator ==(Object other) => other is TimelineEntry && _deep.equals(_props, other._props);

  @override
  int get hashCode => _deep.hash(_props);
}

abstract final class TimelineEmptyCopy {
  static const title = '留住我们的第一个小日常';
  static const detail = '轻点下面的＋，存下照片或写一段话';
}

abstract final class JinbaoCalendar {

  static DateParts parts(int millis, ZoneRules zone) {
    final wall = zone.wallClock(millis);
    return DateParts(wall.year, wall.month, wall.day);
  }

  static ({int years, int months, int days})? age(DateParts date, {DateParts? birthday}) {
    if (birthday == null) return null;
    if (compare(date, birthday) < 0) return null;
    final months = _wholeMonths(birthday, date);
    final anchor = _addingMonths(months, birthday);
    final days = julian(date) - julian(anchor);
    return (years: months ~/ 12, months: months % 12, days: days);
  }

  static String dayTitle(DateParts date) {
    return '${date.month}月${date.day}日';
  }

  static List<TimelineMonth> months(List<TimelineEntry> entries, ZoneRules zone) {
    final sorted = [...entries]..sort((a, b) {
        if (a.occurredAt != b.occurredAt) return b.occurredAt.compareTo(a.occurredAt);
        return a.id.compareTo(b.id);
      });
    final byMonth = <String, List<TimelineEntry>>{};
    final monthDate = <String, DateParts>{};
    for (final entry in sorted) {
      final date = parts(entry.occurredAt, zone);
      final key = '${date.year}-${date.month}';
      monthDate.putIfAbsent(key, () => date);
      byMonth.putIfAbsent(key, () => []).add(entry);
    }
    final result = byMonth.entries.map((bucket) {
      final date = monthDate[bucket.key]!;
      final grouped = <DateParts, List<TimelineEntry>>{};
      for (final entry in bucket.value) {
        grouped.putIfAbsent(parts(entry.occurredAt, zone), () => []).add(entry);
      }
      final days = grouped.entries
          .map((day) => TimelineDay(date: day.key, title: dayTitle(day.key), moments: day.value))
          .toList()
        ..sort((a, b) => compare(b.date, a.date));
      return TimelineMonth(year: date.year, month: date.month, days: days);
    }).toList();
    result.sort((a, b) => a.year != b.year ? b.year.compareTo(a.year) : b.month.compareTo(a.month));
    return result;
  }

  static int compare(DateParts lhs, DateParts rhs) {
    if (lhs.year != rhs.year) return lhs.year < rhs.year ? -1 : 1;
    if (lhs.month != rhs.month) return lhs.month < rhs.month ? -1 : 1;
    if (lhs.day != rhs.day) return lhs.day < rhs.day ? -1 : 1;
    return 0;
  }

  static int _wholeMonths(DateParts start, DateParts end) {
    var months = (end.year - start.year) * 12 + (end.month - start.month);
    if (end.day < start.day) months -= 1;
    return months < 0 ? 0 : months;
  }

  static DateParts _addingMonths(int months, DateParts date) {
    final total = date.year * 12 + (date.month - 1) + months;
    final year = total ~/ 12;
    final month = total % 12 + 1;
    final last = daysInMonth(year, month);
    return DateParts(year, month, date.day < last ? date.day : last);
  }

  static int daysInMonth(int year, int month) => switch (month) {
        1 || 3 || 5 || 7 || 8 || 10 || 12 => 31,
        4 || 6 || 9 || 11 => 30,
        2 => isLeap(year) ? 29 : 28,
        _ => 30,
      };

  static bool isLeap(int year) => (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;

  /// Julian day number (proleptic Gregorian). Differences give whole calendar days.
  static int julian(DateParts date) {
    final a = (14 - date.month) ~/ 12;
    final year = date.year - a;
    final month = date.month + 12 * a - 3;
    return date.day + (153 * month + 2) ~/ 5 + 365 * year + year ~/ 4 - year ~/ 100 + year ~/ 400 - 32045;
  }
}
