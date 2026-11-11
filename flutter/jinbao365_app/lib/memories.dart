import 'package:jinbao_core/jinbao_core.dart';

/// DaysWith 4.0 「那年今天」: earlier records that fall on today's day of the month,
/// a whole number of years ago, or 1, 3 or 6 months ago for the first year.
class Memory {
  final TimelineEntry entry;
  final int monthsAgo;
  const Memory({required this.entry, required this.monthsAgo});

  String get label {
    if (monthsAgo % 12 == 0) return '${monthsAgo ~/ 12}年前的今天';
    if (monthsAgo == 6) return '半年前的今天';
    return '$monthsAgo个月前的今天';
  }
}

abstract final class Memories {
  static const _shortSpans = {1, 3, 6};

  static List<Memory> onThisDay(List<TimelineEntry> entries, DateParts today, {ZoneRules zone = const DeviceZone()}) {
    final lastDayToday = today.day == JinbaoCalendar.daysInMonth(today.year, today.month);
    final result = <Memory>[];
    for (final entry in entries) {
      if (entry.occurredAt <= 0) continue;
      final date = JinbaoCalendar.parts(entry.occurredAt, zone);
      final months = (today.year - date.year) * 12 + (today.month - date.month);
      if (months < 1 || !(months % 12 == 0 || _shortSpans.contains(months))) continue;
      // The 31st is remembered on the last day of a shorter month.
      final sameDay = date.day == today.day || (lastDayToday && date.day > today.day);
      if (sameDay) result.add(Memory(entry: entry, monthsAgo: months));
    }
    result.sort((a, b) {
      if (a.monthsAgo != b.monthsAgo) return b.monthsAgo.compareTo(a.monthsAgo);
      if (a.entry.occurredAt != b.entry.occurredAt) return a.entry.occurredAt.compareTo(b.entry.occurredAt);
      return a.entry.id.compareTo(b.entry.id);
    });
    return result;
  }
}
