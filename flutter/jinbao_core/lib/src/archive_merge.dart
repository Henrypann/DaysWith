import 'package:collection/collection.dart';

import 'anniversaries.dart';
import 'cos_client.dart';
import 'digest.dart';
import 'errors.dart';
import 'json_codec.dart';
import 'text.dart';
import 'v1_json.dart';
import 'v1_layout.dart';
import 'v1_model.dart';
import 'v1_validator.dart';

const _deep = DeepCollectionEquality();

class ChainSnapshot {
  final ParentIdentity parent;
  final String prefix;
  final String writer;
  final int createdAt;
  final V1Manifest manifest;

  const ChainSnapshot(
      {required this.parent, required this.prefix, required this.writer, required this.createdAt, required this.manifest});
}

bool _validChain(ParentIdentity parent, String chainPrefix) {
  final root = parent.prefix;
  if (!chainPrefix.startsWith(root)) return false;
  final suffix = chainPrefix.substring(root.length);
  return suffix.isEmpty ||
      (suffix.endsWith('/') && V1Layout.isDeviceSegment(suffix.substring(0, suffix.length - 1)));
}

/// A bounded image reference derived from a validated family manifest, never an arbitrary URL.
class RemotePreview {
  static const maximumBytes = 8 * 1024 * 1024;
  static const _imageTypes = ['image/jpeg', 'image/png', 'image/heic', 'image/heif', 'image/webp', 'image/gif'];

  final String assetID;
  final ParentIdentity parent;
  final String chainPrefix;
  final String objectKey;
  final String sha256;
  final int byteCount;
  final String contentType;

  const RemotePreview({
    required this.assetID,
    required this.parent,
    required this.chainPrefix,
    required this.objectKey,
    required this.sha256,
    required this.byteCount,
    required this.contentType,
  });

  String get id => '${parent.folder}:$sha256';

  void validate() {
    final ok = _validChain(parent, chainPrefix) &&
        sha256Pattern.hasMatch(sha256) &&
        objectKey == V1Layout.objectKey(prefix: chainPrefix, sha256: sha256) &&
        byteCount >= 1 &&
        byteCount <= maximumBytes &&
        _imageTypes.contains(contentType);
    if (!ok) throw const CosFailure(ConnectionFailure.contentMismatch);
  }

  void validateData(List<int> data) {
    validate();
    if (data.length != byteCount || Digest.sha256Hex(data) != sha256) {
      throw const CosFailure(ConnectionFailure.contentMismatch);
    }
  }

  bool get isValid {
    try {
      validate();
      return true;
    } on CosFailure {
      return false;
    }
  }

  factory RemotePreview.fromJson(Object? json) {
    final v = JsonFields(json, 'preview');
    return RemotePreview(
      assetID: v.string('assetID'),
      parent: v.parent('parent'),
      chainPrefix: v.string('chainPrefix'),
      objectKey: v.string('objectKey'),
      sha256: v.string('sha256'),
      byteCount: v.integer('byteCount'),
      contentType: v.string('contentType'),
    );
  }

  Map<String, Object?> toJson() => {
        'assetID': assetID,
        'parent': parent.folder,
        'chainPrefix': chainPrefix,
        'objectKey': objectKey,
        'sha256': sha256,
        'byteCount': byteCount,
        'contentType': contentType,
      };

  @override
  bool operator ==(Object other) => other is RemotePreview && _deep.equals(toJson(), other.toJson());

  @override
  int get hashCode => _deep.hash(toJson());
}

/// Original reference from a validated family chain; only dad/mom immutable object roots are accepted.
class RemoteResource {
  static const maximumBytes = 2147483648;
  static const _roles = ['photo', 'video', 'livePhotoImage', 'livePhotoVideo', 'motionPhoto', 'preview'];

  final String id;
  final String assetID;
  final String role;
  final ParentIdentity parent;
  final String chainPrefix;
  final String objectKey;
  final String sha256;
  final int byteCount;
  final String contentType;
  final String originalFilename;

  const RemoteResource({
    required this.id,
    required this.assetID,
    required this.role,
    required this.parent,
    required this.chainPrefix,
    required this.objectKey,
    required this.sha256,
    required this.byteCount,
    required this.contentType,
    required this.originalFilename,
  });

  void validate() {
    final ok = _validChain(parent, chainPrefix) &&
        _roles.contains(role) &&
        sha256Pattern.hasMatch(sha256) &&
        objectKey == V1Layout.objectKey(prefix: chainPrefix, sha256: sha256) &&
        byteCount >= 1 &&
        byteCount <= maximumBytes &&
        V1Validator.validContentType(contentType, role) &&
        V1Validator.validFilename(originalFilename);
    if (!ok) throw const CosFailure(ConnectionFailure.contentMismatch);
  }

