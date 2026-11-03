/// Versioned, isolated family archive contracts. These types validate data; they
/// do not authenticate callers, grant storage access, migrate files, or replace
/// the legacy life/v1 writer. Gateway record APIs and immutable archive export
/// remain separate until an authenticated export/import adapter is integrated.
library;

import 'dart:typed_data';

import 'anniversaries.dart';
import 'digest.dart';
import 'errors.dart';
import 'family.dart';
import 'json_wire.dart';
import 'storage_provider.dart';
import 'v1_json.dart';
import 'v1_layout.dart';
import 'v1_validator.dart';

const _maximumInteger = 9007199254740991;
const _maximumMetadata = 8 * 1024 * 1024;
final _hashPattern = RegExp(r'^[a-f0-9]{64}$');

Never _invalid(String field) =>
    throw ContractError('familyArchive.$field', 'Invalid family archive.');

/// All namespace components are canonical UUIDs, never names or relationships.
/// The media namespace matches the Family Gateway's scoped digest storage.
class FamilyArchiveScope {
  final String familyID;
  final String memberID;
  final String deviceID;
  FamilyArchiveScope({
    required String familyID,
    required String memberID,
    required String deviceID,
  }) : familyID = familyStableID(familyID),
       memberID = familyStableID(memberID),
       deviceID = familyStableID(deviceID);

  String get familyPrefix => 'family/v1/$familyID/';
  String get memberPrefix => '${familyPrefix}members/$memberID/';
  String get devicePrefix => '${memberPrefix}devices/$deviceID/';
  String objectKey(String sha256) {
    if (!_hashPattern.hasMatch(sha256)) _invalid('sha256');
    return '${memberPrefix}objects/$sha256';
  }

  String manifestKey({required int sequence, required String sha256}) {
    _positive(sequence, 'sequence');
    if (!_hashPattern.hasMatch(sha256)) _invalid('sha256');
    return '${devicePrefix}manifests/$sequence-$sha256.json';
  }

  @override
  bool operator ==(Object other) =>
      other is FamilyArchiveScope &&
      familyID == other.familyID &&
      memberID == other.memberID &&
      deviceID == other.deviceID;
  @override
  int get hashCode => Object.hash(familyID, memberID, deviceID);
}

class FamilyArchiveResource {
  final String id;
  final String role;
  final String contentType;
  final String originalFilename;
  final int byteCount;
  final String sha256;
  FamilyArchiveResource({
    required String id,
    required this.role,
    required this.contentType,
    required this.originalFilename,
    required this.byteCount,
    required this.sha256,
  }) : id = familyStableID(id) {
    if (!const {'photo', 'video', 'motionPhoto', 'livePhotoImage', 'livePhotoVideo', 'preview'}.contains(role) ||
        !_hashPattern.hasMatch(sha256) ||
        byteCount < 1 || byteCount > V1Validator.maxResourceBytes ||
        !V1Validator.validFilename(originalFilename) ||
        !V1Validator.validContentType(contentType, role)) {
      _invalid('resource');
    }
  }

  Map<String, Object?> toJson(FamilyArchiveScope scope) => {
    'id': id, 'role': role, 'contentType': contentType,
    'originalFilename': originalFilename, 'byteCount': byteCount,
    'sha256': sha256, 'objectKey': scope.objectKey(sha256),
  };
  factory FamilyArchiveResource.fromJson(Object? value, FamilyArchiveScope scope) {
    final data = _fields(value, {
      'id', 'role', 'contentType', 'originalFilename', 'byteCount', 'sha256', 'objectKey',
    });
    final result = FamilyArchiveResource(
      id: _string(data, 'id'), role: _string(data, 'role'),
      contentType: _string(data, 'contentType'),
      originalFilename: _string(data, 'originalFilename'),
      byteCount: _integer(data, 'byteCount'), sha256: _string(data, 'sha256'),
    );
    if (_string(data, 'objectKey') != scope.objectKey(result.sha256)) {
      _invalid('resource.objectKey');
    }
    return result;
  }
}

