/// Authenticated immutable family transfers and isolated full-media recovery.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'digest.dart';
import 'family.dart';
import 'family_archive.dart';
import 'json_wire.dart';
import 'text.dart' show newUuid;
import 'v1_validator.dart';

const _metadataLimit = 8 * 1024 * 1024;
final _digestPattern = RegExp(r'^[a-f0-9]{64}$');

enum FamilyArchiveClientFailure {
  paused, integrity, invalidResponse, invalidPath, unauthenticated,
  denied, revoked, conflict, unavailable, timeout,
}

class FamilyArchiveClientException implements Exception {
  final FamilyArchiveClientFailure failure;
  /// Only an app-private local staging directory, never a token or remote URL.
  final String? stageDirectory;
  const FamilyArchiveClientException(this.failure, {this.stageDirectory});
  @override
  String toString() => 'FamilyArchiveClientException(${failure.name})';
}

/// Injectable streaming boundary. Media paths refer only to caller-owned files.
class FamilyArchiveRequest {
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final List<int> body;
  final String? sourceFile;
  final String? destinationFile;
  final int? transferByteCount;
  final int maxResponseBytes;
  final bool Function()? shouldPause;
  FamilyArchiveRequest({
    required this.method, required this.uri, required Map<String, String> headers,
    List<int> body = const [], this.sourceFile, this.destinationFile,
    this.transferByteCount, this.maxResponseBytes = _metadataLimit,
    this.shouldPause,
  }) : headers = Map.unmodifiable(headers), body = List.unmodifiable(body);
  @override
  String toString() => 'FamilyArchiveRequest($method, redacted)';
}

class FamilyArchiveResponse {
  final int statusCode;
  final Map<String, String> headers;
  final List<int> body;
  FamilyArchiveResponse({required this.statusCode,
    Map<String, String> headers = const {}, List<int> body = const []})
      : headers = Map.unmodifiable({for (final entry in headers.entries) entry.key.toLowerCase(): entry.value}),
        body = List.unmodifiable(body);
}

abstract interface class FamilyArchiveTransport {
  Future<FamilyArchiveResponse> send(FamilyArchiveRequest request);
}

/// TLS verification remains enabled. Redirects are never followed with a bearer.
/// File bodies flow through backpressure-aware streams; originals stay off heap.
class IoFamilyArchiveTransport implements FamilyArchiveTransport {
  final Duration timeout;
  const IoFamilyArchiveTransport({this.timeout = const Duration(minutes: 5)});
  @override
  Future<FamilyArchiveResponse> send(FamilyArchiveRequest request) async {
    if (request.uri.scheme != 'https' || request.uri.host.isEmpty || request.uri.userInfo.isNotEmpty) {
      _fail(FamilyArchiveClientFailure.invalidPath);
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    Future<FamilyArchiveResponse> perform() async {
      _pause(request.shouldPause);
      final outgoing = await client.openUrl(request.method, request.uri);
      outgoing.followRedirects = false;
      outgoing.maxRedirects = 0;
      outgoing.bufferOutput = false;
      request.headers.forEach(outgoing.headers.set);
      if (request.sourceFile case final source?) {
        await outgoing.addStream(_chunks(File(source).openRead(), request.shouldPause,
            maximum: request.transferByteCount));
      } else {
        outgoing.add(request.body);
      }
      final incoming = await outgoing.close();
      final headers = <String, String>{};
      incoming.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(','));
      if (request.destinationFile != null && incoming.statusCode >= 200 && incoming.statusCode < 300) {
        final target = File(request.destinationFile!);
        if (FileSystemEntity.typeSync(target.path, followLinks: false) != FileSystemEntityType.notFound) {
          _fail(FamilyArchiveClientFailure.invalidPath);
        }
        await target.create(exclusive: true);
        final sink = target.openWrite();
        try {
          await sink.addStream(_chunks(incoming, request.shouldPause, maximum: request.transferByteCount));
          await sink.flush();
        } finally {
          await sink.close();
        }
        return FamilyArchiveResponse(statusCode: incoming.statusCode, headers: headers);
      }
      final bytes = <int>[];
      await for (final chunk in _chunks(incoming, request.shouldPause, maximum: request.maxResponseBytes)) {
        bytes.addAll(chunk);
      }
      return FamilyArchiveResponse(statusCode: incoming.statusCode, headers: headers, body: bytes);
    }
    try {
      return await perform().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }
}

class FamilyArchiveSnapshot {
  final FamilyArchiveScope scope;
  final int sequence;
  final String sha256;
  final int byteCount;
  FamilyArchiveSnapshot({required this.scope, required this.sequence,
    required this.sha256, required this.byteCount}) {
    if (sequence < 1 || sequence > 9007199254740991 || !_digestPattern.hasMatch(sha256) ||
        byteCount < 1 || byteCount > _metadataLimit) _fail(FamilyArchiveClientFailure.invalidResponse);
  }
  factory FamilyArchiveSnapshot.fromJson(Object? value) {
    try {
      final json = _object(value);
      return FamilyArchiveSnapshot(
        scope: FamilyArchiveScope(familyID: _string(json, 'familyID'),
          memberID: _string(json, 'memberID'), deviceID: _string(json, 'deviceID')),
        sequence: _integer(json['sequence']), sha256: _string(json, 'sha256'),
        byteCount: _integer(json['byteCount']),
      );
    } on FamilyArchiveClientException { rethrow; }
    catch (_) { _fail(FamilyArchiveClientFailure.invalidResponse); }
  }
  Map<String, Object?> toJson() => {'familyID': scope.familyID, 'memberID': scope.memberID,
    'deviceID': scope.deviceID, 'sequence': sequence, 'sha256': sha256, 'byteCount': byteCount};
  String get key => '${scope.memberID}/${scope.deviceID}/$sequence';
}

/// A separately audited administrator decision. It never rewrites the owner's
/// immutable record bytes, revision, tombstone or original media.
class FamilyArchiveModeration {
  final int id;
  final String familyID;
  final String ownerMemberID;
  final String recordID;
  final bool hidden;
  final int recordRevision;
  final int at;
  final String actorMemberID;
  FamilyArchiveModeration._({required this.id, required this.familyID,
    required this.ownerMemberID, required this.recordID, required this.hidden,
    required this.recordRevision, required this.at, required this.actorMemberID});

