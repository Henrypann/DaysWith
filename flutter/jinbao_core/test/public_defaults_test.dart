import 'dart:convert';
import 'package:jinbao_core/jinbao_core.dart';
import 'package:test/test.dart';

void main() {
  AppSession session() => AppSession(
      deviceID: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      testBuild: true,
      identity: ParentIdentity.dad);

  test('fresh install has exactly three yearless public holidays without writes', () {
    final state = session();
    final entries = state.anniversaryEntries();
    expect(entries.map((e) => e.title), ['儿童节', '国庆节', '元旦']);
    expect(entries.map((e) => e.date), ['0004-06-01', '0004-10-01', '0004-01-01']);
    expect(entries.every((e) => !e.yearKnown), isTrue);
    expect(state.anniversaries, isEmpty);
    expect(state.anniversaryEntries(), entries);
    expect(JinbaoCalendar.age(const DateParts(2030, 2, 3)), isNull);
    expect(JinbaoCalendar.dayTitle(const DateParts(2030, 2, 3)), '2月3日');
    expect(() => const StorageConfiguration().validate(), throwsA(isA<ContractError>()));
  });

  test('blank first-run fields can enter a local placeholder, never a verified connection', () {
    final state = session();
    expect(state.phase, AppPhase.connectCloud);
    expect(() => state.connectVerified(bucket: '', region: ''), throwsA(isA<ContractError>()));
    state.connectPlaceholder(bucket: '', region: '');
    expect(state.phase, AppPhase.timeline);
    expect(state.link, isA<CloudPlaceholder>());
    expect(state.link.bucket, 'example-1234567890');
    expect(state.anniversaries, isEmpty);
    expect(() => BackupPlan.manifest(state, now: 1), throwsA(isA<ContractError>()));
  });

  test('saved legacy rows and tombstones survive new defaults and repeat reads', () {
    final state = session();
    final legacy = LocalAnniversary(
        id: '00000000-0000-4000-8000-000000000001',
        owner: ParentIdentity.dad, title: '用户已保存', date: '2000-02-03', updatedAt: 1);
    state.anniversaries.add(legacy);
    state.saveAnniversary(id: AnniversaryCalendar.defaults[0].id,
        title: '用户改过', date: '--02-14', now: 2);
    state.deleteAnniversary(id: AnniversaryCalendar.defaults[1].id, now: 3);
    final before = state.anniversaries.map((e) => e.toJson()).toList();
    final entries = state.anniversaryEntries();
    expect(entries.length, 3);
    expect(entries.singleWhere((e) => e.id == legacy.id).date, '2000-02-03');
    expect(entries.singleWhere((e) => e.title == '用户改过').date, '0004-02-14');
    expect(entries.any((e) => e.title == '国庆节'), isFalse);
    expect(state.anniversaryEntries(), entries);
    expect(state.anniversaries.map((e) => e.toJson()).toList(), before);
    final reloaded = PersistedArchive.fromJson(
        jsonDecode(jsonEncode(PersistedArchive.fromSession(state).toJson()))).session();
    expect(reloaded.anniversaryEntries(), entries);
    expect(reloaded.anniversaries.map((e) => e.toJson()).toList(), before);
  });

  test('annual holidays roll across the year without invented anniversaries', () {
    final result = AnniversaryCalendar.upcoming(session().anniversaryEntries(),
        now: DateTime.utc(2030, 12, 31).millisecondsSinceEpoch, zone: const FixedOffsetZone(0));
    expect(result.first.entry.title, '元旦');
    expect(result.first.daysUntil, 1);
    expect(result.every((e) => e.years == null), isTrue);
  });
}