class FamilyArchiveAsset {
  final String id;
  final String kind;
  final int capturedAt;
  final List<FamilyArchiveResource> resources;
  FamilyArchiveAsset({
    required String id,
    required this.kind,
    required this.capturedAt,
    required List<FamilyArchiveResource> resources,
  }) : id = familyStableID(id),
       resources = List.unmodifiable([...resources]..sort((a, b) => a.id.compareTo(b.id))) {
    _timestamp(capturedAt, 'asset.capturedAt');
    final expected = switch (kind) {
      'photo' => {'photo', 'preview'},
      'video' => {'video', 'preview'},
      'motionPhoto' => {'motionPhoto', 'preview'},
      'livePhoto' => {'livePhotoImage', 'livePhotoVideo', 'preview'},
      _ => _invalid('asset.kind'),
    };
    final roles = resources.map((r) => r.role).toSet();
    if (resources.length != expected.length ||
        resources.map((r) => r.id).toSet().length != resources.length ||
        roles.length != expected.length || !roles.containsAll(expected)) {
      _invalid('asset.resources');
    }
  }
  Map<String, Object?> toJson(FamilyArchiveScope scope) => {
    'id': id, 'kind': kind, 'capturedAt': capturedAt,
    'resources': resources.map((r) => r.toJson(scope)).toList(),
  };
  factory FamilyArchiveAsset.fromJson(Object? value, FamilyArchiveScope scope) {
    final data = _fields(value, {'id', 'kind', 'capturedAt', 'resources'});
    return FamilyArchiveAsset(
      id: _string(data, 'id'), kind: _string(data, 'kind'),
      capturedAt: _integer(data, 'capturedAt'),
      resources: _list(data, 'resources', 3)
          .map((r) => FamilyArchiveResource.fromJson(r, scope)).toList(),
    );
  }
}

/// Ownership never changes through revision resolution. A shared-record deletion
/// is a tombstone; it is not permission to physically delete a media object.
class FamilyArchiveRecord {
  final String id;
  final String ownerMemberID;
  final String writerDeviceID;
  final int revision;
  final int occurredAt;
  final int updatedAt;
  final int? deletedAt;
  final String title;
  final String note;
  final List<FamilyArchiveAsset> assets;
  FamilyArchiveRecord({
    required String id,
    required String ownerMemberID,
    required String writerDeviceID,
    required this.revision,
    required this.occurredAt,
    required this.updatedAt,
    required this.title,
    required this.note,
    this.deletedAt,
    List<FamilyArchiveAsset> assets = const [],
  }) : id = familyStableID(id),
       ownerMemberID = familyStableID(ownerMemberID),
       writerDeviceID = familyStableID(writerDeviceID),
       assets = List.unmodifiable([...assets]..sort((a, b) => a.id.compareTo(b.id))) {
    _positive(revision, 'record.revision');
    _timestamp(occurredAt, 'record.occurredAt');
    _timestamp(updatedAt, 'record.updatedAt');
    if (deletedAt != null) _timestamp(deletedAt!, 'record.deletedAt');
    if (title.length > 200 || note.length > 10000 || assets.length > 30 ||
        assets.map((a) => a.id).toSet().length != assets.length ||
        (deletedAt == null && assets.isEmpty && title.trim().isEmpty && note.trim().isEmpty)) {
      _invalid('record');
    }
  }
  Map<String, Object?> toJson(FamilyArchiveScope scope) => {
    'id': id, 'ownerMemberID': ownerMemberID, 'writerDeviceID': writerDeviceID,
    'revision': revision, 'occurredAt': occurredAt, 'updatedAt': updatedAt,
    'deletedAt': deletedAt, 'title': title, 'note': note,
    'assets': assets.map((a) => a.toJson(scope)).toList(),
  };
  factory FamilyArchiveRecord.fromJson(Object? value, FamilyArchiveScope scope) {
    final data = _fields(value, {
      'id', 'ownerMemberID', 'writerDeviceID', 'revision', 'occurredAt',
      'updatedAt', 'deletedAt', 'title', 'note', 'assets',
    });
    final result = FamilyArchiveRecord(
      id: _string(data, 'id'), ownerMemberID: _string(data, 'ownerMemberID'),
      writerDeviceID: _string(data, 'writerDeviceID'),
      revision: _integer(data, 'revision'), occurredAt: _integer(data, 'occurredAt'),
      updatedAt: _integer(data, 'updatedAt'), deletedAt: _optionalInteger(data, 'deletedAt'),
      title: _string(data, 'title'), note: _string(data, 'note'),
      assets: _list(data, 'assets', 30)
          .map((a) => FamilyArchiveAsset.fromJson(a, scope)).toList(),
    );
    if (result.ownerMemberID != scope.memberID) _invalid('record.ownerMemberID');
    return result;
  }
}

