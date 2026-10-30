import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:collection/collection.dart';

import 'anniversaries.dart';
import 'archive_merge.dart';
import 'backup_queue.dart';
import 'cos_client.dart';
import 'digest.dart';
import 'errors.dart';
import 'json_codec.dart';
import 'text.dart';
import 'time_zone.dart';
import 'timeline.dart';
import 'v1_ids.dart';
import 'v1_json.dart';
import 'v1_layout.dart';
import 'v1_model.dart';
import 'v1_validator.dart';

const _deep = DeepCollectionEquality();

enum AppPhase { chooseIdentity, connectCloud, timeline }

sealed class CloudLink {
  const CloudLink();

  String? get bucket;
  String? get region;
  bool get isConnected => this is! CloudMissing;

  /// Swift `Codable` shape: `{"missing":{}}`, `{"placeholder":{"bucket":…,"region":…}}`.
  Map<String, Object?> toJson();

  static CloudLink fromJson(Object? json) {
    final v = JsonFields(json, 'link');
    if (v.map.length != 1) throw const ContractError('link', 'Invalid cloud link.');
    final key = v.map.keys.single;
    if (key == 'missing') return const CloudMissing();
    final fields = JsonFields(v.map[key], 'link.$key');
    final bucket = fields.string('bucket');
    final region = fields.string('region');
    return switch (key) {
      'placeholder' => CloudPlaceholder(bucket: bucket, region: region),
      'verified' => CloudVerified(bucket: bucket, region: region),
      _ => throw const ContractError('link', 'Invalid cloud link.'),
    };
  }

  @override
  bool operator ==(Object other) => other is CloudLink && _deep.equals(toJson(), other.toJson());

  @override
  int get hashCode => _deep.hash(toJson());
}

class CloudMissing extends CloudLink {
  const CloudMissing();
  @override
  String? get bucket => null;
  @override
  String? get region => null;
  @override
  Map<String, Object?> toJson() => {'missing': <String, Object?>{}};
}

class CloudPlaceholder extends CloudLink {
  @override
  final String bucket;
  @override
  final String region;
  const CloudPlaceholder({required this.bucket, required this.region});
  @override
  Map<String, Object?> toJson() => {
        'placeholder': {'bucket': bucket, 'region': region}
      };
}

class CloudVerified extends CloudLink {
  @override
  final String bucket;
  @override
  final String region;
  const CloudVerified({required this.bucket, required this.region});
  @override
  Map<String, Object?> toJson() => {
        'verified': {'bucket': bucket, 'region': region}
      };
}

class LocalResource {
  String id;
  String role;
  String contentType;
  String originalFilename;
  int byteCount;
  String sha256;
  String relativePath;

  LocalResource({
    required this.id,
    required this.role,
    required this.contentType,
    required this.originalFilename,
    required this.byteCount,
    required this.sha256,
    required this.relativePath,
  });

  LocalResource copy() => LocalResource.fromJson(toJson());

  factory LocalResource.fromJson(Object? json) {
    final v = JsonFields(json, 'resource');
    return LocalResource(
      id: v.string('id'),
      role: v.string('role'),
      contentType: v.string('contentType'),
      originalFilename: v.string('originalFilename'),
      byteCount: v.integer('byteCount'),
      sha256: v.string('sha256'),
      relativePath: v.string('relativePath'),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'role': role,
        'contentType': contentType,
        'originalFilename': originalFilename,
        'byteCount': byteCount,
        'sha256': sha256,
        'relativePath': relativePath,
      };

  @override
  bool operator ==(Object other) => other is LocalResource && _deep.equals(toJson(), other.toJson());

  @override
  int get hashCode => _deep.hash(toJson());
}

class CaptureMetadata {
  String source;
  int? timezoneOffsetMinutes;
  String? localDateTime;
  bool isEstimated;

  CaptureMetadata({required this.source, this.timezoneOffsetMinutes, this.localDateTime, this.isEstimated = false});

  factory CaptureMetadata.fromJson(Object? json) {
    final v = JsonFields(json, 'captureMetadata');
    return CaptureMetadata(
      source: v.string('source'),
      timezoneOffsetMinutes: v.optionalInt('timezoneOffsetMinutes'),
      localDateTime: v.optionalString('localDateTime'),
      isEstimated: v.boolean('isEstimated'),
    );
  }

  Map<String, Object?> toJson() => {
        'source': source,
        if (timezoneOffsetMinutes != null) 'timezoneOffsetMinutes': timezoneOffsetMinutes,
        if (localDateTime != null) 'localDateTime': localDateTime,
        'isEstimated': isEstimated,
      };

  @override
  bool operator ==(Object other) => other is CaptureMetadata && _deep.equals(toJson(), other.toJson());

  @override
  int get hashCode => _deep.hash(toJson());
}

class LocalAsset {
  String id;
  String kind;
  int capturedAt;
  String? provenance;
  CaptureMetadata? captureMetadata;
  List<LocalResource> resources;

  LocalAsset({
    required this.id,
    required this.kind,
    required this.capturedAt,
    required this.provenance,
    required this.resources,
    this.captureMetadata,
  });

  LocalAsset copy() => LocalAsset.fromJson(toJson());

