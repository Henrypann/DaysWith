import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'cos_client.dart';
import 'digest.dart';
import 'storage_provider.dart';
import 'text.dart';
import 'v1_layout.dart';
import 'v1_validator.dart';

const _configuration = StorageProviderFailure(
  StorageProviderFailureKind.configuration,
);
const _invalid = StorageProviderFailure(
  StorageProviderFailureKind.invalidResponse,
);
const _integrity = StorageProviderFailure(StorageProviderFailureKind.integrity);
const _unsafe = StorageProviderFailure(
  StorageProviderFailureKind.unsafeConditionalWrites,
);

class WebDavCredentials {
  final String username;
  final String password;
  const WebDavCredentials({required this.username, required this.password});
  bool get isValid =>
      username.isNotEmpty &&
      !username.contains(':') &&
      password.isNotEmpty &&
      !hasControlScalar(username) &&
      !hasControlScalar(password) &&
      utf8.encode('$username:$password').length <= 16384;
  String get authorization {
    if (!isValid) throw _configuration;
    return 'Basic ${base64Encode(utf8.encode('$username:$password'))}';
  }

  @override
  String toString() => 'WebDavCredentials(redacted)';
}

/// HTTPS endpoint must end in a dedicated DaysWith directory. Existing NAS
/// photos elsewhere are never traversed. Arbitrary endpoints, query credentials,
/// encoded path segments and root directories are deliberately rejected.
class WebDavConfiguration {
  final Uri baseUri;
  final String prefix;
  factory WebDavConfiguration({
    required String baseUrl,
    String prefix = 'life/v1/',
  }) {
    final Uri uri;
    try {
      uri = Uri.parse(baseUrl);
    } catch (_) {
      throw _configuration;
    }
    final segments = uri.path.split('/').where((s) => s.isNotEmpty).toList();
    final safe = RegExp(r'^[A-Za-z0-9_.-]+$');
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        baseUrl.contains('%') ||
        baseUrl.contains(r'\') ||
        hasControlScalar(baseUrl) ||
        RegExp(r'(^|/)\.{1,2}(/|$)').hasMatch(baseUrl) ||
        !uri.path.endsWith('/') ||
        uri.path.contains('//') ||
        segments.isEmpty ||
        segments.any((s) => s == '.' || s == '..' || !safe.hasMatch(s)) ||
        !RegExp(r'^[Dd]ays[Ww]ith(?:-[A-Za-z0-9_-]+)?$')
            .hasMatch(segments.last)) {
      throw _configuration;
    }
    try {
      V1Layout.validatePrefix(prefix);
    } catch (_) {
      throw _configuration;
    }
    return WebDavConfiguration._(uri, prefix);
  }
  const WebDavConfiguration._(this.baseUri, this.prefix);
  StorageIdentity get identity => StorageIdentity(
    providerId: 'webdav',
    endpoint: baseUri.toString(),
    prefix: prefix,
  );
  @override
  String toString() => 'WebDavConfiguration(redacted)';
}

/// WebDAV has no standard continuation token or quota API. Depth:1 PROPFIND is
/// traversed with strict bounds, then snapshot-bound application pages are used.
/// Basic credentials remain in this instance; callers must not share them.
class WebDavStorageProvider extends StorageProvider {
  final WebDavConfiguration configuration;
  final WebDavCredentials _credentials;
  final ObjectTransport _transport;
  bool _safe = false;
  final Set<String> _directories = {};
  WebDavStorageProvider({
    required this.configuration,
    required WebDavCredentials credentials,
    ObjectTransport? transport,
  }) : _credentials = credentials,
       _transport = transport ?? HttpWebDavTransport(configuration) {
    if (!credentials.isValid) throw _configuration;
  }
  @override
  StorageIdentity get identity => StorageIdentity(
    providerId: 'webdav',
    endpoint: configuration.baseUri.toString(),
    prefix: configuration.prefix,
    accountScope: Digest.sha256Hex(utf8.encode(_credentials.username)),
  );
  @override
  StorageCapabilities get capabilities => StorageCapabilities(
    conditionalWrites: _safe,
    versioning: StorageVersioning.unknown,
    nativePagination: false,
  );
  @override
  String toString() => 'WebDavStorageProvider(redacted)';

