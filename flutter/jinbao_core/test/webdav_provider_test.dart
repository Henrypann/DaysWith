import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jinbao_core/src/cos_client.dart';
import 'package:jinbao_core/src/digest.dart';
import 'package:jinbao_core/src/storage_provider.dart';
import 'package:jinbao_core/src/v1_layout.dart';
import 'package:jinbao_core/src/webdav_provider.dart';
import 'package:test/test.dart';

const _root = '/remote.php/dav/files/test/DaysWith/';
const _key = 'life/v1/dad/commits/test.json';
final _config = WebDavConfiguration(
  baseUrl: 'https://nas.example:5006$_root',
  prefix: 'life/v1/dad/',
);
Matcher failure(StorageProviderFailureKind kind) =>
    isA<StorageProviderFailure>().having((e) => e.kind, 'kind', kind);

class MemoryDav implements ObjectTransport {
  final directories = <String>{_root};
  final files = <String, Uint8List>{};
  final requests = <ObjectRequest>[];
  bool ignoreConditional = false;
  bool corruptAlbumDownload = false;
  bool redirect = false;
  bool timeout = false;
  String? poisonHref;
  void seed(String key, List<int> bytes) {
    files['$_root$key'] = Uint8List.fromList(bytes);
    var path = _root;
    for (final part in key.split('/')..removeLast()) {
      path += '$part/';
      directories.add(path);
    }
  }

  @override
  Future<ObjectResponse> execute(ObjectRequest request) async {
    requests.add(request);
    if (timeout) throw TimeoutException('secret server detail');
    if (redirect) {
      return ObjectResponse(
        status: 307,
        headers: {'Location': 'https://other.example/'},
      );
    }
    if (request.method == 'PROPFIND') {
      if (!directories.contains(request.path)) {
        return ObjectResponse(status: 404);
      }
      final entries = <String, bool>{request.path: true};
      if (request.headers['Depth'] == '1') {
        for (final path in directories.where(
          (p) => p != request.path && p.startsWith(request.path),
        )) {
          if (!path
              .substring(request.path.length, path.length - 1)
              .contains('/')) {
            entries[path] = true;
          }
        }
        for (final path in files.keys.where(
          (p) => p.startsWith(request.path),
        )) {
          if (!path.substring(request.path.length).contains('/')) {
            entries[path] = false;
          }
        }
      }
      if (poisonHref != null) entries[poisonHref!] = false;
      final xml =
          '<d:multistatus xmlns:d="DAV:">${entries.entries.map((e) => '<d:response><d:href>${e.key}</d:href><d:propstat><d:prop><d:resourcetype>${e.value ? '<d:collection/>' : ''}</d:resourcetype></d:prop>'
              '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>').join()}</d:multistatus>';
      return ObjectResponse(
        status: 207,
        body: Uint8List.fromList(utf8.encode(xml)),
      );
    }
    if (request.method == 'MKCOL') {
      final added = directories.add(request.path);
      return ObjectResponse(status: added ? 201 : 405);
    }
    if (request.method == 'HEAD') {
      final body = files[request.path];
      return ObjectResponse(
        status: body == null ? 404 : 200,
        headers: body == null
            ? {}
            : {'Content-Length': '${body.length}', 'ETag': 'not-a-hash'},
      );
    }
    if (request.method == 'PUT') {
      final existing = files.containsKey(request.path);
      if (existing &&
          request.headers['If-None-Match'] == '*' &&
          !ignoreConditional) {
        return ObjectResponse(status: 412);
      }
      files[request.path] = request.bodyFilePath == null
          ? Uint8List.fromList(request.body)
          : await File(request.bodyFilePath!).readAsBytes();
      return ObjectResponse(status: existing ? 204 : 201);
    }
    if (request.method == 'GET') {
      var bytes = files[request.path];
      if (bytes == null) return ObjectResponse(status: 404);
      if (corruptAlbumDownload && !request.path.contains('.dayswith-probe-')) {
        bytes = Uint8List.fromList(List.filled(bytes.length, 0));
      }
      if (request.responseFilePath != null) {
        await File(request.responseFilePath!).writeAsBytes(bytes, flush: true);
        return ObjectResponse(status: 200);
      }
      return ObjectResponse(status: 200, body: bytes);
    }
    throw StateError('unsupported test method');
  }
}