  factory FamilyArchiveModeration.fromJson(Object? value) {
    try {
      final json = _object(value);
      const fields = {'id', 'familyID', 'ownerMemberID', 'recordID', 'hidden',
        'recordRevision', 'at', 'actorMemberID'};
      if (json.length != fields.length || json.keys.any((key) => !fields.contains(key)) ||
          json['hidden'] is! bool) _fail(FamilyArchiveClientFailure.invalidResponse);
      return FamilyArchiveModeration._(
        id: _boundedInteger(json['id'], minimum: 1),
        familyID: _canonicalID(json['familyID']), ownerMemberID: _canonicalID(json['ownerMemberID']),
        recordID: _canonicalID(json['recordID']), hidden: json['hidden'] as bool,
        recordRevision: _boundedInteger(json['recordRevision'], minimum: 1),
        at: _boundedInteger(json['at'], maximum: V1Validator.maxTimestamp),
        actorMemberID: _canonicalID(json['actorMemberID']),
      );
    } on FamilyArchiveClientException { rethrow; }
    catch (_) { _fail(FamilyArchiveClientFailure.invalidResponse); }
  }
  String get recordKey => '$ownerMemberID/$recordID';
  Map<String, Object?> toJson() => {'id': id, 'familyID': familyID,
    'ownerMemberID': ownerMemberID, 'recordID': recordID, 'hidden': hidden,
    'recordRevision': recordRevision, 'at': at, 'actorMemberID': actorMemberID};
}

/// The snapshot set and moderation overlay describe the same server watermark.
/// Losing or silently defaulting the overlay would expose hidden shared records.
class FamilyArchiveCatalog {
  final String familyID;
  final List<FamilyArchiveSnapshot> snapshots;
  final List<FamilyArchiveModeration> moderations;
  final int moderationVersion;
  FamilyArchiveCatalog({required String familyID,
    required List<FamilyArchiveSnapshot> snapshots,
    required List<FamilyArchiveModeration> moderations, required this.moderationVersion})
      : familyID = familyStableID(familyID), snapshots = List.unmodifiable(snapshots),
        moderations = List.unmodifiable(moderations) {
    _boundedInteger(moderationVersion);
    if (snapshots.length > 10000 || moderations.length > 10000 ||
        snapshots.any((snapshot) => snapshot.scope.familyID != this.familyID) ||
        snapshots.map((snapshot) => snapshot.key).toSet().length != snapshots.length) {
      _fail(FamilyArchiveClientFailure.invalidResponse);
    }
    var previousID = 0;
    final records = <String>{};
    for (final event in moderations) {
      if (event.familyID != this.familyID || event.id <= previousID || event.id > moderationVersion ||
          !records.add(event.recordKey)) _fail(FamilyArchiveClientFailure.invalidResponse);
      previousID = event.id;
    }
    if (previousID != moderationVersion) {
      // The latest-per-record overlay must retain the family's greatest event.
      // A nonzero watermark with a truncated/empty overlay must never unhide it.
      _fail(FamilyArchiveClientFailure.invalidResponse);
    }
  }

  factory FamilyArchiveCatalog.fromJson(Object? value, {required String familyID}) {
    final data = _object(value);
    final snapshots = data['snapshots'];
    final moderations = data['moderations'];
    if (snapshots is! List || snapshots.length > 10000 ||
        moderations is! List || moderations.length > 10000) {
      _fail(FamilyArchiveClientFailure.invalidResponse);
    }
    return FamilyArchiveCatalog(familyID: familyID,
      snapshots: snapshots.map(FamilyArchiveSnapshot.fromJson).toList(),
      moderations: moderations.map(FamilyArchiveModeration.fromJson).toList(),
      moderationVersion: _boundedInteger(data['moderationVersion']));
  }

  String get overlayFingerprint => Digest.sha256Hex(JsonWire.encode({
    'moderationVersion': moderationVersion, 'moderations': moderations.map((e) => e.toJson()).toList()}));
  String get fingerprint => Digest.sha256Hex(JsonWire.encode(toJson()));
  Map<String, Object?> toJson() {
    final ordered = [...snapshots]..sort((a, b) => a.key.compareTo(b.key));
    return {'snapshots': ordered.map((s) => s.toJson()).toList(),
      'moderationVersion': moderationVersion, 'moderations': moderations.map((e) => e.toJson()).toList()};
  }

