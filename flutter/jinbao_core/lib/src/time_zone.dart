/// Calendar time zone. Dart's DateTime only knows UTC and the device zone, so the core
/// takes this instead of Swift's `TimeZone`.
abstract class ZoneRules {
  const ZoneRules();

  /// Offset from UTC in effect at [utcMillis].
  Duration offsetAt(int utcMillis);

  /// UTC instant for a wall-clock time, or null when that wall-clock time does not exist
  /// (for example inside a daylight-saving gap).
  int? utcMillisForLocal(int year, int month, int day, int hour, int minute, int second);

  /// Wall-clock fields at [utcMillis] (fields are read from a UTC DateTime).
  DateTime wallClock(int utcMillis) =>
      DateTime.fromMillisecondsSinceEpoch(utcMillis + offsetAt(utcMillis).inMilliseconds, isUtc: true);
}

class FixedOffsetZone extends ZoneRules {
  final int offsetMinutes;
  const FixedOffsetZone(this.offsetMinutes);
  static const utc = FixedOffsetZone(0);

  @override
  Duration offsetAt(int utcMillis) => Duration(minutes: offsetMinutes);

  @override
  int? utcMillisForLocal(int year, int month, int day, int hour, int minute, int second) {
    final wall = DateTime.utc(year, month, day, hour, minute, second);
    if (wall.year != year || wall.month != month || wall.day != day || wall.hour != hour || wall.minute != minute ||
        wall.second != second) {
      return null;
    }
    return wall.millisecondsSinceEpoch - offsetMinutes * 60000;
  }
}

/// The device's current time zone.
class DeviceZone extends ZoneRules {
  const DeviceZone();

  @override
  Duration offsetAt(int utcMillis) => DateTime.fromMillisecondsSinceEpoch(utcMillis).timeZoneOffset;

  @override
  int? utcMillisForLocal(int year, int month, int day, int hour, int minute, int second) {
    final local = DateTime(year, month, day, hour, minute, second);
    if (local.year != year || local.month != month || local.day != day || local.hour != hour ||
        local.minute != minute || local.second != second) {
      return null;
    }
    return local.millisecondsSinceEpoch;
  }
}