  factory LocalAsset.fromJson(Object? json) {
    final v = JsonFields(json, 'asset');
    return LocalAsset(
      id: v.string('id'),
      kind: v.string('kind'),
      capturedAt: v.integer('capturedAt'),
      provenance: v.optionalString('provenance'),
      captureMetadata: v.has('captureMetadata') ? CaptureMetadata.fromJson(v.raw('captureMetadata')) : null,
      resources: v.list('resources').map(LocalResource.fromJson).toList(),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind,
        'capturedAt': capturedAt,
        if (provenance != null) 'provenance': provenance,
        if (captureMetadata != null) 'captureMetadata': captureMetadata!.toJson(),
        'resources': resources.map((r) => r.toJson()).toList(),
      };

  @override
  bool operator ==(Object other) => other is LocalAsset && _deep.equals(toJson(), other.toJson());

  @override
  int get hashCode => _deep.hash(toJson());
}

enum UploadEligibility {
  // The former "eligible" value did not record the creation build and cannot be trusted.
  eligible('family'),
  testOnly('testOnly'),
  localOnly('localOnly');

  final String rawValue;
  const UploadEligibility(this.rawValue);

  /// Anything missing, legacy or unknown fails closed to [localOnly].
  static UploadEligibility decode(Object? value) =>
      UploadEligibility.values.where((item) => item.rawValue == value).firstOrNull ?? localOnly;
}

class LocalMoment {
  String id;
  String title;
  String note;
  int occurredAt;
  int createdAt;
  int updatedAt;
  int revision;
  int? trashedAt;
  ParentIdentity parent;
  List<LocalAsset> assets;
  final UploadEligibility uploadEligibility;

  LocalMoment({
    required this.id,
    required this.title,
    required this.note,
    required this.occurredAt,
    required this.createdAt,
    required this.updatedAt,
    this.revision = 1,
    this.trashedAt,
    required this.parent,
    required this.assets,
    this.uploadEligibility = UploadEligibility.localOnly,
  });

  LocalMoment copy() => LocalMoment.fromJson(toJson());

  factory LocalMoment.fromJson(Object? json) {
    final v = JsonFields(json, 'moment');
    return LocalMoment(
      id: v.string('id'),
      title: v.string('title'),
      note: v.string('note'),
      occurredAt: v.integer('occurredAt'),
      createdAt: v.integer('createdAt'),
      updatedAt: v.integer('updatedAt'),
      revision: v.integer('revision'),
      trashedAt: v.optionalInt('trashedAt'),
      parent: v.parent('parent'),
      assets: v.list('assets').map(LocalAsset.fromJson).toList(),
      uploadEligibility: UploadEligibility.decode(v.raw('uploadEligibility')),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'note': note,
        'occurredAt': occurredAt,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'revision': revision,
        if (trashedAt != null) 'trashedAt': trashedAt,
        'parent': parent.folder,
        'assets': assets.map((a) => a.toJson()).toList(),
        'uploadEligibility': uploadEligibility.rawValue,
      };

  @override
  bool operator ==(Object other) => other is LocalMoment && _deep.equals(toJson(), other.toJson());

  @override
  int get hashCode => _deep.hash(toJson());
}

class ComposerDraft {
  final String id;
  String title;
  String note;
  int occurredAt;
  List<LocalAsset> assets;
  String? originalMomentID;
  int? baselineRevision;
  bool timeWasEdited;
  bool occurredAtIsEstimated;
  bool hasImportedBatch;
  final UploadEligibility uploadEligibility;

  ComposerDraft({
    this.title = '',
    this.note = '',
    required this.occurredAt,
    List<LocalAsset>? assets,
    this.uploadEligibility = UploadEligibility.localOnly,
    String? id,
    this.originalMomentID,
    this.baselineRevision,
    this.timeWasEdited = false,
    this.hasImportedBatch = false,
    this.occurredAtIsEstimated = false,
  })  : assets = assets ?? [],
        id = id ?? newUuid();

  ComposerDraft copy() => ComposerDraft.fromJson(toJson());

  factory ComposerDraft.fromJson(Object? json) {
    final v = JsonFields(json, 'draft');
    final assets = v.list('assets').map(LocalAsset.fromJson).toList();
    return ComposerDraft(
      id: v.optionalString('id') ?? newUuid(),
      title: v.string('title'),
      note: v.string('note'),
      occurredAt: v.integer('occurredAt'),
      assets: assets,
      uploadEligibility: UploadEligibility.decode(v.raw('uploadEligibility')),
      originalMomentID: v.optionalString('originalMomentID'),
      baselineRevision: v.optionalInt('baselineRevision'),
      // Old drafts may contain manually entered dates: never overwrite them during upgrade.
      timeWasEdited: v.optionalBool('timeWasEdited') ?? true,
      hasImportedBatch: v.optionalBool('hasImportedBatch') ?? assets.isNotEmpty,
      occurredAtIsEstimated: v.optionalBool('occurredAtIsEstimated') ?? false,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'note': note,
        'occurredAt': occurredAt,
        'assets': assets.map((a) => a.toJson()).toList(),
        'uploadEligibility': uploadEligibility.rawValue,
        if (originalMomentID != null) 'originalMomentID': originalMomentID,
        if (baselineRevision != null) 'baselineRevision': baselineRevision,
        'timeWasEdited': timeWasEdited,
        'hasImportedBatch': hasImportedBatch,
        'occurredAtIsEstimated': occurredAtIsEstimated,
      };

  int get originalCount => assets.length;

  @override
  bool operator ==(Object other) => other is ComposerDraft && _deep.equals(toJson(), other.toJson());

  @override
  int get hashCode => _deep.hash(toJson());
}

class AppSession {
  String deviceID;
  bool testBuild;
  ParentIdentity? identity;
  CloudLink link;
  List<LocalMoment> moments;
  ComposerDraft? draft;
  List<RemoteMoment> remote;
  List<LocalAnniversary> anniversaries;
  List<RemoteAnniversary> remoteAnniversaries;
  BackupJob? backupJob;
  Map<String, String> committedDrafts;