class FamilyArchiveAnniversary {
  final String id;
  final String ownerMemberID;
  final String title;
  final String date;
  final int revision;
  final int? deletedAt;
  FamilyArchiveAnniversary({
    required String id, required String ownerMemberID, required this.title,
    required String date, required this.revision, this.deletedAt,
  }) : id = familyStableID(id), ownerMemberID = familyStableID(ownerMemberID),
       date = AnniversaryCalendar.normalizedDate(date) {
    _positive(revision, 'anniversary.revision');
    if (title.trim().isEmpty || title.length > 100) _invalid('anniversary.title');
    if (deletedAt != null) _timestamp(deletedAt!, 'anniversary.deletedAt');
  }
  Map<String, Object?> toJson() => {
    'id': id, 'ownerMemberID': ownerMemberID, 'title': title, 'date': date,
    'revision': revision, 'deletedAt': deletedAt,
  };
  factory FamilyArchiveAnniversary.fromJson(Object? value) {
    final data = _fields(value, {'id', 'ownerMemberID', 'title', 'date', 'revision', 'deletedAt'});
    return FamilyArchiveAnniversary(
      id: _string(data, 'id'), ownerMemberID: _string(data, 'ownerMemberID'),
      title: _string(data, 'title'), date: _string(data, 'date'),
      revision: _integer(data, 'revision'), deletedAt: _optionalInteger(data, 'deletedAt'),
    );
  }
}

class FamilyArchiveManifest {
  static const version = 1;
  final FamilyArchiveScope scope;
  final int sequence;
  final String? parentHash;
  final List<FamilyArchiveRecord> records;
  final List<FamilyArchiveAnniversary> anniversaries;
  FamilyArchiveManifest({
    required this.scope, required this.sequence, this.parentHash,
    required List<FamilyArchiveRecord> records,
    List<FamilyArchiveAnniversary> anniversaries = const [],
  }) : records = List.unmodifiable([...records]..sort((a, b) => a.id.compareTo(b.id))),
       anniversaries = List.unmodifiable([...anniversaries]..sort((a, b) => a.id.compareTo(b.id))) {
    _positive(sequence, 'sequence');
    if ((sequence == 1) != (parentHash == null) ||
        parentHash != null && !_hashPattern.hasMatch(parentHash!) ||
        records.length > 10000 || anniversaries.length > 10000 ||
        records.map((r) => r.id).toSet().length != records.length ||
        anniversaries.map((a) => a.id).toSet().length != anniversaries.length ||
        records.any((r) => r.ownerMemberID != scope.memberID) ||
        anniversaries.any((a) => a.ownerMemberID != scope.memberID)) {
      _invalid('manifest');
    }
    // Stable media IDs cannot refer to different bytes anywhere in a snapshot.
    final resources = <String, String>{};
    final assets = <String, String>{};
    final objectSizes = <String, int>{};
    for (final record in records) {
      for (final asset in record.assets) {
        final assetFingerprint = JsonWire.encodeString(asset.toJson(scope));
        if (assets[asset.id] != null && assets[asset.id] != assetFingerprint) {
          _invalid('asset.id');
        }
        assets[asset.id] = assetFingerprint;
        for (final resource in asset.resources) {
          final expectedSize = objectSizes[resource.sha256];
          if (expectedSize != null && expectedSize != resource.byteCount) {
            _invalid('resource.byteCount');
          }
          objectSizes[resource.sha256] = resource.byteCount;
          final fingerprint = JsonWire.encodeString(resource.toJson(scope));
          final previous = resources[resource.id];
          if (previous != null && previous != fingerprint) _invalid('resource.id');
          resources[resource.id] = fingerprint;
        }
      }
    }
  }
  Map<String, Object?> toJson() => {
    'version': version, 'familyID': scope.familyID, 'memberID': scope.memberID,
    'deviceID': scope.deviceID, 'sequence': sequence, 'parentHash': parentHash,
    'records': records.map((r) => r.toJson(scope)).toList(),
    'anniversaries': anniversaries.map((a) => a.toJson()).toList(),
  };
  Uint8List encode() {
    final bytes = JsonWire.encode(toJson());
    if (bytes.length > _maximumMetadata) _invalid('size');
    return bytes;
  }
  String get sha256 => Digest.sha256Hex(encode());
  String get objectKey => scope.manifestKey(sequence: sequence, sha256: sha256);

