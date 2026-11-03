import 'dart:convert';
import 'dart:io';

import 'anniversaries.dart';
import 'app_session.dart';
import 'archive_merge.dart';
import 'archive_store.dart';
import 'digest.dart';
import 'errors.dart';
import 'storage_provider.dart';
import 'v1_ids.dart';
import 'v1_layout.dart';
import 'v1_model.dart';

/// A source chosen by the user, not evidence of permission to edit that source.
class RestoreChain {
  final ParentIdentity parent;
  final String prefix;
  const RestoreChain({required this.parent, required this.prefix});

  void validate() {
    V1Layout.validatePrefix(prefix);
    if (!V1Layout.owns(owner: parent, prefix: prefix)) {
      throw const ContractError('restore.source', '恢复来源与署名不匹配。');
    }
  }
}

class RestoredSource {
  final ParentIdentity parent;
  final String prefix;
  final String writerDeviceID;
  final String commitHash;
  final String manifestHash;
  const RestoredSource({
    required this.parent,
    required this.prefix,
    required this.writerDeviceID,
    required this.commitHash,
    required this.manifestHash,
  });

  Map<String, Object?> toJson() => {
    'parent': parent.folder,
    'prefix': prefix,
    'writerDeviceID': writerDeviceID,
    'commitHash': commitHash,
    'manifestHash': manifestHash,
  };
}

/// A complete offline copy, not a remote write/takeover or authorization receipt.
class ArchiveRestoreResult {
  final String directory;
  final AppSession session;
  final List<RestoredSource> sources;
  final int verifiedObjectCount;
  final int verifiedBytes;
  final int originalResourceCount;
  const ArchiveRestoreResult({
    required this.directory,
    required this.session,
    required this.sources,
    required this.verifiedObjectCount,
    required this.verifiedBytes,
    required this.originalResourceCount,
  });

  String get archivePath => '$directory/archive.json';

  /// Credentials and a source writer lease are deliberately not restored.
  bool get requiresConnectionAndOwnershipReview => true;
}