  AppSession({
    required this.deviceID,
    required this.testBuild,
    this.identity,
    this.link = const CloudMissing(),
    List<LocalMoment>? moments,
    this.draft,
    List<RemoteMoment>? remote,
    List<LocalAnniversary>? anniversaries,
    List<RemoteAnniversary>? remoteAnniversaries,
    this.backupJob,
    Map<String, String>? committedDrafts,
  })  : moments = moments ?? [],
        remote = remote ?? [],
        anniversaries = anniversaries ?? [],
        remoteAnniversaries = remoteAnniversaries ?? [],
        committedDrafts = committedDrafts ?? {};

  /// Deep copy, for callers that need Swift value semantics.
  AppSession copy() => PersistedArchive.fromJson(PersistedArchive.fromSession(this).toJson()).session();

  AppPhase get phase {
    if (identity == null) return AppPhase.chooseIdentity;
    if (!link.isConnected) return AppPhase.connectCloud;
    return AppPhase.timeline;
  }

  void confirmIdentity(ParentIdentity parent) {
    if (identity != null) {
      if (identity != parent) throw const ContractError('identity', '这台手机的署名已经确定，不能修改。');
      return;
    }
    identity = parent;
  }

  void connectPlaceholder({required String bucket, required String region}) {
    if (identity == null) throw const ContractError('identity', '请先选择爸爸或妈妈。');
    // A placeholder has no network client or credentials. Empty first-run fields use
    // synthetic metadata only; verified connections still require the user's bucket.
    final placeholderBucket = swiftTrim(bucket).isEmpty ? 'example-1234567890' : bucket;
    final placeholderRegion = swiftTrim(region).isEmpty ? 'ap-shanghai' : region;
    StorageConfiguration(bucket: placeholderBucket, region: placeholderRegion, prefix: 'life/v1/').validate();
    link = CloudPlaceholder(bucket: placeholderBucket, region: placeholderRegion);
  }

  void connectVerified({required String bucket, required String region}) {
    if (identity == null) throw const ContractError('identity', '请先选择爸爸或妈妈。');
    StorageConfiguration(bucket: bucket, region: region, prefix: 'life/v1/').validate();
    link = CloudVerified(bucket: bucket, region: region);
  }

  void disconnectCloud() => link = const CloudMissing();

  UploadEligibility get newUploadEligibility {
    if (link is CloudVerified) return testBuild ? UploadEligibility.testOnly : UploadEligibility.eligible;
    return UploadEligibility.localOnly;
  }

  /// Reopening the composer resumes its durable draft; it never silently discards work.
  void beginDraft({required int now}) {
    if (draft != null) return;
    draft = ComposerDraft(occurredAt: now, uploadEligibility: newUploadEligibility);
  }

  void beginEdit({required String id, required int now}) {
    final moment = moments.firstWhereOrNull((m) => m.id == id && m.parent == identity && m.trashedAt == null);
    if (moment == null) throw const ContractError('moment', '只能编辑这台手机创建的记录。');
    final current = draft;
    if (current != null) {
      if (current.originalMomentID == id) return;
      throw const ContractError('draft', '请先保存或放弃正在编辑的草稿。');
    }
    draft = ComposerDraft(
      title: moment.title,
      note: moment.note,
      occurredAt: moment.occurredAt,
      assets: moment.assets.map((a) => a.copy()).toList(),
      uploadEligibility: moment.uploadEligibility,
      originalMomentID: moment.id,
      baselineRevision: moment.revision,
      timeWasEdited: true,
      hasImportedBatch: true,
    );
  }

  void discardDraft() => draft = null;

  void updateDraft({required String title, required String note}) {
    draft?.title = title;
    draft?.note = note;
  }

  void setDraftOccurredAt(int occurredAt) {
    final current = draft;
    if (current == null) return;
    current.occurredAt = occurredAt;
    current.timeWasEdited = true;
    current.occurredAtIsEstimated = false;
  }

  void addAsset(LocalAsset asset) => addAssets([asset]);