  @override
  Future<void> connect() async {
    _safe = false;
    _directories.clear();
    await _ensureDirectory(configuration.baseUri.path);
    // A disposable random control object tests the server's actual conditional
    // PUT behavior. Never probe with an album object, and never delete a probe.
    final path = '${configuration.baseUri.path}.dayswith-probe-${newUuid()}';
    final original = Uint8List.fromList(utf8.encode(newUuid()));
    final changed = Uint8List.fromList(utf8.encode(newUuid()));
    final first = await _send(
      'PUT',
      path,
      body: original,
      headers: {
        'If-None-Match': '*',
        'Content-Type': 'application/octet-stream',
        'Content-Length': '${original.length}',
      },
    );
    if (first.status != 201) throw _unsafe;
    final second = await _send(
      'PUT',
      path,
      body: changed,
      headers: {
        'If-None-Match': '*',
        'Content-Type': 'application/octet-stream',
        'Content-Length': '${changed.length}',
      },
    );
    if (second.status != 412) throw _unsafe;
    final readback = await _send('GET', path, responseLimit: original.length);
    _status(readback);
    if (readback.status != 200 ||
        readback.body.length != original.length ||
        Digest.sha256Hex(readback.body) != Digest.sha256Hex(original)) {
      throw _unsafe;
    }
    _safe = true;
  }

  @override
  Future<void> verifyImmutableWritesAllowed() => connect();

  @override
  Future<void> healthCheck() async {
    final entries = await _propfind(configuration.baseUri.path, depth: '0');
    if (entries.length != 1 ||
        !entries.single.directory ||
        entries.single.path != configuration.baseUri.path) {
      throw _invalid;
    }
  }