  /// Expected scope comes from an authenticated, user-selected destination.
  /// An archive's own claimed family/member is never its authorization proof.
  static FamilyArchiveManifest decode(List<int> bytes, {required FamilyArchiveScope expectedScope}) {
    if (bytes.length > _maximumMetadata) _invalid('size');
    final data = _fields(JsonWire.parse(bytes, path: 'familyArchive'), {
      'version', 'familyID', 'memberID', 'deviceID', 'sequence', 'parentHash',
      'records', 'anniversaries',
    });
    if (_integer(data, 'version') != version) _invalid('version');
    final scope = FamilyArchiveScope(
      familyID: _string(data, 'familyID'), memberID: _string(data, 'memberID'),
      deviceID: _string(data, 'deviceID'),
    );
    if (scope != expectedScope) _invalid('scope');
    final parent = data['parentHash'];
    if (parent != null && parent is! String) _invalid('parentHash');
    return FamilyArchiveManifest(
      scope: scope, sequence: _integer(data, 'sequence'), parentHash: parent as String?,
      records: _list(data, 'records', 10000)
          .map((r) => FamilyArchiveRecord.fromJson(r, scope)).toList(),
      anniversaries: _list(data, 'anniversaries', 10000)
          .map(FamilyArchiveAnniversary.fromJson).toList(),
    );
  }

  /// A per-device snapshot chain must be contiguous and immutable.
  void validateSuccessor(FamilyArchiveManifest? previous) {
    if (previous == null) {
      if (sequence != 1 || parentHash != null) _invalid('chain');
    } else if (scope != previous.scope || sequence != previous.sequence + 1 ||
        parentHash != previous.sha256) {
      _invalid('chain');
    } else {
      final nextRecords = {for (final record in records) record.id: record};
      for (final record in previous.records) {
        final next = nextRecords[record.id];
        if (next == null || next.revision < record.revision) _invalid('chain.records');
      }
      // An equal revision is immutable even when a later sequence has a
      // different device state. Deletions must remain explicit tombstones.
      mergeFamilyArchiveRecords([previous, this], familyID: scope.familyID);
      final nextDates = {for (final item in anniversaries) item.id: item};
      for (final item in previous.anniversaries) {
        final next = nextDates[item.id];
        if (next == null || next.revision < item.revision ||
            next.revision == item.revision &&
                JsonWire.encodeString(next.toJson()) != JsonWire.encodeString(item.toJson())) {
          _invalid('chain.anniversaries');
        }
      }
    }
  }
}

/// Deterministic conflict resolution keeps each member's stable record namespace.
/// An equal revision with unequal bytes is a conflict requiring review; it never
/// silently picks a device or overwrites someone else's record.
List<FamilyArchiveRecord> mergeFamilyArchiveRecords(
  List<FamilyArchiveManifest> manifests, {required String familyID},
) {
  final expected = familyStableID(familyID);
  final winners = <String, (FamilyArchiveRecord, String)>{};
  final revisions = <String, String>{};
  for (final manifest in manifests) {
    if (manifest.scope.familyID != expected) _invalid('scope');
    for (final record in manifest.records) {
      final key = '${record.ownerMemberID}:${record.id}';
      final digest = Digest.sha256Hex(JsonWire.encode(record.toJson(manifest.scope)));
      final revisionKey = '$key:${record.revision}';
      if (revisions[revisionKey] != null && revisions[revisionKey] != digest) {
        _invalid('revisionConflict');
      }
      revisions[revisionKey] = digest;
      final previous = winners[key];
      if (previous == null || previous.$1.revision < record.revision) {
        winners[key] = (record, digest);
      }
    }
  }
  final keys = winners.keys.toList()..sort();
  return List.unmodifiable(keys.map((key) => winners[key]!.$1));
}