  static final _localDateTime = RegExp(r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$');

  /// Call once per picker result batch so its earliest known timestamp is used consistently.
  void addAssets(List<LocalAsset> assets, {ZoneRules zone = const DeviceZone()}) {
    final current = draft?.copy();
    if (current == null) throw const ContractError('draft', '请先开始一条记录。');
    if (assets.isEmpty) return;
    if (current.assets.length + assets.length > 30) {
      throw const ContractError('draft.assets', '一条记录最多 30 项媒体。');
    }
    final combined = [...current.assets, ...assets];
    if (combined.map((a) => a.id.toUpperCase()).toSet().length != combined.length) {
      throw const ContractError('draft.assets', '这项媒体已经在记录中。');
    }
    if (current.originalMomentID == null &&
        !current.hasImportedBatch &&
        !current.timeWasEdited &&
        current.assets.isEmpty) {
      final candidates = <({int millis, bool estimated})>[];
      for (final asset in assets) {
        if (asset.capturedAt > 0 && asset.capturedAt <= V1Validator.maxTimestamp) {
          candidates.add((millis: asset.capturedAt, estimated: asset.captureMetadata?.isEstimated ?? false));
          continue;
        }
        // A local date with an unknown zone is useful for the form, but not an absolute asset timestamp.
        final local = asset.captureMetadata?.localDateTime;
        final match = local == null ? null : _localDateTime.firstMatch(local);
        if (match == null) continue;
        final f = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
        final value = zone.utcMillisForLocal(f[0], f[1], f[2], f[3], f[4], f[5]);
        if (value == null || value <= 0 || value > V1Validator.maxTimestamp) continue;
        candidates.add((millis: value, estimated: true));
      }
      final earliest = candidates.isEmpty ? null : candidates.reduce((a, b) => b.millis < a.millis ? b : a);
      if (earliest != null) {
        current.occurredAt = earliest.millis;
        current.occurredAtIsEstimated = earliest.estimated;
      } else {
        current.occurredAtIsEstimated = true;
      }
    }
    current.hasImportedBatch = true;
    current.assets = combined;
    draft = current;
  }

  void removeAsset(String id) => draft?.assets.removeWhere((a) => a.id == id);

  void moveAsset({required int from, required int to}) {
    final current = draft;
    if (current == null || from < 0 || from >= current.assets.length || to < 0 || to > current.assets.length) {
      throw const ContractError('draft.assets', '找不到要移动的媒体。');
    }
    final item = current.assets.removeAt(from);
    current.assets.insert(to < current.assets.length ? to : current.assets.length, item);
  }

  LocalMoment commitDraft({required int now}) {
    final parent = identity;
    final source = draft;
    if (parent == null || source == null) throw const ContractError('draft', '请先开始一条记录。');
    final savedID = committedDrafts[source.id];
    if (savedID != null) {
      final saved = moments.firstWhereOrNull((m) => m.id == savedID);
      if (saved != null) {
        draft = null;
        return saved.copy();
      }
    }
    final current = source.copy();
    current.title = swiftTrim(current.title);
    current.note = swiftTrim(current.note);
    if (current.title.isEmpty && current.note.isEmpty && current.assets.isEmpty) {
      throw const ContractError('draft', '写一段话，或选择媒体。');
    }
    if (utf16Length(current.title) > 200 ||
        utf16Length(current.note) > 10000 ||
        current.occurredAt < 0 ||
        current.occurredAt > V1Validator.maxTimestamp ||
        current.assets.length > 30) {
      throw const ContractError('draft', '请检查日期、文字长度和媒体数量。');
    }
    final LocalMoment saved;
    final originalID = current.originalMomentID;
    if (originalID != null) {
      final index = moments.indexWhere((m) => m.id == originalID && m.parent == parent);
      if (index < 0 || moments[index].revision != current.baselineRevision || moments[index].trashedAt != null) {
        throw const ContractError('draft.baseline', '记录已经改变，请保留草稿并重新检查原记录。');
      }
      // Keep the original immutable upload eligibility, including placeholder origins.
      final edited = moments[index].copy()
        ..title = current.title
        ..note = current.note
        ..occurredAt = current.occurredAt
        ..assets = current.assets
        ..updatedAt = now;
      edited.revision += 1;
      moments[index] = edited;
      saved = edited;
    } else {
      saved = LocalMoment(
        id: current.id,
        title: current.title,
        note: current.note,
        occurredAt: current.occurredAt,
        createdAt: now,
        updatedAt: now,
        parent: parent,
        assets: current.assets,
        uploadEligibility: current.uploadEligibility,
      );
      final existing = moments.firstWhereOrNull((m) => m.id == saved.id);
      if (existing != null) {
        if (existing != saved) throw const ContractError('draft.id', '记录编号冲突，已保留草稿。');
      } else {
        moments.add(saved);
      }
    }
    committedDrafts[current.id] = saved.id;
    draft = null;
    // Swift returns a value: later trash/restore must not change what the caller holds.
    return saved.copy();
  }

  void trashMoment({required String id, required int now}) {
    final index = moments.indexWhere((m) => m.id == id && m.parent == identity);
    if (index < 0) throw const ContractError('moment', '只能移入这台手机创建的记录。');
    final moment = moments[index];
    if (moment.trashedAt != null) return;
    moment
      ..trashedAt = now
      ..updatedAt = now
      ..revision += 1;
  }

  void restoreMoment({required String id, required int now}) {
    final index = moments.indexWhere((m) => m.id == id && m.parent == identity);
    if (index < 0) throw const ContractError('moment', '只能恢复这台手机创建的记录。');
    final moment = moments[index];
    if (moment.trashedAt == null) return;
    moment
      ..trashedAt = null
      ..updatedAt = now
      ..revision += 1;
  }

  List<TimelineMonth> months(ZoneRules zone) => JinbaoCalendar.months(timelineEntries(), zone);

  List<TimelineEntry> timelineEntries() {
    String? path(LocalAsset? asset, bool Function(String role) roles) =>
        asset?.resources.firstWhereOrNull((r) => roles(r.role))?.relativePath;
    final local = moments.where((m) => m.trashedAt == null).map((moment) {
      final first = moment.assets.firstOrNull;
      final preview = path(first, (role) => role == 'preview') ?? path(first, (role) => role == 'photo');
      final provenance = first == null ? null : ImportProvenance.known(first.provenance)?.label;
      return TimelineEntry(
        id: moment.id,
        title: moment.title,
        note: moment.note,
        occurredAt: moment.occurredAt,
        parent: moment.parent,
        readOnly: moment.parent != identity,
        mediaCount: moment.assets.length,
        previewPath: preview,
        provenanceLabel: provenance,
        photos: [
          for (final asset in moment.assets)
            TimelinePhoto(
              id: asset.id,
              localPath: path(asset, (role) => role == 'preview') ??
                  path(asset, (role) => role == 'photo' || role == 'livePhotoImage'),
              fullSizePath: path(asset, (role) => role == 'photo' || role == 'livePhotoImage'),
              kind: asset.kind,
              localResources: asset.resources,
            ),
        ],
      );
    });
    final remoteEntries = remote.map((item) => TimelineEntry(
          id: item.id,
          title: item.title,
          note: item.note,
          occurredAt: item.occurredAt,
          parent: item.parent,
          readOnly: true,
          mediaCount: item.mediaCount,
          previewPath: item.localPreviewPath,
          provenanceLabel: null,
          photos: item.media.isEmpty
              ? [for (final preview in item.previews) TimelinePhoto(id: preview.assetID, remote: preview)]
              : [
                  for (final media in item.media)
                    TimelinePhoto(
                      id: media.id,
                      remote: item.previews.firstWhereOrNull((p) => p.assetID == media.id),
                      kind: media.kind,
                      remoteResources: media.resources,
                    ),
                ],
        ));
    return [...local, ...remoteEntries];
  }

  String writerPrefix() {
    final parent = identity;
    if (parent == null) throw const ContractError('identity', '请先选择爸爸或妈妈。');
    return V1Layout.chainPrefix(parent: parent, deviceID: deviceID, test: testBuild);
  }

  String objectRoot() => V1Layout.objectRoot(writerPrefix());

  // Anniversaries.

  List<AnniversaryEntry> anniversaryEntries() {
    final owner = identity;
    if (owner == null) return [];
    final result = <AnniversaryEntry>[
      for (final item in anniversaries)
        if (item.deletedAt == null && !AnniversaryCalendar.isDefault(item.id))
          AnniversaryEntry(id: item.id, title: item.title, date: item.date, owner: item.owner, readOnly: item.owner != owner),
      for (final remoteItem in remoteAnniversaries)
        if (remoteItem.deletedAt == null &&
            !AnniversaryCalendar.isDefault(remoteItem.recordID) &&
            !anniversaries.any((a) => a.owner == remoteItem.owner && caseInsensitiveEquals(a.id, remoteItem.recordID)))
          AnniversaryEntry(
              id: remoteItem.id, title: remoteItem.title, date: remoteItem.date, owner: remoteItem.owner, readOnly: true),
    ];
    for (final item in AnniversaryCalendar.defaults) {
      final local = anniversaries.firstWhereOrNull((a) => a.owner == owner && caseInsensitiveEquals(a.id, item.id));
      if (local != null) {
        if (local.deletedAt == null) {
          result.add(AnniversaryEntry(
              id: local.id, title: local.title, date: local.date, owner: owner, readOnly: false, isDefault: true));
        }
        continue;
      }
      final remoteCopies = remoteAnniversaries.where((r) => caseInsensitiveEquals(r.recordID, item.id)).toList()
        ..sort((a, b) {
          if ((a.owner == owner) != (b.owner == owner)) return a.owner == owner ? -1 : 1;
          return b.updatedAt.compareTo(a.updatedAt);
        });
      final remoteItem = remoteCopies.firstOrNull;
      if (remoteItem != null) {
        if (remoteItem.deletedAt == null) {
          result.add(AnniversaryEntry(
              id: remoteItem.id,
              title: remoteItem.title,
              date: remoteItem.date,
              owner: remoteItem.owner,
              readOnly: true,
              isDefault: true));
        }
      } else {
        result.add(AnniversaryEntry(
            id: item.id, title: item.title, date: item.date, owner: owner, readOnly: false, isDefault: true));
      }
    }
    return result;
  }

  LocalAnniversary saveAnniversary({String? id, required String title, required String date, required int now}) {
    final owner = identity;
    if (owner == null) throw const ContractError('identity', '请先选择爸爸或妈妈。');
    final cleanTitle = swiftTrim(title);
    if (cleanTitle.isEmpty || utf16Length(cleanTitle) > 100) {
      throw const ContractError('anniversary.title', '请填写 1–100 字的标题。');
    }
    final validDate = AnniversaryCalendar.normalizedDate(date);
    final recordID = V1Ids.canonical(id ?? newUuid(), path: 'anniversary.id');
    final existing = anniversaries.firstWhereOrNull((a) => caseInsensitiveEquals(a.id, recordID) && a.owner == owner);
    if (existing != null) {
      existing
        ..title = cleanTitle
        ..date = validDate
        ..deletedAt = null
        ..updatedAt = now;
      return LocalAnniversary.fromJson(existing.toJson());
    }
    if (remoteAnniversaries.any((r) => r.owner == owner && caseInsensitiveEquals(r.recordID, recordID))) {
      throw const ContractError('anniversary', '其他设备创建的纪念日只读。');
    }
    final item = LocalAnniversary(
        id: recordID,
        owner: owner,
        title: cleanTitle,
        date: validDate,
        updatedAt: now,
        uploadEligibility: newUploadEligibility);
    anniversaries.add(item);
    return LocalAnniversary.fromJson(item.toJson());
  }

  void deleteAnniversary({required String id, required int now}) {
    final owner = identity;
    if (owner == null) throw const ContractError('identity', '请先选择爸爸或妈妈。');
    final existing = anniversaries.firstWhereOrNull((a) => caseInsensitiveEquals(a.id, id) && a.owner == owner);
    if (existing != null) {
      if (existing.deletedAt == null) {
        existing
          ..deletedAt = now
          ..updatedAt = now;
      }
      return;
    }
    final item = AnniversaryCalendar.defaults.firstWhereOrNull((d) => caseInsensitiveEquals(d.id, id));
    if (remoteAnniversaries.any((r) => caseInsensitiveEquals(r.recordID, id)) || item == null) {
      throw const ContractError('anniversary', '只能删除这台手机创建的纪念日。');
    }
    anniversaries.add(LocalAnniversary(
        id: item.id,
        owner: owner,
        title: item.title,
        date: item.date,
        deletedAt: now,
        updatedAt: now,
        uploadEligibility: newUploadEligibility));
  }

  List<V1Anniversary> backupAnniversaries() {
    final eligibility = testBuild ? UploadEligibility.testOnly : UploadEligibility.eligible;
    return [
      for (final item in anniversaries)
        if (item.uploadEligibility == eligibility && item.owner == identity)
          V1Anniversary(
            id: V1Ids.canonical(item.id, path: 'anniversary.id'),
            owner: item.owner,
            title: item.title,
            date: AnniversaryCalendar.normalizedDate(item.date),
            deletedAt: item.deletedAt,
          ),
    ]..sort((a, b) => a.id.compareTo(b.id));
  }

  @override
  bool operator ==(Object other) =>
      other is AppSession &&
      _deep.equals(PersistedArchive.fromSession(this).toJson(), PersistedArchive.fromSession(other).toJson());

  @override
  int get hashCode => _deep.hash(PersistedArchive.fromSession(this).toJson());
}

class PersistedArchive {
  static const currentVersion = 2;
  int schemaVersion;
  String deviceID;
  bool testBuild;
  String? identityFolder;
  CloudLink link;
  List<LocalMoment> moments;
  ComposerDraft? draft;
  List<RemoteMoment> remote;
  List<LocalAnniversary> anniversaries;
  List<RemoteAnniversary> remoteAnniversaries;
  BackupJob? backupJob;
  Map<String, String> committedDrafts;

