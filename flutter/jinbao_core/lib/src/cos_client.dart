import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'digest.dart';
import 'errors.dart';
import 'json_wire.dart';
import 'text.dart';
import 'v1_layout.dart';
import 'v1_validator.dart';

class ObjectRequest {
  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, String> headers;
  final Uint8List body;
  final String? bodyFilePath;
  final int responseLimit;
  final String? responseFilePath;

  ObjectRequest({
    required this.method,
    required this.path,
    this.query = const {},
    this.headers = const {},
    Uint8List? body,
    this.bodyFilePath,
    this.responseLimit = 32 * 1024 * 1024,
    this.responseFilePath,
  }) : body = body ?? Uint8List(0);
}

class ObjectResponse {
  final int status;
  final Map<String, String> headers;
  final Uint8List body;

  ObjectResponse({required this.status, this.headers = const {}, Uint8List? body}) : body = body ?? Uint8List(0);

  String? header(String name) {
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }
}

abstract class ObjectTransport {
  Future<ObjectResponse> execute(ObjectRequest request);
}

abstract final class CosEncoding {
  static String encode(String value, {bool preserveSlash = false}) {
    final out = StringBuffer();
    for (final byte in utf8.encode(value)) {
      final unreserved = (byte >= 65 && byte <= 90) ||
          (byte >= 97 && byte <= 122) ||
          (byte >= 48 && byte <= 57) ||
          byte == 45 ||
          byte == 95 ||
          byte == 46 ||
          byte == 126 ||
          (preserveSlash && byte == 47);
      if (unreserved) {
        out.writeCharCode(byte);
      } else {
        out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }
}

class CosSigner {
  final StorageCredentials _credentials;
  const CosSigner(this._credentials);

  @override
  String toString() => 'CosSigner(redacted)';

  String authorization({
    required String method,
    required String path,
    Map<String, String> query = const {},
    required Map<String, String> headers,
    required int now,
    int validFor = 900,
  }) {
    final verb = method.toUpperCase();
    const configuration = CosFailure(ConnectionFailure.configuration);
    if (!_credentials.isValid || !const ['GET', 'HEAD', 'PUT', 'POST'].contains(verb)) throw configuration;
    if (!path.startsWith('/') || now < 60 || validFor < 1 || validFor > 3600) throw configuration;
    final signingHeaders = Map<String, String>.of(headers);
    final token = _credentials.sessionToken;
    if (token != null) {
      final existing =
          signingHeaders.entries.where((e) => e.key.toLowerCase() == 'x-cos-security-token').toList();
      if (existing.length > 1 || existing.any((e) => e.value != token)) throw configuration;
      if (existing.isEmpty) signingHeaders['x-cos-security-token'] = token;
    }
    final int lifetime;
    final expiry = _credentials.expiresAt;
    if (expiry != null) {
      if (expiry <= now) throw const CosFailure(ConnectionFailure.expiredCredentials);
      lifetime = validFor < expiry - now ? validFor : expiry - now;
    } else {
      lifetime = validFor;
    }
    final end = now + lifetime;
    if (end < now) throw configuration;
    final (queryList, parameters) = _canonical(query);
    final (headerList, httpHeaders) = _canonical(signingHeaders);
    final keyTime = '${now - 60};$end';
    final signKey = _hmacHex(utf8.encode(_credentials.secretKey), utf8.encode(keyTime));
    final httpString = '${verb.toLowerCase()}\n$path\n$parameters\n$httpHeaders\n';
    final digest = Digest.hex(Digest.sha1(utf8.encode(httpString)));
    final signature = _hmacHex(utf8.encode(signKey), utf8.encode('sha1\n$keyTime\n$digest\n'));
    return 'q-sign-algorithm=sha1&q-ak=${_credentials.secretID}&q-sign-time=$keyTime&q-key-time=$keyTime'
        '&q-header-list=$headerList&q-url-param-list=$queryList&q-signature=$signature';
  }

  (String, String) _canonical(Map<String, String> fields) {
    final normalized = <String, String>{};
    for (final entry in fields.entries) {
      if (entry.key.isEmpty || hasControlScalar(entry.key) || hasControlScalar(entry.value)) {
        throw const CosFailure(ConnectionFailure.configuration);
      }
      final name = CosEncoding.encode(entry.key).toLowerCase();
      if (normalized.containsKey(name)) throw const CosFailure(ConnectionFailure.configuration);
      normalized[name] = CosEncoding.encode(entry.value);
    }
    final keys = normalized.keys.toList()..sort();
    return (keys.join(';'), keys.map((key) => '$key=${normalized[key]}').join('&'));
  }

  String _hmacHex(List<int> key, List<int> message) => Digest.hex(Digest.hmacSha1(key: key, message: message));
}

class ObjectHead {
  final int byteCount;
  final String? sha256;
  const ObjectHead({required this.byteCount, required this.sha256});
}

int _unixSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Immutable COS writes. There is no delete method: cloud objects are never removed by this app.
class CosClient {
  final StorageConfiguration configuration;
  final CosSigner _signer;
  final String? _sessionToken;
  final ObjectTransport _transport;
  final int Function() _now;

  CosClient({
    required this.configuration,
    required StorageCredentials credentials,
    required ObjectTransport transport,
    int Function() now = _unixSeconds,
  })  : _signer = CosSigner(credentials),
        _sessionToken = credentials.sessionToken,
        _transport = transport,
        _now = now {
    configuration.validate();
    if (!credentials.isValid) throw const CosFailure(ConnectionFailure.configuration);
  }

  @override
  String toString() => 'CosClient(redacted)';

  Future<List<String>> list({required String prefix}) async {
    _validateKey(prefix, allowPrefix: true);
    var marker = '';
    final seen = <String>{};
    final keys = <String>[];
    for (var page = 0; page < 10000; page++) {
      final query = {'prefix': prefix, 'max-keys': '1000', if (marker.isNotEmpty) 'marker': marker};
      final xml = await _xmlRequest('GET', null, query, 'ListBucketResult');
      final contents = <String>[];
      for (final node in xml.childrenNamed('Contents')) {
        final key = node.value('Key');
        if (key == null || !key.startsWith(prefix)) throw const CosFailure(ConnectionFailure.contentMismatch);
        _validateKey(key);
        contents.add(key);
      }
      if (keys.length + contents.length > 100000) throw const CosFailure(ConnectionFailure.contentMismatch);
      keys.addAll(contents);
      if (!xml.truncated) return keys;
      final next = xml.value('NextMarker') ?? (contents.isEmpty ? null : contents.last);
      if (next == null || next.isEmpty || next == marker || !seen.add(next)) {
        throw const CosFailure(ConnectionFailure.contentMismatch);
      }
      marker = next;
    }
    throw const CosFailure(ConnectionFailure.contentMismatch);
  }

  Future<ObjectHead?> head(String key) async {
    _validateKey(key);
    final response = await _send('HEAD', key);
    if (response.status == 404) return null;
    _interpretStatus(response);
    final length = int.tryParse(response.header('Content-Length') ?? '');
    if (length == null) throw const CosFailure(ConnectionFailure.contentMismatch);
    final hash = response.header('x-cos-meta-sha256');
    return ObjectHead(byteCount: length, sha256: hash != null && sha256Pattern.hasMatch(hash) ? hash : null);
  }

  Future<Uint8List> get({required String key, int responseLimit = 32 * 1024 * 1024}) async {
    _validateKey(key);
    if (responseLimit < 1 || responseLimit > JsonWire.metadataLimit) {
      throw const CosFailure(ConnectionFailure.configuration);
    }
    final response = await _send('GET', key, responseLimit: responseLimit);
    _interpretStatus(response);
    return response.body;
  }

  /// Download to a private staging file, validate the complete bytes, then publish the cache.
  Future<void> getFile(
      {required String key, required String destination, required int byteCount, required String sha256}) async {
    _validateKey(key);
    const mismatch = CosFailure(ConnectionFailure.contentMismatch);
    if (byteCount < 1 || byteCount > V1Validator.maxResourceBytes || !sha256Pattern.hasMatch(sha256)) throw mismatch;
    final existing = await head(key);
    if (existing == null || existing.byteCount != byteCount || (existing.sha256 != null && existing.sha256 != sha256)) {
      throw mismatch;
    }
    final folder = File(destination).parent;
    await folder.create(recursive: true);
    final partial = File('${folder.path}${Platform.pathSeparator}.download-${newUuid()}');
    try {
      final response = await _send('GET', key, responseLimit: byteCount, responseFilePath: partial.path);
      _interpretStatus(response);
      if (response.status != 200) throw mismatch;
      final actual = await Digest.sha256File(partial.path, maximumBytes: byteCount);
      if (actual.byteCount != byteCount || actual.hash != sha256) throw mismatch;
      final target = File(destination);
      if (await target.exists()) {
        final cached = await Digest.sha256File(destination, maximumBytes: byteCount);
        if (cached.byteCount != byteCount || cached.hash != sha256) throw mismatch;
      } else {
        await partial.rename(destination);
      }
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  /// COS forbid-overwrite is ineffective in versioned or versioning-suspended buckets.
  /// Only a valid, empty configuration proves versioning was never enabled.
  Future<void> verifyImmutableWritesAllowed() async {
    try {
      const query = {'versioning': ''};
      final response = await _send('GET', null, query: query, responseLimit: 64 * 1024);
      _interpretStatus(response);
      if (!VersioningSafety.isNeverEnabled(response.body)) throw const CosFailure(ConnectionFailure.unsafeVersioning);
    } on CosFailure catch (error) {
      const passThrough = [
        ConnectionFailure.permission,
        ConnectionFailure.invalidSecretID,
        ConnectionFailure.expiredCredentials,
        ConnectionFailure.signature,
        ConnectionFailure.network,
        ConnectionFailure.timeout,
      ];
      if (passThrough.contains(error.failure)) rethrow;
      throw const CosFailure(ConnectionFailure.unsafeVersioning);
    } catch (_) {
      throw const CosFailure(ConnectionFailure.unsafeVersioning);
    }
  }

  /// Metadata-only interface; use [putImmutableFile] for media.
  Future<void> put({required String key, required List<int> body, required String contentType}) =>
      putImmutable(key: key, body: body, contentType: contentType);

  /// HEAD avoids resending existing bytes; the conditional PUT protects the HEAD/PUT race.
  /// ETag is intentionally unread: a multipart ETag is not a file hash.
  Future<void> putImmutable({required String key, required List<int> body, required String contentType}) async {
    _validateKey(key);
    if (body.length > JsonWire.metadataLimit) throw const CosFailure(ConnectionFailure.contentMismatch);
    final hash = Digest.sha256Hex(body);
    await verifyImmutableWritesAllowed();
    if (await _matchingExistingObject(key, body.length, hash)) return;
    final headers = _immutableHeaders(contentType, hash)..['Content-Length'] = '${body.length}';
    final response = await _send('PUT', key, headers: headers, body: Uint8List.fromList(body));
    await _acceptImmutableResponse(response, key, body.length, hash);
  }

  /// Snapshot and hash before signing: replacing the original afterwards cannot alter the upload.
  /// Only the private staging directory is removed; the user's original is never changed.
  Future<void> putImmutableFile({
    required String key,
    required String filePath,
    required int byteCount,
    required String sha256,
    required String contentType,
  }) async {
    _validateKey(key);
    if (byteCount < 1 ||
        byteCount > V1Validator.maxResourceBytes ||
        !sha256Pattern.hasMatch(sha256) ||
        key != V1Layout.objectKey(prefix: configuration.prefix, sha256: sha256)) {
      throw const CosFailure(ConnectionFailure.contentMismatch);
    }
    final staged = await StagedMedia.create(filePath, byteCount: byteCount, sha256: sha256);
    try {
      await verifyImmutableWritesAllowed();
      if (await _matchingExistingObject(key, byteCount, sha256)) return;
      final headers = _immutableHeaders(contentType, sha256)..['Content-Length'] = '$byteCount';
      final response = await _send('PUT', key, headers: headers, bodyFilePath: staged.path);
      await _acceptImmutableResponse(response, key, byteCount, sha256);
    } finally {
      await staged.remove();
    }
  }

  Future<bool> _matchingExistingObject(String key, int byteCount, String sha256) async {
    final existing = await head(key);
    if (existing == null) return false;
    if (existing.byteCount != byteCount || existing.sha256 != sha256) {
      throw const CosFailure(ConnectionFailure.conflict);
    }
    return true;
  }

  Future<void> _acceptImmutableResponse(ObjectResponse response, String key, int byteCount, String sha256) async {
    if (response.status == 409 || response.status == 412) {
      if (!await _matchingExistingObject(key, byteCount, sha256)) {
        throw const CosFailure(ConnectionFailure.conflict);
      }
      return;
    }
    _interpretStatus(response);
  }

  Future<CosXml> _xmlRequest(String method, String? key, Map<String, String> query, String root) async {
    final response = await _send(method, key, query: query);
    final text = utf8.decode(response.body, allowMalformed: true);
    if (text.contains('<!DOCTYPE') || text.contains('<!ENTITY')) {
      throw const CosFailure(ConnectionFailure.contentMismatch);
    }
    if (response.status < 200 || response.status > 299) _interpretStatus(response);
    final xml = CosXml.parse(response.body);
    if (xml.name == 'Error') _interpretStatus(response);
    if (xml.name != root) throw const CosFailure(ConnectionFailure.contentMismatch);
    return xml;
  }

  Future<ObjectResponse> _send(
    String method,
    String? key, {
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    Uint8List? body,
    String? bodyFilePath,
    int responseLimit = 32 * 1024 * 1024,
    String? responseFilePath,
  }) async {
    if (!const ['GET', 'HEAD', 'PUT', 'POST'].contains(method)) {
      throw const CosFailure(ConnectionFailure.configuration);
    }
    final path = key == null ? '/' : '/$key';
    final signing = Map<String, String>.of(headers)
      ..['Host'] = configuration.host
      ..['Accept-Encoding'] = 'identity';
    if (_sessionToken != null) signing['x-cos-security-token'] = _sessionToken;
    final authorization = _signer.authorization(
        method: method,
        path: path,
        query: query,
        headers: signing,
        now: _now(),
        validFor: bodyFilePath == null ? 900 : 3600);
    signing['Authorization'] = authorization;
    final response = await _transport.execute(ObjectRequest(
      method: method,
      path: path,
      query: query,
      headers: signing,
      body: body,
      bodyFilePath: bodyFilePath,
      responseLimit: responseLimit,
      responseFilePath: responseFilePath,
    ));
    if (response.body.length > (responseFilePath == null ? responseLimit : 64 * 1024)) {
      throw const CosFailure(ConnectionFailure.contentMismatch);
    }
    return response;
  }

  Map<String, String> _immutableHeaders(String contentType, String sha256) => {
        'Content-Type': contentType,
        'x-cos-forbid-overwrite': 'true',
        'x-cos-server-side-encryption': 'AES256',
        'x-cos-meta-sha256': sha256,
      };

  void _interpretStatus(ObjectResponse response) {
    if (response.status >= 200 && response.status <= 299) return;
    switch (_errorCode(response.body)) {
      case 'InvalidAccessKeyId' || 'AccessKeyIdNotExist':
        throw const CosFailure(ConnectionFailure.invalidSecretID);
      case 'ExpiredToken':
        throw const CosFailure(ConnectionFailure.expiredCredentials);
      case 'SignatureDoesNotMatch' || 'RequestTimeTooSkewed':
        throw const CosFailure(ConnectionFailure.signature);
    }
    if (response.status == 401 || response.status == 403) throw const CosFailure(ConnectionFailure.permission);
    if (response.status == 404) throw const CosFailure(ConnectionFailure.notFound);
    throw const CosFailure(ConnectionFailure.network);
  }

  static final _code = RegExp(r'^[A-Za-z]+$');

  String? _errorCode(List<int> body) {
    final String text;
    try {
      text = utf8.decode(body);
    } on FormatException {
      return null;
    }
    final start = text.indexOf('<Code>');
    final end = text.indexOf('</Code>');
    if (start < 0 || end < 0 || end < start + 6) return null;
    final code = text.substring(start + 6, end);
    return _code.hasMatch(code) ? code : null;
  }

  void _validateKey(String key, {bool allowPrefix = false}) {
    final parts = key.split('/');
    final checked = (allowPrefix && parts.last.isEmpty) ? parts.sublist(0, parts.length - 1) : parts;
    final objects = '${V1Layout.objectRoot(configuration.prefix)}objects/';
    final allowed = key.startsWith(configuration.prefix) || key.startsWith(objects);
    final badSegment = checked.any((s) => s.isEmpty || s == '.' || s == '..');
    if (!allowed ||
        (!allowPrefix && key == configuration.prefix) ||
        utf8.encode(key).length > 1024 ||
        key.startsWith('/') ||
        key.contains(r'\') ||
        key.contains('%') ||
        hasControlScalar(key) ||
        badSegment) {
      throw const CosFailure(ConnectionFailure.configuration);
    }
  }
}

/// The list parser is intentionally not used for this security gate: a partial or unfamiliar
/// document must never be read as a disabled versioning setting. Accepted: an optional XML
/// declaration, then one `VersioningConfiguration` element (optionally with the S3 namespace)
/// that is empty or holds only whitespace. Anything else fails closed.
abstract final class VersioningSafety {
  static final _accepted = RegExp(
    r'^\s*(<\?xml[^<>]*\?>)?\s*<VersioningConfiguration(\s+xmlns="http://s3\.amazonaws\.com/doc/2006-03-01/")?\s*'
    r'(/>|>\s*</VersioningConfiguration\s*>)\s*$',
  );

  static bool isNeverEnabled(List<int> data) {
    final String text;
    try {
      text = utf8.decode(data);
    } on FormatException {
      return false;
    }
    if (text.contains('<!DOCTYPE') || text.contains('<!ENTITY')) return false;
    return _accepted.hasMatch(text);
  }
}

class CosXml {
  final String name;
  final String text;
  final List<CosXml> children;
  const CosXml(this.name, this.text, this.children);

  Iterable<CosXml> childrenNamed(String name) => children.where((c) => c.name == name);
  String? value(String name) {
    for (final child in children) {
      if (child.name == name) return child.text;
    }
    return null;
  }

  bool get truncated => value('IsTruncated') == 'true';

  static CosXml parse(List<int> data) {
    final String text;
    try {
      text = utf8.decode(data);
    } on FormatException {
      throw const CosFailure(ConnectionFailure.contentMismatch);
    }
    if (text.contains('<!DOCTYPE') || text.contains('<!ENTITY')) {
      throw const CosFailure(ConnectionFailure.contentMismatch);
    }
    final parser = _XmlParser(text)..skipPrologue();
    final node = parser.parseNode();
    if (node == null) throw const CosFailure(ConnectionFailure.contentMismatch);
    return node;
  }
}

class _XmlParser {
  final String text;
  int index = 0;
  _XmlParser(this.text);

  static const _mismatch = CosFailure(ConnectionFailure.contentMismatch);

  void skipPrologue() {
    while (true) {
      _skipUntilTag();
      if (text.startsWith('<?', index)) {
        final end = text.indexOf('?>', index);
        if (end < 0) throw _mismatch;
        index = end + 2;
        continue;
      }
      if (text.startsWith('<!--', index)) {
        final end = text.indexOf('-->', index);
        if (end < 0) throw _mismatch;
        index = end + 3;
        continue;
      }
      return;
    }
  }

  CosXml? parseNode() {
    _skipUntilTag();
    if (index >= text.length || text[index] != '<') return null;
    if (text.startsWith('</', index) || text.startsWith('<?', index) || text.startsWith('<!--', index)) return null;
    index++;
    final name = _readName();
    _skipAttributes();
    if (_consume('/>')) return CosXml(name, '', const []);
    if (!_consume('>')) throw _mismatch;
    final children = <CosXml>[];
    final body = StringBuffer();
    while (index < text.length) {
      if (text.startsWith('</', index)) {
        index += 2;
        final closing = _readName();
        if (closing != name || !_consume('>')) throw _mismatch;
        return CosXml(name, _unescape(body.toString()), children);
      }
      if (text[index] == '<') {
        final child = parseNode();
        if (child == null) break;
        children.add(child);
      } else {
        body.write(text[index]);
        index++;
      }
    }
    throw _mismatch;
  }

  void _skipAttributes() {
    while (index < text.length) {
      if (text.startsWith('/>', index) || text[index] == '>') return;
      final character = text[index];
      if (character == '"' || character == "'") {
        index++;
        while (index < text.length && text[index] != character) {
          index++;
        }
        if (index < text.length) index++;
        continue;
      }
      index++;
    }
    throw _mismatch;
  }

  void _skipUntilTag() {
    while (index < text.length && text[index] != '<') {
      index++;
    }
  }

  static final _nameCharacter = RegExp(r'[\p{L}\p{N}:_-]', unicode: true);

  String _readName() {
    final start = index;
    while (index < text.length && _nameCharacter.hasMatch(text[index])) {
      index++;
    }
    if (start == index) throw _mismatch;
    return text.substring(start, index);
  }

  bool _consume(String token) {
    if (!text.startsWith(token, index)) return false;
    index += token.length;
    return true;
  }

  String _unescape(String value) => value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&amp;', '&')
      .trim();
}

/// A private, read-only copy of the media taken before signing, verified against the expected hash.
class StagedMedia {
  final Directory directory;
  final String path;
  StagedMedia._(this.directory, this.path);

  static Future<StagedMedia> create(String source, {required int byteCount, required String sha256}) async {
    const mismatch = CosFailure(ConnectionFailure.contentMismatch);
    // Do not follow a swapped symlink or read anything but a regular file.
    if (await FileSystemEntity.type(source, followLinks: false) != FileSystemEntityType.file) throw mismatch;
    final directory = await Directory.systemTemp.createTemp('jinbao-upload-');
    final target = '${directory.path}${Platform.pathSeparator}body';
    try {
      final before = await File(source).stat();
      if (before.size != byteCount) throw mismatch;
      final output = _DigestSink();
      final hashing = crypto.sha256.startChunkedConversion(output);
      final input = await File(source).open();
      final sink = await File(target).open(mode: FileMode.writeOnly);
      var copied = 0;
      try {
        while (true) {
          final chunk = await input.read(1024 * 1024);
          if (chunk.isEmpty) break;
          copied += chunk.length;
          if (copied > byteCount) throw mismatch;
          hashing.add(chunk);
          await sink.writeFrom(chunk);
        }
        await sink.flush();
      } finally {
        await input.close();
        await sink.close();
      }
      hashing.close();
      final after = await File(source).stat();
      if (after.size != before.size ||
          after.modified != before.modified ||
          after.changed != before.changed ||
          copied != byteCount ||
          output.value.toString() != sha256) {
        throw mismatch;
      }
      return StagedMedia._(directory, target);
    } catch (_) {
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> remove() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

/// Production transport over `dart:io`. Request bodies and large responses stream through files.
class HttpObjectTransport implements ObjectTransport {
  final HttpClient _client;
  final StorageConfiguration configuration;
  final Duration timeout;

  HttpObjectTransport(this.configuration, {HttpClient? client, this.timeout = const Duration(seconds: 60)})
      : _client = client ?? HttpClient();

  @override
  Future<ObjectResponse> execute(ObjectRequest request) async {
    final query = request.query.entries
        .map((e) => e.value.isEmpty ? CosEncoding.encode(e.key) : '${CosEncoding.encode(e.key)}=${CosEncoding.encode(e.value)}')
        .join('&');
    final uri = Uri.parse('https://${configuration.host}${CosEncoding.encode(request.path, preserveSlash: true)}'
        '${query.isEmpty ? '' : '?$query'}');
    try {
      final http = await _client.openUrl(request.method, uri).timeout(timeout);
      http.followRedirects = false;
      for (final header in request.headers.entries) {
        if (header.key.toLowerCase() == 'host') continue;
        http.headers.set(header.key, header.value, preserveHeaderCase: true);
      }
      if (request.bodyFilePath != null) {
        await http.addStream(File(request.bodyFilePath!).openRead());
      } else if (request.body.isNotEmpty) {
        http.add(request.body);
      }
      final response = await http.close().timeout(timeout);
      final headers = <String, String>{};
      response.headers.forEach((name, values) => headers[name] = values.join(','));
      final limit = request.responseFilePath == null ? request.responseLimit : 64 * 1024;
      if (request.responseFilePath != null && response.statusCode == 200) {
        final sink = File(request.responseFilePath!).openWrite();
        var received = 0;
        await for (final chunk in response.timeout(timeout)) {
          received += chunk.length;
          if (received > request.responseLimit) {
            await sink.close();
            throw const CosFailure(ConnectionFailure.contentMismatch);
          }
          sink.add(chunk);
        }
        await sink.close();
        return ObjectResponse(status: response.statusCode, headers: headers);
      }
      final body = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        body.add(chunk);
        if (body.length > limit) throw const CosFailure(ConnectionFailure.contentMismatch);
      }
      return ObjectResponse(status: response.statusCode, headers: headers, body: body.takeBytes());
    } on TimeoutException {
      throw const CosFailure(ConnectionFailure.timeout);
    } on SocketException {
      throw const CosFailure(ConnectionFailure.network);
    } on HttpException {
      throw const CosFailure(ConnectionFailure.network);
    } on HandshakeException {
      throw const CosFailure(ConnectionFailure.network);
    }
  }
}