  /// Requires the complete merged raw record set, before date/search filtering.
  /// A later owner edit never implicitly cancels an administrator's decision.
  List<FamilyArchiveRecord> visibleRecords(List<FamilyArchiveRecord> records) {
    final byID = {for (final record in records) '${record.ownerMemberID}/${record.id}': record};
    if (byID.length != records.length) _fail(FamilyArchiveClientFailure.integrity);
    for (final event in moderations) {
      final record = byID[event.recordKey];
      if (record == null || event.recordRevision > record.revision) {
        _fail(FamilyArchiveClientFailure.integrity);
      }
    }
    final hidden = moderations.where((event) => event.hidden).map((event) => event.recordKey).toSet();
    return List.unmodifiable(records.where((record) => !hidden.contains('${record.ownerMemberID}/${record.id}')));
  }
}

class FamilyArchiveRestoreResult {
  final String directory;
  final List<FamilyArchiveRecord> records;
  final List<FamilyArchiveAnniversary> anniversaries;
  final int verifiedResourceCount;
  final int verifiedByteCount;
  final int manifestCount;
  final Map<String, String> resourceFiles;
  final FamilyArchiveCatalog catalog;
  List<FamilyArchiveModeration> get moderations => catalog.moderations;
  int get moderationVersion => catalog.moderationVersion;
  List<FamilyArchiveRecord> get visibleRecords => catalog.visibleRecords(records);
  FamilyArchiveRestoreResult._({required this.directory, required List<FamilyArchiveRecord> records,
    required List<FamilyArchiveAnniversary> anniversaries, required this.verifiedResourceCount,
    required this.verifiedByteCount, required this.manifestCount, required Map<String, String> resourceFiles,
    required this.catalog})
      : records = List.unmodifiable(records), anniversaries = List.unmodifiable(anniversaries),
        resourceFiles = Map.unmodifiable(resourceFiles);
}

class FamilyArchiveClient {
  final Uri origin;
  final Future<String?> Function() _accessToken;
  final FamilyArchiveTransport _transport;
  final Duration timeout;
  FamilyArchiveClient({required Uri origin, required Future<String?> Function() accessToken,
    FamilyArchiveTransport? transport, this.timeout = const Duration(minutes: 5)})
      : origin = _origin(origin), _accessToken = accessToken,
        _transport = transport ?? IoFamilyArchiveTransport(timeout: timeout) {
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
  }

  Future<void> registerDevice(FamilyArchiveScope scope) async {
    final response = await _request('POST', '/v1/families/${scope.familyID}/devices/${scope.deviceID}',
        body: utf8.encode('{}'));
    if (_object(_json(response))['ok'] != true) _fail(FamilyArchiveClientFailure.invalidResponse);
  }

  Future<List<FamilyArchiveSnapshot>> catalog(String familyID, {bool Function()? shouldPause}) async =>
      (await loadCatalog(familyID, shouldPause: shouldPause)).snapshots;

  Future<FamilyArchiveCatalog> loadCatalog(String familyID, {bool Function()? shouldPause}) async {
    final family = familyStableID(familyID);
    final snapshots = <FamilyArchiveSnapshot>[];
    final keys = <String>{};
    final cursors = <String>{};
    FamilyArchiveCatalog? firstPage;
    String? cursor;
    do {
      _pause(shouldPause);
      final response = await _request('GET', '/v1/families/$family/archive',
          query: {'limit': '100', if (cursor != null) 'cursor': cursor}, shouldPause: shouldPause);
      final data = _object(_json(response));
      if (!data.containsKey('nextCursor')) _fail(FamilyArchiveClientFailure.invalidResponse);
      final page = FamilyArchiveCatalog.fromJson(data, familyID: family);
      if (firstPage == null) firstPage = page;
      else if (page.overlayFingerprint != firstPage.overlayFingerprint) {
        _fail(FamilyArchiveClientFailure.conflict);
      }
      final list = data['snapshots'];
      if (list is! List || list.length > 100) _fail(FamilyArchiveClientFailure.invalidResponse);
      for (final value in list) {
        final descriptor = FamilyArchiveSnapshot.fromJson(value);
        if (descriptor.scope.familyID != family || !keys.add(descriptor.key)) {
          _fail(FamilyArchiveClientFailure.invalidResponse);
        }
        snapshots.add(descriptor);
      }
      if (snapshots.length > 10000) _fail(FamilyArchiveClientFailure.invalidResponse);
      final next = data['nextCursor'];
      if (next != null && (next is! String || next.isEmpty || next.length > 4096 ||
          list.isEmpty || !cursors.add(next))) _fail(FamilyArchiveClientFailure.invalidResponse);
      cursor = next as String?;
    } while (cursor != null);
    final overlay = firstPage;
    if (overlay == null) _fail(FamilyArchiveClientFailure.invalidResponse);
    return FamilyArchiveCatalog(familyID: family, snapshots: snapshots,
      moderations: overlay.moderations, moderationVersion: overlay.moderationVersion);
  }