  PersistedArchive._({
    required this.schemaVersion,
    required this.deviceID,
    required this.testBuild,
    required this.identityFolder,
    required this.link,
    required this.moments,
    required this.draft,
    required this.remote,
    required this.anniversaries,
    required this.remoteAnniversaries,
    required this.backupJob,
    required this.committedDrafts,
  });

  factory PersistedArchive.fromSession(AppSession session) => PersistedArchive._(
        schemaVersion: currentVersion,
        deviceID: session.deviceID,
        testBuild: session.testBuild,
        identityFolder: session.identity?.folder,
        link: session.link,
        moments: session.moments,
        draft: session.draft,
        remote: session.remote,
        anniversaries: session.anniversaries,
        remoteAnniversaries: session.remoteAnniversaries,
        backupJob: session.backupJob,
        committedDrafts: session.committedDrafts,
      );

  factory PersistedArchive.fromJson(Object? json) {
    final v = JsonFields(json, 'archive');
    final schemaVersion = v.optionalInt('schemaVersion') ?? 1;
    if (schemaVersion < 1 || schemaVersion > currentVersion) {
      throw const ContractError('archive.schemaVersion', '此档案需要更新版本的 App，原数据已保留。');
    }
    final identityFolder = v.optionalString('identityFolder');
    if (identityFolder != null && ParentIdentity.fromFolder(identityFolder) == null) {
      throw const ContractError('archive.identity', '档案身份无法识别，原数据已保留。');
    }
    final committed = v.has('committedDrafts') ? JsonFields(v.raw('committedDrafts'), 'archive.committedDrafts') : null;
    return PersistedArchive._(
      schemaVersion: schemaVersion,
      deviceID: v.string('deviceID'),
      testBuild: v.boolean('testBuild'),
      identityFolder: identityFolder,
      link: CloudLink.fromJson(v.raw('link')),
      moments: v.list('moments').map(LocalMoment.fromJson).toList(),
      draft: v.has('draft') ? ComposerDraft.fromJson(v.raw('draft')) : null,
      remote: (v.optionalList('remote') ?? const []).map(RemoteMoment.fromJson).toList(),
      anniversaries: (v.optionalList('anniversaries') ?? const []).map(LocalAnniversary.fromJson).toList(),
      remoteAnniversaries:
          (v.optionalList('remoteAnniversaries') ?? const []).map(RemoteAnniversary.fromJson).toList(),
      backupJob: v.has('backupJob') ? BackupJob.fromJson(v.raw('backupJob')) : null,
      committedDrafts: committed == null ? {} : {for (final key in committed.map.keys) key: committed.string(key)},
    );
  }

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'deviceID': deviceID,
        'testBuild': testBuild,
        if (identityFolder != null) 'identityFolder': identityFolder,
        'link': link.toJson(),
        'moments': moments.map((m) => m.toJson()).toList(),
        if (draft != null) 'draft': draft!.toJson(),
        'remote': remote.map((r) => r.toJson()).toList(),
        'anniversaries': anniversaries.map((a) => a.toJson()).toList(),
        'remoteAnniversaries': remoteAnniversaries.map((a) => a.toJson()).toList(),
        if (backupJob != null) 'backupJob': backupJob!.toJson(),
        'committedDrafts': Map<String, Object?>.of(committedDrafts),
      };

