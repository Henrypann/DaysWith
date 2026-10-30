import 'package:collection/collection.dart';

import 'app_session.dart';
import 'errors.dart';
import 'json_codec.dart';
import 'text.dart';
import 'time_zone.dart';
import 'timeline.dart';
import 'v1_layout.dart';

const _deep = DeepCollectionEquality();

class LocalAnniversary {
  String id;
  ParentIdentity owner;
  String title;
  String date;
  int? deletedAt;
  int updatedAt;
  final UploadEligibility uploadEligibility;

  LocalAnniversary({
    String? id,
    required this.owner,
    required this.title,
    required this.date,
    this.deletedAt,
    required this.updatedAt,
    this.uploadEligibility = UploadEligibility.localOnly,
  }) : id = id ?? newUuid();

  factory LocalAnniversary.fromJson(Object? json) {
    final v = JsonFields(json, 'anniversary');
    return LocalAnniversary(
      id: v.string('id'),
      owner: v.parent('owner'),
      title: v.string('title'),
      date: AnniversaryCalendar.normalizedDate(v.string('date')),
      deletedAt: v.optionalInt('deletedAt'),
      updatedAt: v.optionalInt('updatedAt') ?? 0,
      uploadEligibility: UploadEligibility.decode(v.raw('uploadEligibility')),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'owner': owner.folder,
        'title': title,
        'date': date,
        if (deletedAt != null) 'deletedAt': deletedAt,
        'updatedAt': updatedAt,
        'uploadEligibility': uploadEligibility.rawValue,
      };

  @override
  bool operator ==(Object other) => other is LocalAnniversary && _deep.equals(toJson(), other.toJson());

  @override
  int get hashCode => _deep.hash(toJson());
}

class RemoteAnniversary {
  final String recordID;
  final ParentIdentity owner;
  final String title;
  final String date;
  final int? deletedAt;
  final String sourcePrefix;
  final int updatedAt;

  const RemoteAnniversary({
    required this.recordID,
    required this.owner,
    required this.title,
    required this.date,
    this.deletedAt,
    required this.sourcePrefix,
    required this.updatedAt,
  });

  String get id => 'remote:${owner.folder}:anniversary:${recordID.toUpperCase()}';

  factory RemoteAnniversary.fromJson(Object? json) {
    final v = JsonFields(json, 'remoteAnniversary');
    return RemoteAnniversary(
      recordID: v.string('recordID'),
      owner: v.parent('owner'),
      title: v.string('title'),
      date: v.string('date'),
      deletedAt: v.optionalInt('deletedAt'),
      sourcePrefix: v.string('sourcePrefix'),
      updatedAt: v.integer('updatedAt'),
    );
  }

  Map<String, Object?> toJson() => {
        'recordID': recordID,
        'owner': owner.folder,
        'title': title,
        'date': date,
        if (deletedAt != null) 'deletedAt': deletedAt,
        'sourcePrefix': sourcePrefix,
        'updatedAt': updatedAt,
      };

  @override
  bool operator ==(Object other) => other is RemoteAnniversary && _deep.equals(toJson(), other.toJson());

  @override
  int get hashCode => _deep.hash(toJson());
}

class AnniversaryEntry {
  final String id;
  final String title;
  final String date;
  final ParentIdentity owner;
  final bool readOnly;
  final bool isDefault;

  const AnniversaryEntry({
    required this.id,
    required this.title,
    required this.date,
    required this.owner,
    required this.readOnly,
    this.isDefault = false,
  });

  bool get yearKnown => !date.startsWith('0004-');

  @override
  bool operator ==(Object other) =>
      other is AnniversaryEntry &&
      other.id == id &&
      other.title == title &&
      other.date == date &&
      other.owner == owner &&
      other.readOnly == readOnly &&
      other.isDefault == isDefault;

  @override
  int get hashCode => Object.hash(id, title, date, owner, readOnly, isDefault);
}

class UpcomingAnniversary {
  final AnniversaryEntry entry;
  final int daysUntil;
  final int? years;
  final DateParts nextDate;

  const UpcomingAnniversary({required this.entry, required this.daysUntil, required this.years, required this.nextDate});

  String get id => entry.id;
  bool get shouldRemind => const [0, 1, 2, 3, 7].contains(daysUntil);
}

class BuiltinAnniversary {
  final String id;
  final String title;
  final String date;
  const BuiltinAnniversary(this.id, this.title, this.date);
}

abstract final class AnniversaryCalendar {
  static const defaults = [
    BuiltinAnniversary('00000000-0000-4000-8000-000000000101', '儿童节', '0004-06-01'),
    BuiltinAnniversary('00000000-0000-4000-8000-000000000102', '国庆节', '0004-10-01'),
    BuiltinAnniversary('00000000-0000-4000-8000-000000000103', '元旦', '0004-01-01'),
  ];

  static bool isDefault(String id) => defaults.any((item) => caseInsensitiveEquals(item.id, id));

  static final _datePattern = RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$');

  /// `--MM-DD` (year unknown) is stored as `0004-MM-DD`. Dates use the proleptic Gregorian
  /// calendar, like Android's LocalDate.
  static String normalizedDate(String value) {
    final date = value.startsWith('--') ? '0004-${value.substring(2)}' : value;
    const error = ContractError('anniversary.date', '请选择有效的纪念日日期。');
    if (!_datePattern.hasMatch(date)) throw error;
    final parts = date.split('-').map(int.parse).toList();
    final (year, month, day) = (parts[0], parts[1], parts[2]);
    if (year < 1 || month < 1 || month > 12 || day < 1 || day > JinbaoCalendar.daysInMonth(year, month)) {
      throw error;
    }
    return date;
  }

  static List<UpcomingAnniversary> upcoming(List<AnniversaryEntry> entries, {required int now, required ZoneRules zone}) {
    final today = JinbaoCalendar.parts(now, zone);
    final result = <UpcomingAnniversary>[];
    for (final entry in entries) {
      final String valid;
      try {
        valid = normalizedDate(entry.date);
      } on ContractError {
        continue;
      }
      final parts = valid.split('-').map(int.parse).toList();
      // Android LocalDate.withYear clamps a leap-day anniversary to Feb 28 in non-leap years.
      DateParts dateIn(int year) {
        final last = JinbaoCalendar.daysInMonth(year, parts[1]);
        return DateParts(year, parts[1], parts[2] < last ? parts[2] : last);
      }

      final firstYear = entry.yearKnown ? (today.year > parts[0] ? today.year : parts[0]) : today.year;
      var next = dateIn(firstYear);
      if (JinbaoCalendar.compare(next, today) < 0) next = dateIn(firstYear + 1);
      final days = JinbaoCalendar.julian(next) - JinbaoCalendar.julian(today);
      final years = entry.yearKnown ? next.year - parts[0] : null;
      result.add(UpcomingAnniversary(entry: entry, daysUntil: days, years: years, nextDate: next));
    }
    result.sort((a, b) => a.daysUntil == b.daysUntil ? a.id.compareTo(b.id) : a.daysUntil.compareTo(b.daysUntil));
    return result;
  }
}