  void validateData(List<int> data) {
    validate();
    if (data.length != byteCount || Digest.sha256Hex(data) != sha256) {
      throw const CosFailure(ConnectionFailure.contentMismatch);
    }
  }

  bool get isValid {
    try {
      validate();
      return true;
    } on CosFailure {
      return false;
    }
  }

  factory RemoteResource.fromJson(Object? json) {
    final v = JsonFields(json, 'remoteResource');
    return RemoteResource(
      id: v.string('id'),
      assetID: v.string('assetID'),
      role: v.string('role'),
      parent: v.parent('parent'),
      chainPrefix: v.string('chainPrefix'),
      objectKey: v.string('objectKey'),
      sha256: v.string('sha256'),
      byteCount: v.integer('byteCount'),
      contentType: v.string('contentType'),
      originalFilename: v.string('originalFilename'),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'assetID': assetID,
        'role': role,
        'parent': parent.folder,
        'chainPrefix': chainPrefix,
        'objectKey': objectKey,
        'sha256': sha256,
        'byteCount': byteCount,
        'contentType': contentType,
        'originalFilename': originalFilename,
      };

  @override
  bool operator ==(Object other) => other is RemoteResource && _deep.equals(toJson(), other.toJson());

  @override
  int get hashCode => _deep.hash(toJson());
}

class RemoteMedia {
  final String id;
  final String kind;
  final int capturedAt;
  final List<RemoteResource> resources;

  const RemoteMedia({required this.id, required this.kind, required this.capturedAt, required this.resources});

  factory RemoteMedia.fromJson(Object? json) {
    final v = JsonFields(json, 'remoteMedia');
    return RemoteMedia(
      id: v.string('id'),
      kind: v.string('kind'),
      capturedAt: v.integer('capturedAt'),
      resources: v.list('resources').map(RemoteResource.fromJson).toList(),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind,
        'capturedAt': capturedAt,
        'resources': resources.map((r) => r.toJson()).toList(),
      };

  @override
  bool operator ==(Object other) => other is RemoteMedia && _deep.equals(toJson(), other.toJson());

  @override
  int get hashCode => _deep.hash(toJson());
}

class RemoteMoment {
  final String id;
  final ParentIdentity parent;
  final String title;
  final String note;
  final int occurredAt;
  final bool readOnly;
  final int mediaCount;
  final String? previewObjectKey;
  final String? localPreviewPath;
  final List<RemotePreview> previews;
  final List<RemoteMedia> media;

  const RemoteMoment({
    required this.id,
    required this.parent,
    required this.title,
    required this.note,
    required this.occurredAt,
    this.readOnly = true,
    this.mediaCount = 0,
    this.previewObjectKey,
    this.localPreviewPath,
    this.previews = const [],
    this.media = const [],
  });

