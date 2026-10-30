import 'anniversaries.dart';
import 'errors.dart';
import 'text.dart';
import 'v1_ids.dart';
import 'v1_json.dart';
import 'v1_layout.dart';
import 'v1_model.dart';

abstract final class V1Validator {
  static const maxTimestamp = 8640000000000000;
  static const maxRevision = 9007199254740991;
  static const maxResourceBytes = 2147483648;

  static void validate({required V1Manifest manifest, required String prefix}) {
    V1Layout.validatePrefix(prefix);
    if (manifest.version < 1 || manifest.version > 2) {
      throw const ContractError('manifest.version', 'This archive needs a newer app version.');
    }
    if (manifest.version != 2 && manifest.anniversaries.isNotEmpty) {
      throw const ContractError('manifest.anniversaries', 'Anniversaries require version 2.');
    }
    _identities('anniversaries', manifest.anniversaries.map((a) => a.id));
    for (final anniversary in manifest.anniversaries) {
      final entity = 'anniversaries[${anniversary.id}]';
      if (!V1Layout.owns(owner: anniversary.owner, prefix: prefix)) {
        throw ContractError('$entity.owner', 'Anniversary belongs to another parent.');
      }
      AnniversaryCalendar.normalizedDate(anniversary.date);
      if (anniversary.deletedAt != null) _timestamp(anniversary.deletedAt!, '$entity.deletedAt');
      if (swiftTrim(anniversary.title).isEmpty || utf16Length(anniversary.title) > 100) {
        throw ContractError('$entity.title', 'Invalid anniversary title.');
      }
    }
    _identities('moments', manifest.moments.map((m) => m.id));
    _identities('assets', manifest.assets.map((a) => a.id));
    _identities('resources', manifest.resources.map((r) => r.id));
    manifest.moments.forEach(_validateMoment);
    final assets = {for (final asset in manifest.assets) asset.id.toUpperCase(): asset};
    final used = <String>{};
    for (final moment in manifest.moments) {
      final entity = 'moments[${moment.id}]';
      for (final id in moment.assetIDs) {
        if (!assets.containsKey(id.toUpperCase())) {
          throw ContractError('$entity.assetIDs', 'A selected media item is missing: $id.');
        }
        used.add(id.toUpperCase());
      }
    }
    for (final orphan in assets.keys) {
      if (!used.contains(orphan)) throw ContractError('assets[$orphan].id', 'Archive contains unreferenced media.');
    }
    for (final resource in manifest.resources) {
      if (!used.contains(resource.assetID.toUpperCase())) {
        throw ContractError('resources[${resource.id}].assetID', 'Archive contains missing or unreferenced media.');
      }
    }
    final grouped = <String, List<V1Resource>>{};
    for (final resource in manifest.resources) {
      grouped.putIfAbsent(resource.assetID.toUpperCase(), () => []).add(resource);
    }
    for (final asset in manifest.assets) {
      _validateAsset(asset, grouped[asset.id.toUpperCase()] ?? const []);
    }
    final seen = <String, V1Resource>{};
    for (final resource in manifest.resources) {
      final entity = 'resources[${resource.id}]';
      if (resource.objectKey != V1Layout.objectKey(prefix: prefix, sha256: resource.sha256)) {
        throw ContractError('$entity.objectKey', 'Archive contains an invalid object reference.');
      }
      final first = seen[resource.objectKey];
      if (first != null && (first.byteCount != resource.byteCount || first.sha256 != resource.sha256)) {
        throw ContractError('$entity.objectKey', 'The file does not match its saved hash or byteCount.');
      }
      seen[resource.objectKey] = resource;
    }
  }

  static void validateCommit({
    required V1Commit commit,
    required String key,
    required String prefix,
    required V1Commit? previous,
    required String? previousHash,
  }) {
    V1Layout.validatePrefix(prefix);
    final entity = 'commits[${commit.sequence}]';
    ContractError chain(String field) => ContractError('$entity.$field', 'The archive commit chain is incomplete or invalid.');
    if (commit.version != 1) throw chain('version');
    final expected = (previous?.sequence ?? 0) + 1;
    if (commit.sequence <= 0 || commit.sequence != expected) throw chain('sequence');
    if (key != prefix + V1Json.commitRelativeKey(commit.sequence)) throw chain('key');
    if ((previous == null) != (previousHash == null) || commit.parentHash != previousHash) throw chain('parentHash');
    V1Ids.canonical(commit.writerDeviceID, path: '$entity.writerDeviceID');
    V1Ids.canonical(commit.requestID, path: '$entity.requestID');
    if (commit.kind != 'snapshot' && commit.kind != 'takeover') throw chain('kind');
    if (previous == null && commit.kind != 'snapshot') throw chain('kind');
    if (previous != null &&
        commit.kind != 'takeover' &&
        commit.writerDeviceID.toUpperCase() != previous.writerDeviceID.toUpperCase()) {
      throw chain('writerDeviceID');
    }
    if (!sha256Pattern.hasMatch(commit.manifestHash)) throw chain('manifestHash');
    if (commit.manifestKey != '${prefix}snapshots/${commit.manifestHash}.json') throw chain('manifestKey');
    _timestamp(commit.createdAt, '$entity.createdAt');
  }

