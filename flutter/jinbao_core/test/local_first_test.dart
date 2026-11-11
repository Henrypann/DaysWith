import 'package:jinbao_core/jinbao_core.dart';
import 'package:test/test.dart';

/// DaysWith 4.0 local-first: records made before a verified connection stay on the phone
/// until the user explicitly adds them to the backup scope.
void main() {
  const device = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

  late Set<String> ids;

  AppSession localSession({bool testBuild = false}) {
    final session = AppSession(deviceID: device, testBuild: testBuild)..confirmIdentity(ParentIdentity.mom);
    session
      ..beginDraft(now: 1000)
      ..updateDraft(title: '第一次翻身', note: '');
    final moment = session.commitDraft(now: 1000);
    final anniversary = session.saveAnniversary(title: '出生日', date: '2025-03-12', now: 1000);
    ids = {moment.id, anniversary.id};
    return session;
  }

  test('records made without a connection are local-only and never planned for backup', () {
    final session = localSession();
    expect(session.adoptableCount(ids), 2);
    session.connectVerified(bucket: 'family-1234567890', region: 'ap-shanghai');
    expect(session.adoptableCount(ids), 2);
    expect(session.backupAnniversaries(), isEmpty);
  });

  test('adoption needs a verified connection', () {
    final session = localSession();
    expect(() => session.adoptLocalOnlyRecords(ids), throwsA(isA<ContractError>()));
    session.connectPlaceholder(bucket: '', region: '');
    expect(() => session.adoptLocalOnlyRecords(ids), throwsA(isA<ContractError>()));
    expect(session.adoptableCount(ids), 2);
  });

  test('adoption moves the named records into the family scope and keeps content', () {
    final session = localSession()..connectVerified(bucket: 'family-1234567890', region: 'ap-shanghai');
    final before = session.moments.single.copy();
    expect(session.adoptLocalOnlyRecords(ids.map((id) => id.toLowerCase()).toSet()), 2);
    expect(session.adoptableCount(ids), 0);
    final after = session.moments.single;
    expect(after.uploadEligibility, UploadEligibility.eligible);
    expect(after.id, before.id);
    expect(after.title, before.title);
    expect(after.revision, before.revision);
    expect(session.backupAnniversaries().single.title, '出生日');
    expect(session.adoptLocalOnlyRecords(ids), 0);
    // Survives persistence.
    expect(session.copy().moments.single.uploadEligibility, UploadEligibility.eligible);
  });

  test('a test build adopts into the test scope only', () {
    final session = localSession(testBuild: true)..connectVerified(bucket: 'family-1234567890', region: 'ap-shanghai');
    session.adoptLocalOnlyRecords(ids);
    expect(session.moments.single.uploadEligibility, UploadEligibility.testOnly);
  });

  test('local-only records that were not named stay on the phone', () {
    final session = localSession()..connectVerified(bucket: 'family-1234567890', region: 'ap-shanghai');
    // For example a record imported from an older install: local-only, same owner, not named.
    session.moments.add(LocalMoment(
        id: newUuid(), title: '旧版导入', note: '', occurredAt: 1, createdAt: 1, updatedAt: 1, parent: ParentIdentity.mom, assets: []));
    expect(session.adoptableCount(ids), 2);
    expect(session.adoptLocalOnlyRecords(ids), 2);
    expect(session.moments.last.uploadEligibility, UploadEligibility.localOnly);
    expect(session.adoptLocalOnlyRecords(const {}), 0);
  });

  test('records signed by the other parent are never adopted, even when named', () {
    final session = localSession()..connectVerified(bucket: 'family-1234567890', region: 'ap-shanghai');
    final other = LocalMoment(
        id: newUuid(), title: '爸爸的', note: '', occurredAt: 1, createdAt: 1, updatedAt: 1, parent: ParentIdentity.dad, assets: []);
    session.moments.add(other);
    session.adoptLocalOnlyRecords({...ids, other.id});
    expect(session.moments.last.uploadEligibility, UploadEligibility.localOnly);
  });
}