  AppSession session() => AppSession(
        deviceID: deviceID,
        testBuild: testBuild,
        identity: ParentIdentity.fromFolder(identityFolder),
        link: link,
        moments: moments,
        draft: draft,
        remote: remote,
        anniversaries: anniversaries,
        remoteAnniversaries: remoteAnniversaries,
        backupJob: backupJob,
        committedDrafts: committedDrafts,
      );

  @override
  bool operator ==(Object other) => other is PersistedArchive && _deep.equals(toJson(), other.toJson());

  @override
  int get hashCode => _deep.hash(toJson());
}

class BackupManifestPlan {
  final String prefix;
  final V1Manifest manifest;
  final Uint8List bytes;
  const BackupManifestPlan(this.prefix, this.manifest, this.bytes);
}

abstract final class BackupPlan {
  static BackupManifestPlan manifest(AppSession session, {required int now}) {
    if (session.link is! CloudVerified) {
      throw const ContractError('backup', '占位连接不会上传。请在真机填写密钥后再备份。');
    }
    final prefix = session.writerPrefix();
    if (V1Layout.isLegacyRoot(prefix)) throw const ContractError('backup.prefix', '旧目录只读，不能写入。');
    final includedMoments = backupMoments(session);
    final anniversaries = session.backupAnniversaries();
    if (includedMoments.isEmpty && anniversaries.isEmpty) {
      throw const ContractError('backup', '没有可备份的记录。');
    }
    final moments = [
      for (final moment in includedMoments)
        V1Moment(
          id: V1Ids.map(kind: 'record', localID: moment.id),
          title: moment.title,
          note: moment.note,
          occurredAt: moment.occurredAt,
          createdAt: moment.createdAt,
          updatedAt: moment.updatedAt,
          assetIDs: [for (final asset in moment.assets) V1Ids.map(kind: 'asset', localID: asset.id)],
          trashedAt: moment.trashedAt,
          revision: moment.revision,
        ),
    ]..sort((a, b) => a.id.compareTo(b.id));
    final allAssets = includedMoments.expand((m) => m.assets).toList();
    final assets = [
      for (final asset in allAssets)
        V1Asset(
          id: V1Ids.map(kind: 'asset', localID: asset.id),
          kind: asset.kind,
          capturedAt: asset.capturedAt,
          resourceIDs: [for (final r in asset.resources) V1Ids.map(kind: 'resource', localID: r.id)],
          importProvenance: asset.provenance,
        ),
    ]..sort((a, b) => a.id.compareTo(b.id));
    final resources = [
      for (final asset in allAssets)
        for (final resource in asset.resources)
          V1Resource(
            id: V1Ids.map(kind: 'resource', localID: resource.id),
            assetID: V1Ids.map(kind: 'asset', localID: asset.id),
            role: resource.role,
            contentType: resource.contentType,
            originalFilename: safeFilename(resource.originalFilename),
            byteCount: resource.byteCount,
            sha256: resource.sha256.toLowerCase(),
            objectKey: V1Layout.objectKey(prefix: prefix, sha256: resource.sha256.toLowerCase()),
          ),
    ]..sort((a, b) => a.id.compareTo(b.id));
    final manifest = V1Manifest(
      version: 2,
      moments: moments,
      assets: _deduplicate(assets, (a) => a.id),
      resources: _deduplicate(resources, (r) => r.id),
      anniversaries: anniversaries,
    );
    V1Validator.validate(manifest: manifest, prefix: prefix);
    return BackupManifestPlan(prefix, manifest, V1Json.encodeManifest(manifest));
  }