  static void _validateMoment(V1Moment moment) {
    final entity = 'moments[${moment.id}]';
    if (utf16Length(moment.title) > 200) {
      throw ContractError('$entity.title', 'Title is limited to 200 UTF-16 characters.');
    }
    if (utf16Length(moment.note) > 10000) {
      throw ContractError('$entity.note', 'Note is limited to 10,000 UTF-16 characters.');
    }
    _timestamp(moment.occurredAt, '$entity.occurredAt');
    _timestamp(moment.createdAt, '$entity.createdAt');
    _timestamp(moment.updatedAt, '$entity.updatedAt');
    if (moment.trashedAt != null) _timestamp(moment.trashedAt!, '$entity.trashedAt');
    if (moment.revision < 0 || moment.revision > maxRevision) {
      throw ContractError('$entity.revision', 'Invalid record version.');
    }
    final distinct = moment.assetIDs.map((id) => id.toUpperCase()).toSet();
    if (moment.assetIDs.length > 30 || distinct.length != moment.assetIDs.length) {
      throw ContractError('$entity.assetIDs', 'Choose 0–30 distinct media items.');
    }
    final hasText = swiftTrim(moment.title).isNotEmpty || swiftTrim(moment.note).isNotEmpty;
    if (moment.assetIDs.isEmpty && !hasText) {
      throw ContractError('$entity.assetIDs', 'Add a title, note, or media item.');
    }
  }

  static final _contentType = RegExp(r'^[A-Za-z0-9.+-]+$');

  static void _validateAsset(V1Asset asset, List<V1Resource> resources) {
    final entity = 'assets[${asset.id}]';
    _timestamp(asset.capturedAt, '$entity.capturedAt');
    if (asset.revision < 0 || asset.revision > maxRevision) {
      throw ContractError('$entity.revision', 'Invalid record version.');
    }
    final Set<String> expected = switch (asset.kind) {
      'photo' => {'photo', 'preview'},
      'video' => {'video', 'preview'},
      'motionPhoto' => {'motionPhoto', 'preview'},
      'livePhoto' => {'livePhotoImage', 'livePhotoVideo', 'preview'},
      _ => throw ContractError('$entity.kind', 'Invalid media kind.'),
    };
    final ids = asset.resourceIDs.map((id) => id.toUpperCase()).toSet();
    final roles = resources.map((r) => r.role).toSet();
    final complete = ids.length == asset.resourceIDs.length &&
        resources.length == ids.length &&
        resources.length == expected.length &&
        resources.every((r) => ids.contains(r.id.toUpperCase())) &&
        roles.length == expected.length &&
        roles.containsAll(expected);
    if (!complete) {
      throw ContractError('$entity.resourceIDs.role', 'A complete original and a preview are required.');
    }
    for (final resource in resources) {
      final resourceEntity = 'resources[${resource.id}]';
      if (resource.byteCount < 1 || resource.byteCount > maxResourceBytes) {
        throw ContractError('$resourceEntity.byteCount', 'Invalid media resource size.');
      }
      if (!sha256Pattern.hasMatch(resource.sha256)) {
        throw ContractError('$resourceEntity.sha256', 'Expected a lowercase SHA-256 hash.');
      }
      if (!validContentType(resource.contentType, resource.role)) {
        throw ContractError('$resourceEntity.contentType', 'The media type is invalid for role ${resource.role}.');
      }
      if (!validFilename(resource.originalFilename)) {
        throw ContractError('$resourceEntity.originalFilename', 'The original filename is invalid.');
      }
    }
  }

  static bool validContentType(String contentType, String role) {
    final typePrefix = (role == 'video' || role == 'livePhotoVideo') ? 'video/' : 'image/';
    return utf16Length(contentType) <= 120 &&
        contentType.startsWith(typePrefix) &&
        _contentType.hasMatch(contentType.substring(typePrefix.length));
  }

  static bool validFilename(String name) {
    final length = utf16Length(name);
    return length >= 1 && length <= 255 && !name.contains('/') && !name.contains(r'\') && !hasControlScalar(name);
  }

  static void _identities(String kind, Iterable<String> ids) {
    final seen = <String>{};
    for (final id in ids) {
      V1Ids.canonical(id, path: '$kind[$id].id');
      if (!seen.add(id.toUpperCase())) {
        throw ContractError('$kind[$id].id', 'Archive contains duplicate identities.');
      }
    }
  }

  static void _timestamp(int value, String path) {
    if (value < 0 || value > maxTimestamp) throw ContractError(path, 'Choose a valid record date.');
  }
}