/// Complete legacy v1/v2 archive recovery into a new, isolated directory.
///
/// All referenced bytes, including originals, previews and trashed media, are
/// downloaded and independently hashed before the destination is published.
/// Existing destinations are refused rather than merged or replaced. Sources
/// stay untouched. An explicit own [editableSourcePrefix] permits local editing
/// of that chain only; all other chains remain read-only. This does not prove
/// cloud ownership or transfer an old writer lease. The result is disconnected
/// and local-only, so restoration never silently republishes an old snapshot.
abstract final class ArchiveRestore {
  static Future<ArchiveRestoreResult> restore(
    StorageProvider provider, {
    required String destination,
    required ParentIdentity owner,
    required String deviceID,
    required List<RestoreChain> chains,
    String? editableSourcePrefix,
    bool testBuild = true,
  }) async {
    V1Ids.canonical(deviceID, path: 'restore.deviceID');
    if (chains.isEmpty ||
        chains.length > 1000 ||
        chains.map((c) => c.prefix).toSet().length != chains.length) {
      throw const ContractError('restore.source', '请选择不同的有效恢复来源。');
    }
    for (final chain in chains) {
      chain.validate();
    }
    if (editableSourcePrefix != null &&
        !chains.any(
          (c) => c.prefix == editableSourcePrefix && c.parent == owner,
        )) {
      throw const ContractError('restore.owner', '只能明确选择自己的来源用于本机编辑。');
    }
    final requested = Directory(destination).absolute;
    if (await FileSystemEntity.type(requested.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const ContractError('restore.destination', '恢复目录必须不存在，现有资料不会被覆盖。');
    }
    if (!await requested.parent.exists()) {
      throw const ContractError('restore.destination', '请先创建独立恢复目录的父目录。');
    }
    // Keep staging, publication and the returned receipt on one resolved
    // filesystem path, even if a parent directory alias changes while the
    // remote originals are being downloaded.
    final parent = await requested.parent.resolveSymbolicLinks();
    final name = requested.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final target = Directory('$parent${Platform.pathSeparator}$name');
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const ContractError('restore.destination', '恢复目录已被占用，现有资料不会被覆盖。');
    }
    final staging = await target.parent.createTemp('.dayswith-restore-');
    var published = false;
    try {
      final snapshots = <ChainSnapshot>[];
      final sources = <RestoredSource>[];
      final objects = <String, V1Resource>{};
      var originalResources = 0;
      final sorted = [...chains]..sort((a, b) => a.prefix.compareTo(b.prefix));
      for (final chain in sorted) {
        final receipt = await FamilyReader.latestStorage(
          provider,
          chain.prefix,
        );
        if (receipt == null) {
          throw const ContractError('restore.source', '恢复来源中没有完整的已提交档案。');
        }
        snapshots.add(
          ChainSnapshot(
            parent: chain.parent,
            prefix: chain.prefix,
            writer: receipt.commit.writerDeviceID,
            createdAt: receipt.commit.createdAt,
            manifest: receipt.manifest,
          ),
        );
        sources.add(
          RestoredSource(
            parent: chain.parent,
            prefix: chain.prefix,
            writerDeviceID: receipt.commit.writerDeviceID,
            commitHash: receipt.commitHash,
            manifestHash: receipt.commit.manifestHash,
          ),
        );
        // Preserve the validated manifests, including tombstones and original
        // writer associations that the read-side timeline does not display.
        final saved = File('${staging.path}/sources/${sources.length}.json');
        await saved.parent.create(recursive: true);
        final sourceBytes = await provider.get(key: receipt.commit.manifestKey);
        if (Digest.sha256Hex(sourceBytes) != receipt.commit.manifestHash) {
          throw const ContractError('restore.source', '原始清单未通过哈希校验。');
        }
        await saved.writeAsBytes(sourceBytes, flush: true);
        for (final resource in receipt.manifest.resources) {
          final previous = objects[resource.objectKey];
          if (previous != null &&
              (previous.byteCount != resource.byteCount ||
                  previous.sha256 != resource.sha256)) {
            throw const ContractError('restore.resource', '原件引用的大小或哈希不一致。');
          }
          objects[resource.objectKey] = resource;
          if (resource.role != 'preview') originalResources++;
        }
      }
      var verifiedBytes = 0;
      final downloaded = <String, String>{};
      for (final entry in objects.entries) {
        final resource = entry.value;
        final relative = 'media/restored/${resource.sha256}';
        final path = '${staging.path}/$relative';
        await provider.getFile(
          key: entry.key,
          destination: path,
          byteCount: resource.byteCount,
          sha256: resource.sha256,
        );
        // Never assume the adapter's return proves the disk artifact.
        final actual = await Digest.sha256File(
          path,
          maximumBytes: resource.byteCount,
        );
        if (actual.byteCount != resource.byteCount ||
            actual.hash != resource.sha256) {
          throw const ContractError('restore.resource', '恢复的完整原件未通过哈希校验。');
        }
        downloaded[entry.key] = relative;
        verifiedBytes += actual.byteCount;
      }
      final winners = <String, (ChainSnapshot, V1Moment)>{};
      for (final source in snapshots) {
        for (final moment in source.manifest.moments) {
          final key = _momentKey(source.parent, moment.id);
          final previous = winners[key]?.$2;
          if (previous == null ||
              previous.updatedAt < moment.updatedAt ||
              (previous.updatedAt == moment.updatedAt &&
                  previous.revision < moment.revision) ||
              (previous.updatedAt == moment.updatedAt &&
                  previous.revision == moment.revision &&
                  previous.trashedAt == null &&
                  moment.trashedAt != null)) {
            winners[key] = (source, moment);
          }
        }
      }
      final local = <LocalMoment>[];
      final editableKeys = <String>{};
      for (final entry in winners.entries) {
        final (source, moment) = entry.value;
        if (source.prefix != editableSourcePrefix || source.parent != owner) {
          continue;
        }
        editableKeys.add(ArchiveMerge.remoteID(source.parent, moment.id));
        final assets = <LocalAsset>[];
        for (final assetID in moment.assetIDs) {
          final asset = source.manifest.assets.firstWhere(
            (a) => a.id.toUpperCase() == assetID.toUpperCase(),
          );
          assets.add(
            LocalAsset(
              id: asset.id,
              kind: asset.kind,
              capturedAt: asset.capturedAt,
              provenance: asset.importProvenance,
              resources: [
                for (final resourceID in asset.resourceIDs)
                  for (final resource in source.manifest.resources)
                    if (resource.id.toUpperCase() == resourceID.toUpperCase())
                      LocalResource(
                        id: resource.id,
                        role: resource.role,
                        contentType: resource.contentType,
                        originalFilename: resource.originalFilename,
                        byteCount: resource.byteCount,
                        sha256: resource.sha256,
                        relativePath: downloaded[resource.objectKey]!,
                      ),
              ],
            ),
          );
        }
        local.add(
          LocalMoment(
            id: moment.id,
            title: moment.title,
            note: moment.note,
            occurredAt: moment.occurredAt,
            createdAt: moment.createdAt,
            updatedAt: moment.updatedAt,
            revision: moment.revision,
            trashedAt: moment.trashedAt,
            parent: source.parent,
            assets: assets,
            uploadEligibility: UploadEligibility.localOnly,
          ),
        );
      }
      final remote = <RemoteMoment>[];
      for (final moment in ArchiveMerge.merge(snapshots)) {
        if (editableKeys.contains(moment.id)) continue;
        for (final media in moment.media) {
          for (final resource in media.resources) {
            final relative = resource.role == 'preview'
                ? 'preview-cache/${resource.parent.folder}-${resource.sha256}'
                : 'original-cache/${resource.parent.folder}-${resource.sha256}.${_extension(resource.originalFilename)}';
            final cache = File('${staging.path}/$relative');
            await cache.parent.create(recursive: true);
            if (!await cache.exists()) {
              await File('${staging.path}/${downloaded[resource.objectKey]!}')
                  .copy(cache.path);
            }
          }
        }
        final first = moment.previews.firstOrNull;
        remote.add(
          RemoteMoment(
            id: moment.id,
            parent: moment.parent,
            title: moment.title,
            note: moment.note,
            occurredAt: moment.occurredAt,
            readOnly: true,
            mediaCount: moment.mediaCount,
            previewObjectKey: moment.previewObjectKey,
            localPreviewPath: first == null
                ? null
                : 'preview-cache/${first.parent.folder}-${first.sha256}',
            previews: moment.previews,
            media: moment.media,
          ),
        );
      }
      final anniversaries = ArchiveMerge.mergeAnniversaries(snapshots);
      final session = AppSession(
        deviceID: deviceID,
        testBuild: testBuild,
        identity: owner,
        moments: local,
        remote: remote,
        anniversaries: [
          for (final item in anniversaries)
            if (item.sourcePrefix == editableSourcePrefix &&
                item.owner == owner)
              LocalAnniversary(
                id: item.recordID,
                owner: item.owner,
                title: item.title,
                date: item.date,
                deletedAt: item.deletedAt,
                updatedAt: item.updatedAt,
                uploadEligibility: UploadEligibility.localOnly,
              ),
        ],
        remoteAnniversaries: [
          for (final item in anniversaries)
            if (item.sourcePrefix != editableSourcePrefix ||
                item.owner != owner)
              item,
        ],
      );
      final store = ArchiveStore('${staging.path}/archive.json');
      store.save(PersistedArchive.fromSession(session));
      // Re-read the exact serialized artifact before publication.
      final reloaded = store.load()!.session();
      await File('${staging.path}/restore-receipt.json').writeAsString(
        jsonEncode({
          'version': 1,
          'sources': sources.map((s) => s.toJson()).toList(),
          'verifiedObjectCount': objects.length,
          'verifiedBytes': verifiedBytes,
          'originalResourceCount': originalResources,
          'editableSourcePrefix': editableSourcePrefix,
          'requiresConnectionAndOwnershipReview': true,
          'limitations':
              'Offline copy only. No credentials or cloud writer takeover. '
              'Foreign and unselected chains remain read-only. Not real-device acceptance.',
        }),
        flush: true,
      );
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const ContractError('restore.destination', '恢复目录已被占用，现有资料不会被覆盖。');
      }
      await staging.rename(target.path);
      published = true;
      return ArchiveRestoreResult(
        directory: target.path,
        session: reloaded,
        sources: List.unmodifiable(sources),
        verifiedObjectCount: objects.length,
        verifiedBytes: verifiedBytes,
        originalResourceCount: originalResources,
      );
    } finally {
      // Only a directory created by this operation is eligible for cleanup.
      if (!published && await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
  }

  static String _momentKey(ParentIdentity parent, String id) =>
      '${parent.folder}:${id.toUpperCase()}';
  static String _extension(String filename) {
    final dot = filename.lastIndexOf('.');
    final value = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,10}$').hasMatch(value) ? value : 'bin';
  }
}