  /// Persisted copies are re-validated: older archives may hold bare object keys.
  factory RemoteMoment.fromJson(Object? json) {
    final v = JsonFields(json, 'remoteMoment');
    final parent = v.parent('parent');
    List<RemotePreview> previews;
    try {
      previews = (v.list('previews')).map(RemotePreview.fromJson).toList();
    } on ContractError {
      previews = [];
    }
    final media = (v.optionalList('media') ?? const []).map(RemoteMedia.fromJson).toList();
    return RemoteMoment(
      id: v.string('id'),
      parent: parent,
      title: v.string('title'),
      note: v.string('note'),
      occurredAt: v.integer('occurredAt'),
      readOnly: true,
      mediaCount: v.optionalInt('mediaCount') ?? 0,
      previewObjectKey: v.optionalString('previewObjectKey'),
      localPreviewPath: v.optionalString('localPreviewPath'),
      previews: previews.where((p) => p.parent == parent && p.isValid).toList(),
      media: media.where((m) => m.resources.every((r) => r.parent == parent && r.isValid)).toList(),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'parent': parent.folder,
        'title': title,
        'note': note,
        'occurredAt': occurredAt,
        'readOnly': readOnly,
        'mediaCount': mediaCount,
        if (previewObjectKey != null) 'previewObjectKey': previewObjectKey,
        if (localPreviewPath != null) 'localPreviewPath': localPreviewPath,
        'previews': previews.map((p) => p.toJson()).toList(),
        'media': media.map((m) => m.toJson()).toList(),
      };

  @override
  bool operator ==(Object other) => other is RemoteMoment && _deep.equals(toJson(), other.toJson());

  @override
  int get hashCode => _deep.hash(toJson());
}

class _Copy {
  final ParentIdentity parent;
  final V1Moment moment;
  final V1Manifest manifest;
  final String prefix;
  const _Copy(this.parent, this.moment, this.manifest, this.prefix);
}

/// Read-side merge. Newest edit wins. A newer deletion hides the older copy. Nothing here writes or deletes.
abstract final class ArchiveMerge {
  static List<RemoteMoment> merge(List<ChainSnapshot> sources) {
    final grouped = <String, List<_Copy>>{};
    for (final source in sources) {
      for (final moment in source.manifest.moments) {
        grouped
            .putIfAbsent('${source.parent.folder}:${moment.id.toUpperCase()}', () => [])
            .add(_Copy(source.parent, moment, source.manifest, source.prefix));
      }
    }
    bool increasing(_Copy lhs, _Copy rhs) {
      if (lhs.moment.updatedAt != rhs.moment.updatedAt) return lhs.moment.updatedAt < rhs.moment.updatedAt;
      if (lhs.moment.revision != rhs.moment.revision) return lhs.moment.revision < rhs.moment.revision;
      return lhs.moment.trashedAt == null && rhs.moment.trashedAt != null;
    }

    final hidden = <String>{};
    final winners = <_Copy>[];
    for (final group in grouped.values) {
      var best = group.first;
      for (final copy in group.skip(1)) {
        if (increasing(best, copy)) best = copy;
      }
      if (best.moment.trashedAt != null) {
        hidden.add(remoteID(best.parent, best.moment.id));
      } else {
        winners.add(best);
      }
    }
    final result = <RemoteMoment>[];
    for (final copy in winners) {
      final id = remoteID(copy.parent, copy.moment.id);
      if (hidden.contains(id) || copy.moment.trashedAt != null) continue;
      final resources = copy.manifest.resources;
      V1Asset? assetFor(String assetID) =>
          copy.manifest.assets.firstWhereOrNull((a) => a.id.toUpperCase() == assetID.toUpperCase());
      final previews = <RemotePreview>[];
      for (final assetID in copy.moment.assetIDs) {
        final asset = assetFor(assetID);
        if (asset == null) continue;
        final resource = resources.firstWhereOrNull((r) =>
            r.assetID.toUpperCase() == assetID.toUpperCase() &&
            r.role == 'preview' &&
            asset.resourceIDs.map((id) => id.toUpperCase()).contains(r.id.toUpperCase()));
        if (resource == null) continue;
        final reference = RemotePreview(
            assetID: assetID,
            parent: copy.parent,
            chainPrefix: copy.prefix,
            objectKey: resource.objectKey,
            sha256: resource.sha256,
            byteCount: resource.byteCount,
            contentType: resource.contentType);
        if (reference.isValid) previews.add(reference);
      }
      final media = <RemoteMedia>[];
      for (final assetID in copy.moment.assetIDs) {
        final asset = assetFor(assetID);
        if (asset == null) continue;
        final originals = <RemoteResource>[];
        for (final resourceID in asset.resourceIDs) {
          final r = resources.firstWhereOrNull((r) =>
              r.id.toUpperCase() == resourceID.toUpperCase() && r.assetID.toUpperCase() == assetID.toUpperCase());
          if (r == null) continue;
          final reference = RemoteResource(
              id: r.id,
              assetID: assetID,
              role: r.role,
              parent: copy.parent,
              chainPrefix: copy.prefix,
              objectKey: r.objectKey,
              sha256: r.sha256,
              byteCount: r.byteCount,
              contentType: r.contentType,
              originalFilename: r.originalFilename);
          if (reference.isValid) originals.add(reference);
        }
        media.add(RemoteMedia(id: assetID, kind: asset.kind, capturedAt: asset.capturedAt, resources: originals));
      }
      result.add(RemoteMoment(
        id: id,
        parent: copy.parent,
        title: copy.moment.title,
        note: copy.moment.note,
        occurredAt: copy.moment.occurredAt,
        mediaCount: copy.moment.assetIDs.length,
        previewObjectKey: previews.firstOrNull?.objectKey,
        previews: previews,
        media: media,
      ));
    }
    return result;
  }