  /// Explicit administrator action only. The server authenticates the caller
  /// and checks role/revision; no local role check can grant this permission.
  Future<FamilyArchiveModeration> moderateRecord({required String familyID,
    required String ownerMemberID, required String recordID,
    required int expectedRevision, required bool hidden}) async {
    final family = familyStableID(familyID);
    final owner = familyStableID(ownerMemberID);
    final record = familyStableID(recordID);
    _boundedInteger(expectedRevision, minimum: 1);
    final response = await _request('POST', '/v1/families/$family/members/$owner/records/$record/moderation',
      body: JsonWire.encode({'expectedRevision': expectedRevision, 'hidden': hidden}));
    final event = FamilyArchiveModeration.fromJson(_json(response));
    if (event.familyID != family || event.ownerMemberID != owner || event.recordID != record ||
        event.recordRevision != expectedRevision || event.hidden != hidden) {
      _fail(FamilyArchiveClientFailure.invalidResponse);
    }
    return event;
  }

  /// Returns one verified preview/original in an app-private scoped cache.
  /// Possession of cached bytes is never proof of current family authorization.
  Future<String> loadResource({required FamilyArchiveScope scope,
    required FamilyArchiveResource resource, required Directory cacheParent,
    bool Function()? shouldPause}) async {
    try {
      return await _loadResource(scope: scope, resource: resource,
        cacheParent: cacheParent, shouldPause: shouldPause);
    } on FamilyArchiveClientException { rethrow; }
    catch (_) { _fail(FamilyArchiveClientFailure.unavailable); }
  }

  Future<String> _loadResource({required FamilyArchiveScope scope,
    required FamilyArchiveResource resource, required Directory cacheParent,
    bool Function()? shouldPause}) async {
    _pause(shouldPause);
    // Check the current remote grant before inspecting or exposing a cache hit.
    final initial = await _request('HEAD', _mediaPath(scope, resource.sha256), shouldPause: shouldPause);
    if (!_matches(initial, resource)) _fail(FamilyArchiveClientFailure.integrity);
    _safeDirectory(cacheParent.absolute.path, create: true);
    final parent = cacheParent.resolveSymbolicLinksSync();
    final originHash = Digest.sha256Hex(utf8.encode(origin.toString()));
    final folder = '$parent/family-resources-v1/$originHash/${scope.familyID}/${scope.memberID}';
    _safeDirectory(folder, create: true);
    final target = '$folder/${resource.sha256}';
    var verified = false;
    if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) {
      try {
        await _verifyFile(target, resource, shouldPause);
        verified = true;
      } on FamilyArchiveClientException catch (error) {
        if (error.failure != FamilyArchiveClientFailure.integrity) rethrow;
        File(target).renameSync('$folder/.corrupt-${resource.sha256}-${newUuid()}');
      }
    }
    if (!verified) {
      final part = '$folder/.${resource.sha256}-${newUuid()}.part';
      try {
        await _request('GET', _mediaPath(scope, resource.sha256), destinationFile: part,
          transferByteCount: resource.byteCount, shouldPause: shouldPause);
        await _verifyFile(part, resource, shouldPause);
        if (FileSystemEntity.typeSync(target, followLinks: false) == FileSystemEntityType.notFound) {
          File(part).renameSync(target);
        } else {
          // A concurrent view may have completed this same immutable download.
          await _verifyFile(target, resource, shouldPause);
        }
      } finally {
        if (FileSystemEntity.typeSync(part, followLinks: false) == FileSystemEntityType.file) {
          File(part).deleteSync();
        }
      }
    }
    final current = await _request('HEAD', _mediaPath(scope, resource.sha256), shouldPause: shouldPause);
    if (!_matches(current, resource)) _fail(FamilyArchiveClientFailure.integrity);
    _pause(shouldPause);
    return target;
  }

  Future<FamilyArchiveManifest> getManifest(FamilyArchiveSnapshot descriptor,
      {bool Function()? shouldPause}) async {
    final response = await _request('GET', _snapshotPath(descriptor), shouldPause: shouldPause);
    if (response.body.length != descriptor.byteCount || Digest.sha256Hex(response.body) != descriptor.sha256) {
      _fail(FamilyArchiveClientFailure.integrity);
    }
    try {
      final manifest = FamilyArchiveManifest.decode(response.body, expectedScope: descriptor.scope);
      if (manifest.sequence != descriptor.sequence || manifest.sha256 != descriptor.sha256) {
        _fail(FamilyArchiveClientFailure.integrity);
      }
      return manifest;
    } on FamilyArchiveClientException { rethrow; } catch (_) {
      _fail(FamilyArchiveClientFailure.integrity);
    }
  }