  @override
  Future<StorageListPage> listPage({
    required String prefix,
    String? cursor,
    int limit = 1000,
  }) async {
    _validateKey(prefix, allowPrefix: true);
    if (limit < 1 || limit > 1000) throw _configuration;
    final slash = prefix.lastIndexOf('/');
    final startKey = prefix.endsWith('/')
        ? prefix
        : prefix.substring(0, slash + 1);
    final pending = <String>['${configuration.baseUri.path}$startKey'];
    final visited = <String>{};
    final keys = <String>[];
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      if (!visited.add(directory) || visited.length > 10000) throw _invalid;
      final entries = await _propfind(
        directory,
        depth: '1',
        missingIsEmpty: true,
      );
      for (final entry in entries) {
        if (entry.path == directory) continue;
        if (!entry.path.startsWith(directory)) throw _invalid;
        final relative = entry.path.substring(directory.length);
        final component = entry.directory
            ? relative.substring(0, relative.length - 1)
            : relative;
        if (component.isEmpty || component.contains('/')) throw _invalid;
        final key = entry.path.substring(configuration.baseUri.path.length);
        _validateKey(key, allowPrefix: entry.directory);
        if (entry.directory) {
          pending.add(entry.path);
        } else if (key.startsWith(prefix)) {
          keys.add(key);
        }
        if (keys.length > 100000) throw _invalid;
      }
    }
    return storageSnapshotPage(keys, prefix, cursor, limit);
  }

  @override
  Future<ObjectHead?> stat(String key) async {
    final response = await _send('HEAD', _path(key));
    if (response.status == 404) return null;
    _status(response);
    final count = int.tryParse(response.header('Content-Length') ?? '');
    if (count == null || count < 0 || count > V1Validator.maxResourceBytes) {
      throw _invalid;
    }
    // ETag and Last-Modified never prove media integrity.
    return ObjectHead(byteCount: count, sha256: null);
  }

  @override
  Future<Uint8List> get({
    required String key,
    int responseLimit = 32 * 1024 * 1024,
  }) async {
    if (responseLimit < 1 || responseLimit > 32 * 1024 * 1024) {
      throw _configuration;
    }
    final response = await _send(
      'GET',
      _path(key),
      responseLimit: responseLimit,
    );
    _status(response);
    if (response.status != 200) throw _invalid;
    return response.body;
  }

  @override
  Future<void> getFile({
    required String key,
    required String destination,
    required int byteCount,
    required String sha256,
  }) async {
    final path = _path(key);
    _validateFacts(byteCount, sha256);
    final directory = await Directory.systemTemp.createTemp(
      'dayswith-dav-download-',
    );
    final staging = File('${directory.path}/body');
    try {
      await _downloadVerified(path, staging.path, byteCount, sha256);
      final target = File(destination);
      if (await target.exists()) {
        final actual = await Digest.sha256File(
          destination,
          maximumBytes: byteCount,
        );
        if (actual.byteCount != byteCount || actual.hash != sha256) {
          throw _integrity;
        }
      } else {
        await target.parent.create(recursive: true);
        // Copy into the target filesystem first; publish by rename after hashing.
        final sibling = File(
          '${target.parent.path}/.dayswith-download-${newUuid()}',
        );
        try {
          await staging.copy(sibling.path);
          final copied = await Digest.sha256File(
            sibling.path,
            maximumBytes: byteCount,
          );
          if (copied.byteCount != byteCount || copied.hash != sha256) {
            throw _integrity;
          }
          if (await target.exists()) {
            throw const StorageProviderFailure(
              StorageProviderFailureKind.conflict,
            );
          }
          await sibling.rename(destination);
        } finally {
          if (await sibling.exists()) await sibling.delete();
        }
      }
    } finally {
      await directory.delete(recursive: true);
    }
  }

  @override
  Future<void> putImmutable({
    required String key,
    required List<int> body,
    required String contentType,
  }) async {
    if (body.length > 32 * 1024 * 1024) throw _integrity;
    final bytes = Uint8List.fromList(body);
    await _put(
      key,
      byteCount: bytes.length,
      sha256: Digest.sha256Hex(bytes),
      contentType: contentType,
      body: bytes,
    );
  }

  @override
  Future<void> putImmutableFile({
    required String key,
    required String filePath,
    required int byteCount,
    required String sha256,
    required String contentType,
  }) async {
    _validateFacts(byteCount, sha256);
    _path(key);
    if (key !=
        V1Layout.objectKey(prefix: configuration.prefix, sha256: sha256)) {
      throw _integrity;
    }
    final staged = await StagedMedia.create(
      filePath,
      byteCount: byteCount,
      sha256: sha256,
    );
    try {
      await _put(
        key,
        byteCount: byteCount,
        sha256: sha256,
        contentType: contentType,
        bodyFilePath: staged.path,
      );
    } finally {
      await staged.remove();
    }
  }

  Future<void> _put(
    String key, {
    required int byteCount,
    required String sha256,
    required String contentType,
    Uint8List? body,
    String? bodyFilePath,
  }) async {
    final path = _path(key);
    if (contentType.isEmpty || hasControlScalar(contentType)) {
      throw _configuration;
    }
    if (!_safe) await connect();
    final existing = await stat(key);
    if (existing != null) {
      if (existing.byteCount != byteCount) {
        throw const StorageProviderFailure(StorageProviderFailureKind.conflict);
      }
      await _verifyRemote(path, byteCount, sha256, conflict: true);
      return;
    }
    await _ensureParents(path);
    final response = await _send(
      'PUT',
      path,
      body: body,
      bodyFilePath: bodyFilePath,
      headers: {
        'If-None-Match': '*',
        'Content-Type': contentType,
        'Content-Length': '$byteCount',
      },
    );
    if (response.status == 409 || response.status == 412) {
      await _verifyRemote(path, byteCount, sha256, conflict: true);
      return;
    }
    _status(response);
    // A successful create must be 201. 200/204 may mean an existing file was overwritten.
    if (response.status != 201) {
      _safe = false;
      throw _unsafe;
    }
    await _verifyRemote(path, byteCount, sha256);
  }

  Future<void> _verifyRemote(
    String path,
    int count,
    String hash, {
    bool conflict = false,
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'dayswith-dav-readback-',
    );
    try {
      await _downloadVerified(path, '${directory.path}/body', count, hash);
    } on StorageProviderFailure catch (error) {
      if (conflict &&
          (error.kind == StorageProviderFailureKind.integrity ||
              error.kind == StorageProviderFailureKind.notFound)) {
        throw const StorageProviderFailure(StorageProviderFailureKind.conflict);
      }
      rethrow;
    } finally {
      await directory.delete(recursive: true);
    }
  }

  Future<void> _downloadVerified(
    String path,
    String destination,
    int count,
    String hash,
  ) async {
    final response = await _send(
      'GET',
      path,
      responseLimit: count,
      responseFilePath: destination,
    );
    _status(response);
    if (response.status != 200 || !await File(destination).exists()) {
      throw _integrity;
    }
    final actual = await Digest.sha256File(destination, maximumBytes: count);
    if (actual.byteCount != count || actual.hash != hash) throw _integrity;
  }

  void _validateFacts(int count, String hash) {
    if (count < 1 ||
        count > V1Validator.maxResourceBytes ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw _integrity;
    }
  }

  String _path(String key) {
    _validateKey(key);
    return '${configuration.baseUri.path}$key';
  }

  void _validateKey(String key, {bool allowPrefix = false}) {
    final parts = key.split('/');
    final segments = allowPrefix && parts.last.isEmpty
        ? parts.sublist(0, parts.length - 1)
        : parts;
    final objects = '${V1Layout.objectRoot(configuration.prefix)}objects/';
    if (!(key.startsWith(configuration.prefix) || key.startsWith(objects)) ||
        !allowPrefix && key == configuration.prefix ||
        key.startsWith('/') ||
        key.contains('%') ||
        key.contains(r'\') ||
        hasControlScalar(key) ||
        utf8.encode(key).length > 1024 ||
        segments.any(
          (s) =>
              s.isEmpty ||
              s == '.' ||
              s == '..' ||
              !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(s),
        )) {
      throw _configuration;
    }
  }

  Future<void> _ensureParents(String path) async {
    final relative =
        path.substring(configuration.baseUri.path.length).split('/')
          ..removeLast();
    var directory = configuration.baseUri.path;
    for (final segment in relative) {
      directory += '$segment/';
      await _ensureDirectory(directory);
    }
  }

  Future<void> _ensureDirectory(String path) async {
    if (_directories.contains(path)) return;
    var entries = await _propfind(path, depth: '0', missingIsEmpty: true);
    if (entries.isEmpty) {
      final created = await _send('MKCOL', path);
      if (created.status != 201 && created.status != 405) _status(created);
      entries = await _propfind(path, depth: '0');
    }
    if (entries.length != 1 ||
        entries.single.path != path ||
        !entries.single.directory) {
      throw _invalid;
    }
    _directories.add(path);
  }

  Future<List<_DavEntry>> _propfind(
    String path, {
    required String depth,
    bool missingIsEmpty = false,
  }) async {
    final response = await _send(
      'PROPFIND',
      path,
      headers: {
        'Depth': depth,
        'Content-Type': 'application/xml; charset=utf-8',
      },
      body: Uint8List.fromList(
        utf8.encode(
          '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
        ),
      ),
    );
    if (missingIsEmpty && response.status == 404) return [];
    _status(response);
    if (response.status != 207) throw _invalid;
    final xml = _DavXml.parse(response.body);
    if (xml.name != 'multistatus') throw _invalid;
    final result = <_DavEntry>[];
    final seen = <String>{};
    for (final entry in xml.children.where((e) => e.name == 'response')) {
      final href = entry.only('href').text;
      final uri = configuration.baseUri.resolve(href);
      if (uri.scheme != configuration.baseUri.scheme ||
          uri.host != configuration.baseUri.host ||
          uri.port != configuration.baseUri.port ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          !uri.path.startsWith(configuration.baseUri.path) ||
          href.contains('%') ||
          href.contains(r'\') ||
          hasControlScalar(href) ||
          href.split('/').any((s) => s == '.' || s == '..')) {
        throw _invalid;
      }
      final props = entry.children.where((e) => e.name == 'propstat').toList();
      final successful = props
          .where(
            (p) =>
                RegExp(r'^HTTP/1\.[01] 200(?: |$)')
                    .hasMatch(p.only('status').text),
          )
          .toList();
      if (successful.length != 1) throw _invalid;
      final resource = successful.single.only('prop').only('resourcetype');
      final isDirectory = resource.children.any((e) => e.name == 'collection');
      final canonical = isDirectory && !uri.path.endsWith('/')
          ? '${uri.path}/'
          : uri.path;
      if (!seen.add(canonical)) throw _invalid;
      result.add(_DavEntry(canonical, isDirectory));
    }
    return result;
  }

  Future<ObjectResponse> _send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    Uint8List? body,
    String? bodyFilePath,
    int responseLimit = 8 * 1024 * 1024,
    String? responseFilePath,
  }) async {
    try {
      final response = await _transport.execute(
        ObjectRequest(
          method: method,
          path: path,
          headers: {
            ...headers,
            'Authorization': _credentials.authorization,
            'Accept-Encoding': 'identity',
          },
          body: body,
          bodyFilePath: bodyFilePath,
          responseLimit: responseLimit,
          responseFilePath: responseFilePath,
        ),
      );
      if (response.status >= 300 && response.status < 400) throw _invalid;
      final encoding = response.header('Content-Encoding');
      if (encoding != null && encoding.toLowerCase() != 'identity') {
        throw _invalid;
      }
      if (response.body.length >
          (responseFilePath == null ? responseLimit : 64 * 1024)) {
        throw _invalid;
      }
      return response;
    } on StorageProviderFailure {
      rethrow;
    } on TimeoutException {
      throw const StorageProviderFailure(StorageProviderFailureKind.timeout);
    } on IOException {
      throw const StorageProviderFailure(StorageProviderFailureKind.network);
    }
  }

  void _status(ObjectResponse response) {
    if (response.status >= 200 && response.status < 300) return;
    if (response.status == 401 || response.status == 403) {
      throw const StorageProviderFailure(StorageProviderFailureKind.permission);
    }
    if (response.status == 404) {
      throw const StorageProviderFailure(StorageProviderFailureKind.notFound);
    }
    if (response.status == 409 || response.status == 412) {
      throw const StorageProviderFailure(StorageProviderFailureKind.conflict);
    }
    throw const StorageProviderFailure(StorageProviderFailureKind.network);
  }
}