class FamilyLegacyObjectCopy {
  final String sourceKey;
  final String destinationKey;
  final String sha256;
  final int byteCount;
  const FamilyLegacyObjectCopy._(this.sourceKey, this.destinationKey, this.sha256, this.byteCount);
}

/// A reviewable copy plan only. It performs no writes, credential transfer,
/// ownership grant, activation, deletion, or destructive in-place migration.
class FamilyLegacyCopyPlan {
  final StorageIdentity sourceStorage;
  final String sourceManifestHash;
  final FamilyArchiveScope destination;
  final List<FamilyLegacyObjectCopy> objects;
  final Map<String, String> recordOwners;
  final List<String> anniversaryIDs;
  FamilyLegacyCopyPlan._(this.sourceStorage, this.sourceManifestHash,
      this.destination, this.objects, this.recordOwners, this.anniversaryIDs);

  static FamilyLegacyCopyPlan inspect({
    required StorageIdentity sourceStorage, required ParentIdentity sourceOwner,
    required List<int> sourceManifestBytes, required String sourceManifestHash,
    required FamilyArchiveScope destination,
  }) {
    if (sourceManifestBytes.length > _maximumMetadata ||
        !_hashPattern.hasMatch(sourceManifestHash) ||
        Digest.sha256Hex(sourceManifestBytes) != sourceManifestHash ||
        !V1Layout.owns(owner: sourceOwner, prefix: sourceStorage.prefix) ||
        !sourceStorage.prefix.startsWith('life/v1/')) {
      _invalid('legacySource');
    }
    final legacy = V1Json.decodeManifest(sourceManifestBytes);
    V1Validator.validate(manifest: legacy, prefix: sourceStorage.prefix);
    final copies = <String, FamilyLegacyObjectCopy>{};
    for (final resource in legacy.resources) {
      copies[resource.objectKey] = FamilyLegacyObjectCopy._(
        resource.objectKey, destination.objectKey(resource.sha256),
        resource.sha256, resource.byteCount,
      );
    }
    return FamilyLegacyCopyPlan._(
      sourceStorage, sourceManifestHash, destination,
      List.unmodifiable(copies.values),
      Map.unmodifiable({for (final record in legacy.moments) record.id: destination.memberID}),
      List.unmodifiable(legacy.anniversaries.map((a) => a.id)),
    );
  }

  bool get mayActivateAutomatically => false;
  bool get mayDeleteSource => false;
  List<String> get requiredSteps => const [
    'Authenticate and explicitly approve the legacy-owner to family-member mapping.',
    'Copy every original and preview into the separate destination namespace.',
    'Independently verify all copied hashes, sizes, records and anniversaries.',
    'Review conflicts and explicitly activate the copied namespace only after verification.',
    'Keep the original life/v1 source and connection available for rollback.',
  ];
}

Map<String, dynamic> _fields(Object? value, Set<String> expected) {
  if (value is! Map<String, dynamic> || value.length != expected.length ||
      value.keys.any((key) => !expected.contains(key))) _invalid('fields');
  return value;
}
String _string(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is! String) _invalid(key);
  return value;
}
int _integer(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is! int || value < 0 || value > _maximumInteger) _invalid(key);
  return value;
}
int? _optionalInteger(Map<String, dynamic> data, String key) =>
    data[key] == null ? null : _integer(data, key);
List<dynamic> _list(Map<String, dynamic> data, String key, int maximum) {
  final value = data[key];
  if (value is! List || value.length > maximum) _invalid(key);
  return value;
}
void _positive(int value, String key) {
  if (value < 1 || value > _maximumInteger) _invalid(key);
}
void _timestamp(int value, String key) {
  if (value < 0 || value > V1Validator.maxTimestamp) _invalid(key);
}