  /// Supplied source files are all verified before any write. An omitted file
  /// may be reused only after authenticated remote HEAD confirms size and hash.
  /// No retries are hidden: retrying this exact manifest reuses its immutable URI.
  Future<FamilyArchiveSnapshot> publishManifest(FamilyArchiveManifest manifest,
      {required Map<String, String> sourceFiles, bool Function()? shouldPause}) async {
    final bytes = manifest.encode();
    final frozen = FamilyArchiveManifest.decode(bytes, expectedScope: manifest.scope);
    final resources = _resources(frozen.records, frozen.scope.familyID);
    final sources = <String, String>{};
    for (final entry in resources.entries) {
      _pause(shouldPause);
      final path = sourceFiles[entry.key] ?? sourceFiles[entry.value.$2.sha256];
      if (path != null) {
        await _verifyFile(path, entry.value.$2, shouldPause);
        sources[entry.key] = path;
      }
    }
    _pause(shouldPause);
    await registerDevice(frozen.scope);
    for (final entry in resources.entries) {
      _pause(shouldPause);
      final (scope, resource) = entry.value;
      final remote = await _request('HEAD', _mediaPath(scope, resource.sha256),
          allowNotFound: true, shouldPause: shouldPause);
      if (remote.statusCode == 200 && _matches(remote, resource)) continue;
      final source = sources[entry.key];
      if (source == null) _fail(FamilyArchiveClientFailure.integrity);
      if (remote.statusCode != 404) _fail(FamilyArchiveClientFailure.integrity);
      await _request('PUT', _mediaPath(scope, resource.sha256), sourceFile: source,
          transferByteCount: resource.byteCount, digest: resource.sha256,
          contentType: resource.contentType, shouldPause: shouldPause);
      final verified = await _request('HEAD', _mediaPath(scope, resource.sha256), shouldPause: shouldPause);
      if (!_matches(verified, resource)) _fail(FamilyArchiveClientFailure.integrity);
    }
    _pause(shouldPause);
    final expected = FamilyArchiveSnapshot(scope: frozen.scope, sequence: frozen.sequence,
        sha256: Digest.sha256Hex(bytes), byteCount: bytes.length);
    final response = await _request('PUT', _snapshotPath(expected), body: bytes,
        digest: expected.sha256, contentType: 'application/json', shouldPause: shouldPause);
    final actual = FamilyArchiveSnapshot.fromJson(_json(response));
    if (JsonWire.encodeString(actual.toJson()) != JsonWire.encodeString(expected.toJson())) {
      _fail(FamilyArchiveClientFailure.integrity);
    }
    // Publication success is followed by an independent immutable byte read.
    await getManifest(actual, shouldPause: shouldPause);
    return actual;
  }