  static List<LocalMoment> backupMoments(AppSession session) {
    final eligibility = session.testBuild ? UploadEligibility.testOnly : UploadEligibility.eligible;
    return session.moments.where((m) => m.uploadEligibility == eligibility && m.parent == session.identity).toList();
  }

  static List<T> _deduplicate<T>(List<T> values, String Function(T) id) {
    final unique = <String, T>{};
    for (final value in values) {
      final key = id(value).toUpperCase();
      final existing = unique[key];
      if (existing != null && existing != value) {
        throw ContractError(key, '媒体编号对应不同原件，已停止备份。');
      }
      unique[key] = value;
    }
    final keys = unique.keys.toList()..sort();
    return [for (final key in keys) unique[key] as T];
  }

  static String safeFilename(String filename) {
    final replaced = filename.characters
        .map((character) => character == '/' || character == r'\' || hasControlScalar(character) ? '_' : character)
        .join();
    if (replaced.isEmpty) return 'import';
    if (utf16Length(replaced) <= 255) return replaced;
    // Android's wire limit is UTF-16 code units. Keep complete grapheme clusters as well
    // as complete surrogate pairs, so emoji and combining sequences remain readable.
    final result = StringBuffer();
    var units = 0;
    for (final character in replaced.characters) {
      final width = utf16Length(character);
      if (units + width > 255) break;
      result.write(character);
      units += width;
    }
    return result.isEmpty ? 'import' : result.toString();
  }

  static List<BackupUpload> uploads(AppSession session) {
    final planned = manifest(session, now: 0);
    final locals = backupMoments(session).expand((m) => m.assets).expand((a) => a.resources).toList();
    return [
      for (final resource in planned.manifest.resources)
        () {
          final local = locals.firstWhereOrNull((r) => V1Ids.map(kind: 'resource', localID: r.id) == resource.id);
          if (local == null) throw ContractError(resource.id, '原件还在本地，暂时找不到。');
          return BackupUpload(
            objectKey: resource.objectKey,
            relativePath: local.relativePath,
            contentType: resource.contentType,
            sha256: resource.sha256,
            byteCount: resource.byteCount,
          );
        }(),
    ];
  }
}

class BackupUpload {
  final String objectKey;
  final String relativePath;
  final String contentType;
  final String sha256;
  final int byteCount;