class _DavEntry {
  final String path;
  final bool directory;
  const _DavEntry(this.path, this.directory);
}

/// No redirect following, certificate override, authentication retry, or proxy
/// credential forwarding. Media request and response bodies stay file-backed.
class HttpWebDavTransport implements ObjectTransport {
  final WebDavConfiguration configuration;
  final HttpClient _client;
  final Duration timeout;
  HttpWebDavTransport(
    this.configuration, {
    this.timeout = const Duration(seconds: 60),
  }) : _client = HttpClient();
  void close() => _client.close(force: true);
  @override
  Future<ObjectResponse> execute(ObjectRequest request) async {
    if (!const [
          'PROPFIND',
          'MKCOL',
          'PUT',
          'HEAD',
          'GET',
        ].contains(request.method) ||
        request.query.isNotEmpty ||
        !request.path.startsWith(configuration.baseUri.path) ||
        request.path.contains('%') ||
        request.path.contains(r'\') ||
        request.path.split('/').any((s) => s == '.' || s == '..') ||
        hasControlScalar(request.path)) {
      throw _configuration;
    }
    final uri = configuration.baseUri.replace(path: request.path);
    HttpClientRequest? http;
    try {
      http = await _client.openUrl(request.method, uri).timeout(timeout);
      http.followRedirects = false;
      for (final header in request.headers.entries) {
        http.headers.set(header.key, header.value);
      }
      if (request.bodyFilePath != null) {
        await http
            .addStream(File(request.bodyFilePath!).openRead())
            .timeout(timeout);
      } else if (request.body.isNotEmpty) {
        http.add(request.body);
      }
      final response = await http.close().timeout(timeout);
      final headers = <String, String>{};
      response.headers.forEach(
        (key, values) => headers[key] = values.join(','),
      );
      final encoding = response.headers.value('Content-Encoding');
      if (encoding != null && encoding.toLowerCase() != 'identity') {
        throw _invalid;
      }
      if (request.responseFilePath != null && response.statusCode == 200) {
        final file = await File(request.responseFilePath!)
            .open(mode: FileMode.writeOnly);
        var count = 0;
        try {
          await for (final chunk in response.timeout(timeout)) {
            count += chunk.length;
            if (count > request.responseLimit) throw _integrity;
            await file.writeFrom(chunk);
          }
          await file.flush();
        } finally {
          await file.close();
        }
        return ObjectResponse(status: response.statusCode, headers: headers);
      }
      final bytes = BytesBuilder(copy: false);
      final limit = request.responseFilePath == null
          ? request.responseLimit
          : 64 * 1024;
      await for (final chunk in response.timeout(timeout)) {
        if (bytes.length + chunk.length > limit) throw _invalid;
        bytes.add(chunk);
      }
      return ObjectResponse(
        status: response.statusCode,
        headers: headers,
        body: bytes.takeBytes(),
      );
    } on StorageProviderFailure {
      http?.abort();
      rethrow;
    } on TimeoutException {
      http?.abort();
      throw const StorageProviderFailure(StorageProviderFailureKind.timeout);
    } on IOException {
      http?.abort();
      throw const StorageProviderFailure(StorageProviderFailureKind.network);
    }
  }
}

/// Small bounded XML reader for DAV. Rejects entities/DTD, trailing documents,
/// excess nesting and malformed tags; namespace prefixes do not affect matching.
class _DavXml {
  final String name;
  final String text;
  final List<_DavXml> children;
  const _DavXml(this.name, this.text, this.children);
  _DavXml only(String name) {
    final values = children.where((e) => e.name == name).toList();
    if (values.length != 1) throw _invalid;
    return values.single;
  }