  /// The active app archive and original media are never opened for writing.
  /// A failure leaves an explicitly incomplete stage, suitable only for this
  /// authenticated family's retry. Cached files are hashed again on every retry.
  Future<FamilyArchiveRestoreResult> restoreFamily({required String familyID,
    required Directory restoreParent, String? resumeDirectory,
    bool Function()? shouldPause, int maxTotalBytes = 8 * 1024 * 1024 * 1024,
    void Function(String stageDirectory)? onStageCreated}) async {
    final family = familyStableID(familyID);
    _safeDirectory(restoreParent.absolute.path, create: true);
    final parent = restoreParent.resolveSymbolicLinksSync();
    late final String stage;
    if (resumeDirectory == null) {
      stage = '$parent/.family-restore-${newUuid()}.pending';
      try {
        Directory(stage).createSync();
        _writeNew('$stage/STATUS.json', JsonWire.encode({'state': 'incomplete',
          'familyID': family, 'origin': origin.toString(), 'catalogSha256': null}));
      } catch (_) {
        throw FamilyArchiveClientException(FamilyArchiveClientFailure.unavailable, stageDirectory: stage);
      }
    } else {
      _safeDirectory(Directory(resumeDirectory).absolute.path);
      stage = Directory(resumeDirectory).resolveSymbolicLinksSync();
      if (Directory(stage).parent.path != parent ||
          !RegExp(r'^\.family-restore-[A-F0-9-]{36}\.pending$').hasMatch(stage.split(Platform.pathSeparator).last)) {
        _fail(FamilyArchiveClientFailure.invalidPath);
      }
      _safeDirectory(stage);
    }
    try {
      _pause(shouldPause);
      final status = _object(JsonWire.parse(_readRegular('$stage/STATUS.json'), path: 'restoreStatus'));
      if (status['state'] != 'incomplete' || status['familyID'] != family || status['origin'] != origin.toString()) {
        _fail(FamilyArchiveClientFailure.invalidPath);
      }
      // Hosts persist this pointer synchronously, bound to their authenticated
      // family/member/session. A persistence failure aborts before any network.
      onStageCreated?.call(stage);
      // Requires a live session even when every byte was already cached.
      final current = await loadCatalog(family, shouldPause: shouldPause);
      final List<FamilyArchiveSnapshot> descriptors;
      final FamilyArchiveCatalog pinnedCatalog;
      if (status['catalogSha256'] == null) {
        pinnedCatalog = current;
        descriptors = current.snapshots;
        final catalogBytes = JsonWire.encode(current.toJson());
        // A crash between the immutable catalog write and status checkpoint is
        // recoverable only when the current authenticated full catalog is exact.
        _writeIdentical('$stage/catalog.json', catalogBytes);
        _replaceStageStatus(stage, {'state': 'incomplete', 'familyID': family,
          'origin': origin.toString(), 'catalogSha256': Digest.sha256Hex(catalogBytes),
          'catalogCount': descriptors.length});
      } else {
        final pinned = _readRegular('$stage/catalog.json');
        if (Digest.sha256Hex(pinned) != status['catalogSha256']) _fail(FamilyArchiveClientFailure.integrity);
        final data = _object(JsonWire.parse(pinned, path: 'restoreCatalog'));
        pinnedCatalog = FamilyArchiveCatalog.fromJson(data, familyID: family);
        descriptors = pinnedCatalog.snapshots;
        if (status['catalogCount'] != descriptors.length ||
            pinnedCatalog.fingerprint != current.fingerprint) {
          _fail(FamilyArchiveClientFailure.conflict);
        }
        final known = {for (final descriptor in current.snapshots) descriptor.key: JsonWire.encodeString(descriptor.toJson())};
        final unique = <String>{};
        for (final descriptor in descriptors) {
          if (descriptor.scope.familyID != family || !unique.add(descriptor.key) ||
              known[descriptor.key] != JsonWire.encodeString(descriptor.toJson())) {
            _fail(FamilyArchiveClientFailure.integrity);
          }
        }
      }
      final ordered = [...descriptors]..sort((a, b) {
        final byScope = '${a.scope.memberID}/${a.scope.deviceID}'.compareTo('${b.scope.memberID}/${b.scope.deviceID}');
        return byScope == 0 ? a.sequence.compareTo(b.sequence) : byScope;
      });
      if (ordered.fold<int>(0, (sum, descriptor) => sum + descriptor.byteCount) > 64 * 1024 * 1024) {
        _fail(FamilyArchiveClientFailure.invalidResponse);
      }
      final manifests = <FamilyArchiveManifest>[];
      final manifestFiles = <String, String>{};
      final previous = <FamilyArchiveScope, FamilyArchiveManifest>{};
      for (final descriptor in ordered) {
        _pause(shouldPause);
        // Re-read metadata from the immutable authorized server even on retry.
        final manifest = await getManifest(descriptor, shouldPause: shouldPause);
        manifest.validateSuccessor(previous[manifest.scope]);
        previous[manifest.scope] = manifest;
        manifests.add(manifest);
        final folder = '$stage/manifests/${manifest.scope.memberID}/${manifest.scope.deviceID}';
        _safeDirectory(folder, create: true);
        final name = '${manifest.sequence}-${descriptor.sha256}.json';
        _writeIdentical('$folder/$name', manifest.encode());
        manifestFiles[descriptor.key] = 'manifests/${manifest.scope.memberID}/${manifest.scope.deviceID}/$name';
      }
      final records = mergeFamilyArchiveRecords(manifests, familyID: family);
      pinnedCatalog.visibleRecords(records); // Validate every overlay reference.
      final dates = _mergeDates(manifests);
      final resources = _resources(records, family);
      final total = resources.values.fold<int>(0, (sum, value) => sum + value.$2.byteCount);
      if (maxTotalBytes < 0 || total > maxTotalBytes || resources.length > 100000) {
        _fail(FamilyArchiveClientFailure.integrity);
      }
      final files = <String, String>{};
      for (final entry in resources.entries) {
        _pause(shouldPause);
        final (scope, resource) = entry.value;
        final folder = '$stage/objects/${scope.memberID}';
        _safeDirectory(folder, create: true);
        final target = '$folder/${resource.sha256}';
        var verified = false;
        if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) {
          try {
            await _verifyFile(target, resource, shouldPause);
            verified = true;
          } on FamilyArchiveClientException catch (error) {
            if (error.failure != FamilyArchiveClientFailure.integrity) rethrow;
            // Preserve the bad cached bytes for inspection; never treat a
            // digest-named file as evidence until its complete bytes match.
            File(target).renameSync('$folder/.corrupt-${resource.sha256}-${newUuid()}');
          }
        }
        if (!verified) {
          final part = '$folder/.${resource.sha256}-${newUuid()}.part';
          try {
            await _request('GET', _mediaPath(scope, resource.sha256), destinationFile: part,
                transferByteCount: resource.byteCount, shouldPause: shouldPause);
            await _verifyFile(part, resource, shouldPause);
            if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) {
              _fail(FamilyArchiveClientFailure.invalidPath);
            }
            File(part).renameSync(target);
          } finally {
            // Only this operation's unverified partial may be removed. Failed
            // retries cannot accumulate another full original on each attempt.
            if (FileSystemEntity.typeSync(part, followLinks: false) == FileSystemEntityType.file) {
              File(part).deleteSync();
            }
          }
        }
        files[entry.key] = 'objects/${scope.memberID}/${resource.sha256}';
      }
      _pause(shouldPause);
      // Revalidate the session before exposing a completed cached recovery.
      final finalCatalog = await loadCatalog(family, shouldPause: shouldPause);
      if (finalCatalog.fingerprint != pinnedCatalog.fingerprint) {
        _fail(FamilyArchiveClientFailure.conflict);
      }
      final archive = {'version': 1, 'familyID': family,
        'records': records.map((r) => r.toJson(FamilyArchiveScope(familyID: family,
            memberID: r.ownerMemberID, deviceID: r.writerDeviceID))).toList(),
        'anniversaries': dates.map((a) => a.toJson()).toList(),
        'snapshots': descriptors.map((d) => d.toJson()).toList(), 'resourceFiles': files,
        'manifestFiles': manifestFiles, 'catalogSha256': pinnedCatalog.fingerprint,
        'moderationVersion': pinnedCatalog.moderationVersion,
        'moderations': pinnedCatalog.moderations.map((event) => event.toJson()).toList(),
        'verifiedResourceCount': resources.length, 'verifiedByteCount': total};
      final archiveBytes = JsonWire.encode(archive);
      if (archiveBytes.length > _metadataLimit) _fail(FamilyArchiveClientFailure.integrity);
      _writeIdentical('$stage/family-restore.json', archiveBytes);
      _writeIdentical('$stage/RESTORE_COMPLETE.json', JsonWire.encode({'familyID': family,
        'archiveSha256': Digest.sha256Hex(archiveBytes),
        'catalogSha256': pinnedCatalog.fingerprint,
        'moderationVersion': pinnedCatalog.moderationVersion,
        'verifiedResourceCount': resources.length, 'verifiedByteCount': total}));
      final finalDirectory = '$parent/family-restore-${newUuid()}';
      if (FileSystemEntity.typeSync(finalDirectory, followLinks: false) != FileSystemEntityType.notFound) {
        _fail(FamilyArchiveClientFailure.invalidPath);
      }
      Directory(stage).renameSync(finalDirectory);
      return FamilyArchiveRestoreResult._(directory: finalDirectory, records: records,
        anniversaries: dates, verifiedResourceCount: resources.length, verifiedByteCount: total,
        manifestCount: manifests.length,
        catalog: pinnedCatalog,
        resourceFiles: {for (final entry in files.entries) entry.key: '$finalDirectory/${entry.value}'});
    } catch (error) {
      final failure = error is FamilyArchiveClientException ? error.failure :
          error is FileSystemException ? FamilyArchiveClientFailure.unavailable : FamilyArchiveClientFailure.integrity;
      throw FamilyArchiveClientException(failure, stageDirectory: stage);
    }
  }

  Future<FamilyArchiveResponse> _request(String method, String path, {List<int> body = const [],
    Map<String, String>? query, String? sourceFile, String? destinationFile,
    int? transferByteCount, String? digest, String contentType = 'application/json',
    bool allowNotFound = false, bool Function()? shouldPause}) async {
    try {
      _pause(shouldPause);
      final session = await _accessToken().timeout(timeout);
      if (session == null || session.isEmpty || session.length > 8192 ||
          !RegExp(r'^[A-Za-z0-9\-._~+/]+=*$').hasMatch(session)) _fail(FamilyArchiveClientFailure.unauthenticated);
      final response = await _transport.send(FamilyArchiveRequest(method: method,
        uri: origin.replace(path: path, queryParameters: query),
        headers: {'Authorization': 'Bearer $session', 'Content-Type': contentType,
          'Content-Length': '${sourceFile == null ? body.length : transferByteCount}',
          if (digest != null) 'X-Content-SHA256': digest},
        body: body, sourceFile: sourceFile, destinationFile: destinationFile,
        transferByteCount: transferByteCount, shouldPause: shouldPause)).timeout(timeout);
      _pause(shouldPause);
      if (response.body.length > _metadataLimit) _fail(FamilyArchiveClientFailure.invalidResponse);
      if (allowNotFound && response.statusCode == 404) return response;
      if (response.statusCode >= 200 && response.statusCode < 300) return response;
      if (response.statusCode == 401) _fail(FamilyArchiveClientFailure.unauthenticated);
      if (response.statusCode == 403) _fail(FamilyArchiveClientFailure.denied);
      if (response.statusCode == 409) _fail(FamilyArchiveClientFailure.conflict);
      if (response.statusCode >= 300 && response.statusCode < 400) _fail(FamilyArchiveClientFailure.invalidResponse);
      _fail(FamilyArchiveClientFailure.unavailable);
    } on FamilyArchiveClientException { rethrow; }
    on TimeoutException { _fail(FamilyArchiveClientFailure.timeout); }
    catch (_) { _fail(FamilyArchiveClientFailure.unavailable); }
  }
}