  const BackupUpload({
    required this.objectKey,
    required this.relativePath,
    required this.contentType,
    required this.sha256,
    required this.byteCount,
  });

  factory BackupUpload.fromJson(Object? json) {
    final v = JsonFields(json, 'upload');
    return BackupUpload(
      objectKey: v.string('objectKey'),
      relativePath: v.string('relativePath'),
      contentType: v.string('contentType'),
      sha256: v.string('sha256'),
      byteCount: v.integer('byteCount'),
    );
  }

  Map<String, Object?> toJson() => {
        'objectKey': objectKey,
        'relativePath': relativePath,
        'contentType': contentType,
        'sha256': sha256,
        'byteCount': byteCount,
      };

  @override
  bool operator ==(Object other) => other is BackupUpload && _deep.equals(toJson(), other.toJson());

  @override
  int get hashCode => _deep.hash(toJson());
}

abstract final class BackupPublisher {
  /// Small in-memory bodies keyed by object key or SHA-256 (tests and metadata-sized media).
  static Future<V1Commit> publishBytes(CosClient client, AppSession session,
      {required Map<String, List<int>> files, required int now, required String requestID}) {
    return _publish(client, session, now: now, requestID: requestID, upload: (resource) async {
      final bytes = files[resource.objectKey] ?? files[resource.sha256];
      if (bytes == null) throw ContractError(resource.objectKey, '原件还在本地，暂时找不到。');
      if (Digest.sha256Hex(bytes) != resource.sha256 || bytes.length != resource.byteCount) {
        throw ContractError(resource.objectKey, '原件和记录里的校验不一致，已停止备份。');
      }
      await client.putImmutable(key: resource.objectKey, body: bytes, contentType: resource.contentType);
    });
  }

  /// Production backup retains only file paths. Each media object is staged, verified, uploaded,
  /// and released independently instead of loading all originals into memory.
  static Future<V1Commit> publishFiles(CosClient client, AppSession session,
      {required Map<String, String> filePaths, required int now, required String requestID}) {
    return _publish(client, session, now: now, requestID: requestID, upload: (resource) async {
      final path = filePaths[resource.objectKey] ?? filePaths[resource.sha256];
      if (path == null) throw ContractError(resource.objectKey, '原件还在本地，暂时找不到。');
      await client.putImmutableFile(
          key: resource.objectKey,
          filePath: path,
          byteCount: resource.byteCount,
          sha256: resource.sha256,
          contentType: resource.contentType);
    });
  }

  static Future<V1Commit> _publish(CosClient client, AppSession session,
      {required int now, required String requestID, required Future<void> Function(V1Resource) upload}) async {
    // Planning first preserves the no-network guarantee for placeholder/local-only archives.
    final planned = BackupPlan.manifest(session, now: now);
    if (client.configuration.prefix != planned.prefix) throw const CosFailure(ConnectionFailure.configuration);
    await client.verifyImmutableWritesAllowed();
    for (final resource in planned.manifest.resources) {
      if (!resource.objectKey.startsWith(V1Layout.objectRoot(planned.prefix))) {
        throw const CosFailure(ConnectionFailure.configuration);
      }
      await upload(resource);
    }
    final manifestHash = Digest.sha256Hex(planned.bytes);
    await client.putImmutable(
        key: '${planned.prefix}snapshots/$manifestHash.json', body: planned.bytes, contentType: 'application/json');
    final receipt = await FamilyReader.latest(client, planned.prefix);
    final sequence = (receipt?.commit.sequence ?? 0) + 1;
    final commit = V1Commit(
      sequence: sequence,
      parentHash: receipt?.commitHash,
      writerDeviceID: V1Ids.canonical(session.deviceID, path: 'writerDeviceID'),
      manifestHash: manifestHash,
      manifestKey: '${planned.prefix}snapshots/$manifestHash.json',
      createdAt: now,
      requestID: V1Ids.canonical(requestID, path: 'requestID'),
    );
    final commitBytes = V1Json.encodeCommit(commit);
    final commitKey = planned.prefix + V1Json.commitRelativeKey(sequence);
    V1Validator.validateCommit(
        commit: commit,
        key: commitKey,
        prefix: planned.prefix,
        previous: receipt?.commit,
        previousHash: receipt?.commitHash);
    await client.putImmutable(key: commitKey, body: commitBytes, contentType: 'application/json');
    return commit;
  }
}