WebDavStorageProvider provider(MemoryDav transport) => WebDavStorageProvider(
  configuration: _config,
  credentials: const WebDavCredentials(
    username: 'test-user',
    password: 'test-password',
  ),
  transport: transport,
);

void main() {
  test('URLs require HTTPS dedicated directory and reject traversal credentials and queries', () {
    for (final url in [
      'http://nas.example/DaysWith/',
      'https://nas.example/',
      'https://user:password@nas.example/DaysWith/',
      'https://nas.example/DaysWith/?token=secret',
      'https://nas.example/DaysWith/#x',
      'https://nas.example/a/../DaysWith/',
      'https://nas.example/%252e%252e/DaysWith/',
      'https://nas.example/a\\b/DaysWith/',
      'https://nas.example/photos/',
    ]) {
      expect(
        () => WebDavConfiguration(baseUrl: url),
        throwsA(failure(StorageProviderFailureKind.configuration)),
        reason: url,
      );
    }
    expect(_config.baseUri.port, 5006);
    expect(_config.identity.providerId, 'webdav');
    const credentials = WebDavCredentials(username: 'user', password: 'pass');
    expect(credentials.toString(), 'WebDavCredentials(redacted)');
    expect(
      const WebDavCredentials(username: 'user:admin', password: 'pass').isValid,
      isFalse,
    );
  });
  test('connect proves conditional create using retained random control file, never DELETE', () async {
    final memory = MemoryDav();
    final storage = provider(memory);
    expect(storage.capabilities.conditionalWrites, isFalse);
    expect(storage.capabilities.quotaBytes, isNull);
    await storage.connect();
    expect(storage.capabilities.conditionalWrites, isTrue);
    expect(memory.files.keys.single, contains('.dayswith-probe-'));
    expect(memory.requests.where((r) => r.method == 'PUT'), hasLength(2));
    expect(memory.requests.every((r) => r.method != 'DELETE'), isTrue);
    await expectLater(
      storage.delete(_key),
      throwsA(failure(StorageProviderFailureKind.forbidden)),
    );
  });
  test(
    'server ignoring If-None-Match fails closed before album upload',
    () async {
      final memory = MemoryDav()..ignoreConditional = true;
      final storage = provider(memory);
      await expectLater(
        storage.putImmutable(
          key: _key,
          body: [1, 2],
          contentType: 'application/json',
        ),
        throwsA(failure(StorageProviderFailureKind.unsafeConditionalWrites)),
      );
      expect(storage.capabilities.conditionalWrites, isFalse);
      expect(
        memory.files.keys.every((p) => p.contains('.dayswith-probe-')),
        isTrue,
      );
    },
  );
  test('immutable metadata uploads read back every byte and repeat without rewriting', () async {
    final memory = MemoryDav();
    final storage = provider(memory);
    await storage.putImmutable(
      key: _key,
      body: [1, 2, 3],
      contentType: 'application/json',
    );
    final uploads = memory.requests
        .where((r) => r.method == 'PUT' && r.path.endsWith(_key))
        .length;
    expect(uploads, 1);
    expect(
      memory.requests.any(
        (r) =>
            r.method == 'GET' &&
            r.path.endsWith(_key) &&
            r.responseFilePath != null,
      ),
      isTrue,
    );
    await storage.putImmutable(
      key: _key,
      body: [1, 2, 3],
      contentType: 'application/json',
    );
    expect(
      memory.requests.where((r) => r.method == 'PUT' && r.path.endsWith(_key)),
      hasLength(1),
    );
    await expectLater(
      storage.putImmutable(
        key: _key,
        body: [9, 8, 7],
        contentType: 'application/json',
      ),
      throwsA(failure(StorageProviderFailureKind.conflict)),
    );
    expect(memory.files['$_root$_key'], [1, 2, 3]);
    expect((await storage.stat(_key))!.sha256, isNull);
  });
  test('incorrect readback never reports successful upload', () async {
    final memory = MemoryDav()..corruptAlbumDownload = true;
    await expectLater(
      provider(memory).putImmutable(
        key: _key,
        body: [1, 2, 3],
        contentType: 'application/json',
      ),
      throwsA(failure(StorageProviderFailureKind.integrity)),
    );
  });
  test(
    'file transfer is staged and file-backed, original bytes remain intact',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'dav-provider-test-',
      );
      try {
        final original = File('${directory.path}/original')
          ..writeAsBytesSync(List.generate(1024 * 1024 + 3, (i) => i % 251));
        final facts = await Digest.sha256File(original.path);
        final key = V1Layout.objectKey(
          prefix: _config.prefix,
          sha256: facts.hash,
        );
        final memory = MemoryDav();
        final storage = provider(memory);
        await storage.putImmutableFile(
          key: key,
          filePath: original.path,
          byteCount: facts.byteCount,
          sha256: facts.hash,
          contentType: 'image/jpeg',
        );
        final upload = memory.requests.singleWhere(
          (r) => r.method == 'PUT' && r.path.endsWith(key),
        );
        expect(upload.body, isEmpty);
        expect(upload.bodyFilePath, isNot(original.path));
        expect(await File(upload.bodyFilePath!).exists(), isFalse);
        final downloaded = '${directory.path}/downloaded';
        await storage.getFile(
          key: key,
          destination: downloaded,
          byteCount: facts.byteCount,
          sha256: facts.hash,
        );
        expect(await Digest.sha256File(downloaded), facts);
        expect(await Digest.sha256File(original.path), facts);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'recursive depth1 listings page deterministically and stale cursor fails',
    () async {
      final memory = MemoryDav()
        ..seed('life/v1/dad/commits/a.json', [1])
        ..seed('life/v1/dad/commits/b.json', [2]);
      final storage = provider(memory);
      final first = await storage.listPage(prefix: 'life/v1/dad/', limit: 1);
      expect(first.keys, ['life/v1/dad/commits/a.json']);
      final second = await storage.listPage(
        prefix: 'life/v1/dad/',
        cursor: first.nextCursor,
        limit: 1,
      );
      expect(second.keys, ['life/v1/dad/commits/b.json']);
      memory.seed('life/v1/dad/commits/c.json', [3]);
      await expectLater(
        storage.listPage(prefix: 'life/v1/dad/', cursor: first.nextCursor),
        throwsA(failure(StorageProviderFailureKind.staleCursor)),
      );
      expect(
        memory.requests
            .where((r) => r.method == 'PROPFIND')
            .every((r) => r.headers['Depth'] != 'infinity'),
        isTrue,
      );
    },
  );
  test('key traversal is rejected before opening a request', () async {
    final memory = MemoryDav();
    for (final key in [
      'life/v1/dad/../mom/a',
      'life/v1/dad/%2e%2e/a',
      '/life/v1/dad/a',
      'life/v1/mom/a',
    ]) {
      await expectLater(
        provider(memory).get(key: key),
        throwsA(failure(StorageProviderFailureKind.configuration)),
      );
    }
    expect(memory.requests, isEmpty);
  });
  test('PROPFIND cannot escape the dedicated directory', () async {
    final memory = MemoryDav()..poisonHref = '/photos/private.jpg';
    await expectLater(
      provider(memory).healthCheck(),
      throwsA(failure(StorageProviderFailureKind.invalidResponse)),
    );
  });
  test('redirects are refused without forwarding credentials and timeout stays redacted', () async {
    final memory = MemoryDav()..redirect = true;
    await expectLater(
      provider(memory).connect(),
      throwsA(failure(StorageProviderFailureKind.invalidResponse)),
    );
    expect(memory.requests, hasLength(1));
    memory.redirect = false;
    memory.timeout = true;
    await expectLater(
      provider(memory).healthCheck(),
      throwsA(failure(StorageProviderFailureKind.timeout)),
    );
    expect(
      const StorageProviderFailure(StorageProviderFailureKind.timeout)
          .toString(),
      isNot(contains('secret')),
    );
  });
}