String _snapshotPath(FamilyArchiveSnapshot descriptor) => '/v1/families/${descriptor.scope.familyID}/members/'
    '${descriptor.scope.memberID}/devices/${descriptor.scope.deviceID}/snapshots/${descriptor.sequence}/${descriptor.sha256}';
String _mediaPath(FamilyArchiveScope scope, String digest) =>
    '/v1/families/${scope.familyID}/members/${scope.memberID}/objects/$digest';
bool _matches(FamilyArchiveResponse response, FamilyArchiveResource resource) =>
    response.headers['content-length'] == '${resource.byteCount}' && response.headers['x-content-sha256'] == resource.sha256;

Map<String, (FamilyArchiveScope, FamilyArchiveResource)> _resources(List<FamilyArchiveRecord> records, String family) {
  final result = <String, (FamilyArchiveScope, FamilyArchiveResource)>{};
  for (final record in records) {
    final scope = FamilyArchiveScope(familyID: family, memberID: record.ownerMemberID, deviceID: record.writerDeviceID);
    for (final asset in record.assets) {
      for (final resource in asset.resources) {
        final key = scope.objectKey(resource.sha256);
        if (result[key] != null && result[key]!.$2.byteCount != resource.byteCount) _fail(FamilyArchiveClientFailure.integrity);
        result[key] = (scope, resource);
      }
    }
  }
  return result;
}

List<FamilyArchiveAnniversary> _mergeDates(List<FamilyArchiveManifest> manifests) {
  final winners = <String, FamilyArchiveAnniversary>{};
  final revisions = <String, String>{};
  for (final manifest in manifests) {
    for (final item in manifest.anniversaries) {
      final key = '${item.ownerMemberID}:${item.id}';
      final revision = '$key:${item.revision}';
      final data = JsonWire.encodeString(item.toJson());
      if (revisions[revision] != null && revisions[revision] != data) _fail(FamilyArchiveClientFailure.integrity);
      revisions[revision] = data;
      if (winners[key] == null || winners[key]!.revision < item.revision) winners[key] = item;
    }
  }
  final keys = winners.keys.toList()..sort();
  return List.unmodifiable(keys.map((key) => winners[key]!));
}