  static _DavXml parse(List<int> bytes) {
    if (bytes.length > 8 * 1024 * 1024) throw _invalid;
    final String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      throw _invalid;
    }
    final reader = _DavXmlReader(text);
    reader.whitespace();
    if (text.startsWith('<?xml', reader.index)) {
      final end = text.indexOf('?>', reader.index);
      if (end < 0) throw _invalid;
      reader.index = end + 2;
    }
    reader.whitespace();
    final root = reader.node(0);
    reader.whitespace();
    if (reader.index != text.length) throw _invalid;
    return root;
  }
}

class _DavXmlReader {
  final String input;
  int index = 0;
  int nodes = 0;
  _DavXmlReader(this.input);
  void whitespace() {
    while (index < input.length && RegExp(r'\s').hasMatch(input[index])) {
      index++;
    }
  }

  bool consume(String text) {
    if (!input.startsWith(text, index)) return false;
    index += text.length;
    return true;
  }

  String name() {
    final match = RegExp(r'[A-Za-z_][A-Za-z0-9_.:-]*')
        .matchAsPrefix(input, index);
    if (match == null) throw _invalid;
    index = match.end;
    return match[0]!;
  }

  _DavXml node(int depth) {
    if (depth > 32 || ++nodes > 200000 || !consume('<')) throw _invalid;
    final tag = name();
    final attributes = <String>{};
    while (true) {
      whitespace();
      if (consume('/>')) return _DavXml(tag.split(':').last, '', []);
      if (consume('>')) break;
      final attribute = name();
      if (!attributes.add(attribute)) throw _invalid;
      whitespace();
      if (!consume('=')) throw _invalid;
      whitespace();
      if (index >= input.length || input[index] != '"' && input[index] != "'") {
        throw _invalid;
      }
      final quote = input[index++];
      while (index < input.length && input[index] != quote) {
        if (input[index] == '<') throw _invalid;
        index++;
      }
      if (index >= input.length) throw _invalid;
      index++;
    }
    final children = <_DavXml>[];
    final body = StringBuffer();
    while (index < input.length) {
      if (consume('</')) {
        if (name() != tag) throw _invalid;
        whitespace();
        if (!consume('>')) throw _invalid;
        return _DavXml(
          tag.split(':').last,
          decode(body.toString()).trim(),
          children,
        );
      }
      if (input[index] == '<') {
        children.add(node(depth + 1));
      } else {
        body.write(input[index++]);
      }
    }
    throw _invalid;
  }

  String decode(String text) =>
      text.replaceAllMapped(RegExp(r'&([^;]+);'), (match) {
        return switch (match[1]) {
          'amp' => '&',
          'lt' => '<',
          'gt' => '>',
          'quot' => '"',
          'apos' => "'",
          _ => throw _invalid,
        };
      });
}
