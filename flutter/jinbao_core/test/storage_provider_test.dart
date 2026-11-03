import 'package:jinbao_core/src/storage_provider.dart';
import 'package:test/test.dart';

void main() {
  test('identity round trips without COS fields or credentials', () {
    const identity = StorageIdentity(
      providerId: 'webdav',
      endpoint: 'https://nas.example/DaysWith/',
      prefix: 'life/v1/',
    );
    expect(StorageIdentity.fromJson(identity.toJson()), identity);
    expect(identity.toJson().keys, ['providerId', 'endpoint', 'prefix']);
    expect(identity.toString(), isNot(contains('nas.example')));
    expect(
      identity,
      isNot(
        const StorageIdentity(
          providerId: 'cos',
          endpoint: 'https://nas.example/DaysWith/',
          prefix: 'life/v1/',
        ),
      ),
    );
  });
  test('snapshot pages are deterministic and reject changed listings', () {
    final first = storageSnapshotPage(['c', 'a', 'b'], 'root/', null, 2);
    expect(first.keys, ['a', 'b']);
    expect(
      storageSnapshotPage(['b', 'a', 'c'], 'root/', first.nextCursor, 2).keys,
      ['c'],
    );
    expect(
      () => storageSnapshotPage(
        ['a', 'b', 'c', 'd'],
        'root/',
        first.nextCursor,
        2,
      ),
      throwsA(
        isA<StorageProviderFailure>().having(
          (e) => e.kind,
          'kind',
          StorageProviderFailureKind.staleCursor,
        ),
      ),
    );
    expect(
      () => storageSnapshotPage(['a'], 'root/', null, 0),
      throwsA(isA<StorageProviderFailure>()),
    );
  });
}