Stream<List<int>> _chunks(Stream<List<int>> input, bool Function()? shouldPause, {int? maximum}) async* {
  var count = 0;
  await for (final chunk in input) {
    _pause(shouldPause);
    count += chunk.length;
    if (maximum != null && count > maximum) _fail(FamilyArchiveClientFailure.integrity);
    yield chunk;
  }
  _pause(shouldPause);
}

class _HashSink implements Sink<crypto.Digest> {
  late crypto.Digest value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}
Future<void> _verifyFile(String path, FamilyArchiveResource resource, bool Function()? pause) async {
  _safeRegular(path);
  final output = _HashSink();
  final sink = crypto.sha256.startChunkedConversion(output);
  var count = 0;
  await for (final chunk in _chunks(File(path).openRead(), pause, maximum: resource.byteCount)) {
    count += chunk.length;
    sink.add(chunk);
  }
  sink.close();
  _safeRegular(path);
  if (count != resource.byteCount || output.value.toString() != resource.sha256) _fail(FamilyArchiveClientFailure.integrity);
}

void _safeDirectory(String path, {bool create = false}) {
  final absolute = Directory(path).absolute.path;
  if (absolute.split(Platform.pathSeparator).contains('..')) _fail(FamilyArchiveClientFailure.invalidPath);
  final pieces = absolute.split(Platform.pathSeparator).where((p) => p.isNotEmpty);
  var current = Platform.pathSeparator;
  for (final piece in pieces) {
    current = '$current${current.endsWith(Platform.pathSeparator) ? '' : Platform.pathSeparator}$piece';
    final type = FileSystemEntity.typeSync(current, followLinks: false);
    // iOS supplies app-private paths under /var, a system alias for /private/var.
    // Accept only these two fixed OS aliases; user-controlled descendant links
    // remain forbidden and are never followed into an existing archive.
    if (type == FileSystemEntityType.link &&
        ((current == '/var' && Link(current).resolveSymbolicLinksSync() == '/private/var') ||
         (current == '/tmp' && Link(current).resolveSymbolicLinksSync() == '/private/tmp'))) {
      current = Link(current).resolveSymbolicLinksSync();
    } else if (type == FileSystemEntityType.notFound && create) Directory(current).createSync();
    else if (type != FileSystemEntityType.directory) _fail(FamilyArchiveClientFailure.invalidPath);
  }
}
void _safeRegular(String path) {
  _safeDirectory(File(path).absolute.parent.path);
  if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.file) _fail(FamilyArchiveClientFailure.invalidPath);
}
List<int> _readRegular(String path) {
  _safeRegular(path);
  final file = File(path);
  if (file.lengthSync() > _metadataLimit) _fail(FamilyArchiveClientFailure.integrity);
  return file.readAsBytesSync();
}
void _writeNew(String path, List<int> bytes) {
  _safeDirectory(File(path).absolute.parent.path);
  if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound) _fail(FamilyArchiveClientFailure.invalidPath);
  File(path).createSync(exclusive: true);
  File(path).writeAsBytesSync(bytes, flush: true);
}
void _writeIdentical(String path, List<int> bytes) {
  if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound) {
    _writeNew(path, bytes);
  } else if (Digest.sha256Hex(_readRegular(path)) != Digest.sha256Hex(bytes)) {
    _fail(FamilyArchiveClientFailure.integrity);
  }
}
void _replaceStageStatus(String stage, Map<String, Object?> status) {
  final temporary = '$stage/.status-${newUuid()}.tmp';
  _writeNew(temporary, JsonWire.encode(status));
  _safeRegular('$stage/STATUS.json');
  File(temporary).renameSync('$stage/STATUS.json');
}
Uri _origin(Uri value) {
  if (value.scheme != 'https' || value.host.isEmpty || value.userInfo.isNotEmpty || value.hasQuery ||
      value.hasFragment || value.path.isNotEmpty && value.path != '/') _fail(FamilyArchiveClientFailure.invalidPath);
  return Uri.parse(value.origin);
}
Object? _json(FamilyArchiveResponse response) {
  try { return JsonWire.parse(response.body, path: 'familyGateway'); }
  catch (_) { _fail(FamilyArchiveClientFailure.invalidResponse); }
}
Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) _fail(FamilyArchiveClientFailure.invalidResponse);
  return value;
}
String _string(Map<String, dynamic> value, String key) {
  final result = value[key];
  if (result is! String) _fail(FamilyArchiveClientFailure.invalidResponse);
  return result;
}
int _integer(Object? value) {
  if (value is! int) _fail(FamilyArchiveClientFailure.invalidResponse);
  return value;
}
int _boundedInteger(Object? value, {int minimum = 0, int maximum = 9007199254740991}) {
  final number = _integer(value);
  if (number < minimum || number > maximum) _fail(FamilyArchiveClientFailure.invalidResponse);
  return number;
}
String _canonicalID(Object? value) {
  if (value is! String) _fail(FamilyArchiveClientFailure.invalidResponse);
  final canonical = familyStableID(value);
  if (canonical != value) _fail(FamilyArchiveClientFailure.invalidResponse);
  return canonical;
}
void _pause(bool Function()? pause) { if (pause?.call() ?? false) _fail(FamilyArchiveClientFailure.paused); }
Never _fail(FamilyArchiveClientFailure failure) => throw FamilyArchiveClientException(failure);