  static List<RemoteAnniversary> mergeAnniversaries(List<ChainSnapshot> sources) {
    final winners = <String, RemoteAnniversary>{};
    final sorted = [...sources]..sort((a, b) => a.prefix.compareTo(b.prefix));
    for (final source in sorted) {
      for (final item in source.manifest.anniversaries) {
        if (item.owner != source.parent) continue;
        try {
          AnniversaryCalendar.normalizedDate(item.date);
        } on ContractError {
          continue;
        }
        final candidate = RemoteAnniversary(
            recordID: item.id,
            owner: item.owner,
            title: item.title,
            date: item.date,
            deletedAt: item.deletedAt,
            sourcePrefix: source.prefix,
            updatedAt: source.createdAt);
        final key = '${item.owner.folder}:${item.id.toUpperCase()}';
        final existing = winners[key];
        if (existing != null && existing.updatedAt > candidate.updatedAt) continue;
        if (existing != null &&
            existing.updatedAt == candidate.updatedAt &&
            existing.deletedAt != null &&
            candidate.deletedAt == null) {
          continue;
        }
        winners[key] = candidate;
      }
    }
    // Keep tombstones to suppress virtual built-ins as well as stale remote copies.
    final keys = winners.keys.toList()..sort();
    return [for (final key in keys) winners[key]!];
  }

  static String remoteID(ParentIdentity parent, String momentID) =>
      'remote:${parent.folder}:record:${momentID.toUpperCase()}';
}

class CommitReceipt {
  final V1Commit commit;
  final String commitHash;
  final V1Manifest manifest;
  const CommitReceipt({required this.commit, required this.commitHash, required this.manifest});
}

class FamilyArchive {
  final List<RemoteMoment> moments;
  final List<RemoteAnniversary> anniversaries;
  const FamilyArchive({required this.moments, required this.anniversaries});
}

abstract final class FamilyReader {
  /// Lists dad and mom only. Legacy roots stay read-only. This device's own chain is skipped.
  /// `life/v1/test/` is not part of the family read.
  static Future<List<RemoteMoment>> read(CosClient client,
          {required ParentIdentity owner, required String deviceID, required bool testBuild}) async =>
      (await readArchive(client, owner: owner, deviceID: deviceID, testBuild: testBuild)).moments;

  static Future<FamilyArchive> readArchive(CosClient client,
      {required ParentIdentity owner, required String deviceID, required bool testBuild}) async {
    if (client.configuration.prefix != 'life/v1/') throw const CosFailure(ConnectionFailure.configuration);
    final sources = <ChainSnapshot>[];
    for (final parent in [owner.other, owner]) {
      final root = parent.prefix;
      final keys = await client.list(prefix: root);
      final chains = V1Layout.chainsUnder(root: root, keys: keys);
      final own = (parent == owner && !testBuild)
          ? V1Layout.chainPrefix(parent: owner, deviceID: deviceID, test: false)
          : null;
      for (final chain in chains) {
        if (own != null && chain == own) continue;
        final receipt = await latest(client, chain);
        if (receipt == null) continue;
        if (parent == owner && receipt.commit.writerDeviceID.toUpperCase() == deviceID.toUpperCase()) continue;
        sources.add(ChainSnapshot(
          parent: parent,
          prefix: chain,
          writer: receipt.commit.writerDeviceID,
          createdAt: receipt.commit.createdAt,
          manifest: receipt.manifest,
        ));
      }
    }
    return FamilyArchive(moments: ArchiveMerge.merge(sources), anniversaries: ArchiveMerge.mergeAnniversaries(sources));
  }

  static Future<CommitReceipt?> latest(CosClient client, String prefix) async {
    final keys = (await client.list(prefix: '${prefix}commits/'))..sort();
    V1Commit? previous;
    String? previousHash;
    for (final key in keys) {
      final bytes = await client.get(key: key);
      final commit = V1Json.decodeCommit(bytes);
      V1Validator.validateCommit(
          commit: commit, key: key, prefix: prefix, previous: previous, previousHash: previousHash);
      previous = commit;
      previousHash = Digest.sha256Hex(bytes);
    }
    if (previous == null || previousHash == null) return null;
    final manifestBytes = await client.get(key: previous.manifestKey);
    if (Digest.sha256Hex(manifestBytes) != previous.manifestHash) {
      throw ContractError('commits[${previous.sequence}].manifestHash', 'The file does not match its saved hash.');
    }
    final manifest = V1Json.decodeManifest(manifestBytes);
    V1Validator.validate(manifest: manifest, prefix: prefix);
    return CommitReceipt(commit: previous, commitHash: previousHash, manifest: manifest);
  }
}
