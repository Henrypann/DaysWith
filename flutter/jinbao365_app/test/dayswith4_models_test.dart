import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/child_profile.dart';
import 'package:jinbao365/memories.dart';
import 'package:jinbao_core/jinbao_core.dart';

const _utc = FixedOffsetZone.utc;

int _at(int year, int month, int day) => DateTime.utc(year, month, day, 12).millisecondsSinceEpoch;

TimelineEntry _entry(String id, int occurredAt) => TimelineEntry(
    id: id,
    title: id,
    note: '',
    occurredAt: occurredAt,
    parent: ParentIdentity.mom,
    readOnly: false,
    mediaCount: 0,
    previewPath: null,
    provenanceLabel: null);

void main() {
  group('child profile', () {
    const child = ChildProfile(nickname: '糯米', birthday: DateParts(2025, 3, 12));

    test('decodes only a real date and a non-empty nickname', () {
      expect(ChildProfile.decode(nickname: ' 糯米 ', birthday: '2025-03-12')?.nickname, '糯米');
      expect(ChildProfile.decode(nickname: '', birthday: '2025-03-12'), isNull);
      expect(ChildProfile.decode(nickname: '糯米', birthday: '2025-02-30'), isNull);
      expect(ChildProfile.decode(nickname: '糯米', birthday: '--03-12'), isNull);
      expect(ChildProfile.decode(nickname: '糯米', birthday: null), isNull);
      expect(child.storedBirthday, '2025-03-12');
    });

    test('age reads naturally at every stage', () {
      expect(child.ageOn(const DateParts(2025, 3, 11)), isNull);
      expect(child.ageOn(const DateParts(2025, 3, 12)), '出生当天');
      expect(child.ageOn(const DateParts(2025, 3, 30)), '18天');
      expect(child.ageOn(const DateParts(2025, 6, 12)), '3个月');
      expect(child.ageOn(const DateParts(2025, 6, 20)), '3个月8天');
      expect(child.ageOn(const DateParts(2026, 3, 12)), '1岁');
      expect(child.ageOn(const DateParts(2026, 11, 11)), '1岁7个月30天');
      expect(child.shortAgeOn(const DateParts(2026, 11, 11)), '1岁7个月');
      expect(child.shortAgeOn(const DateParts(2025, 6, 20)), '3个月8天');
    });

    test('the birthday is day one', () {
      expect(child.dayNumberOn(const DateParts(2025, 3, 12)), 1);
      expect(child.dayNumberOn(const DateParts(2025, 6, 19)), 100);
      expect(child.dayNumberOn(const DateParts(2025, 3, 1)), isNull);
    });

    test('unknown record dates have no age', () {
      expect(child.ageAt(0), isNull);
      expect(child.shortAgeAt(-1), isNull);
    });
  });

  group('on this day', () {
    const today = DateParts(2026, 11, 11);

    test('keeps whole years and the 1, 3 and 6 month marks', () {
      final memories = Memories.onThisDay([
        _entry('today', _at(2026, 11, 11)),
        _entry('one month', _at(2026, 10, 11)),
        _entry('two months', _at(2026, 9, 11)),
        _entry('half year', _at(2026, 5, 11)),
        _entry('one year', _at(2025, 11, 11)),
        _entry('two years', _at(2024, 11, 11)),
        _entry('other day', _at(2025, 11, 12)),
        _entry('unknown', 0),
      ], today, zone: _utc);
      expect(memories.map((m) => m.entry.id), ['two years', 'one year', 'half year', 'one month']);
      expect(memories.map((m) => m.label), ['2年前的今天', '1年前的今天', '半年前的今天', '1个月前的今天']);
    });

    test('the 31st is remembered on the last day of a shorter month', () {
      final memories =
          Memories.onThisDay([_entry('jan 31', _at(2026, 1, 31))], const DateParts(2026, 4, 30), zone: _utc);
      expect(memories.single.label, '3个月前的今天');
      expect(Memories.onThisDay([_entry('jan 31', _at(2026, 1, 31))], const DateParts(2026, 4, 29), zone: _utc), isEmpty);
    });

    test('a leap day comes back on 28 February', () {
      final memories =
          Memories.onThisDay([_entry('leap', _at(2024, 2, 29))], const DateParts(2026, 2, 28), zone: _utc);
      expect(memories.single.label, '2年前的今天');
    });
  });
}
