import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import 'app_session.dart';
import 'archive_merge.dart';
import 'cos_client.dart';
import 'digest.dart';
import 'errors.dart';
import 'json_codec.dart';
import 'text.dart';
import 'v1_ids.dart';
import 'v1_json.dart';
import 'v1_layout.dart';
import 'v1_model.dart';
import 'v1_validator.dart';

const _deep = DeepCollectionEquality();

enum BackupJobStatus { queued, uploading, paused, failed, completed }

/// Frozen publication payload. Credentials and transient transport handles never enter the archive.
class BackupJob {
  final String id;
  final String bucket;
  final String region;
  final String prefix;
  final String writerDeviceID;
  final bool testBuild;
  /// Only this frozen, eligible local plan may introduce new cloud content.
  /// [manifestBytes] also contains the verified previous snapshot's records.
  final Uint8List localManifestBytes;
  final Uint8List manifestBytes;
  final Uint8List commitBytes;
  final String commitKey;
  final List<BackupUpload> uploads;
  BackupJobStatus _status;
  final Set<String> _completedObjectKeys;
  bool _snapshotUploaded;
  String? _lastError;

  BackupJob._({
    required this.id,
    required this.bucket,
    required this.region,
    required this.prefix,
    required this.writerDeviceID,
    required this.testBuild,
    required this.localManifestBytes,
    required this.manifestBytes,
    required this.commitBytes,
    required this.commitKey,
    required this.uploads,
    required BackupJobStatus status,
    required Set<String> completedObjectKeys,
    required bool snapshotUploaded,
    required String? lastError,
  })  : _status = status,
        _completedObjectKeys = completedObjectKeys,
        _snapshotUploaded = snapshotUploaded,
        _lastError = lastError;

  BackupJobStatus get status => _status;
  Set<String> get completedObjectKeys => Set.unmodifiable(_completedObjectKeys);
  bool get snapshotUploaded => _snapshotUploaded;
  String? get lastError => _lastError;
  int get completedCount => _completedObjectKeys.length;
  int get totalCount => uploads.length;
  double get progress =>
      (completedCount + (_snapshotUploaded ? 1 : 0) + (_status == BackupJobStatus.completed ? 1 : 0)) /
      (totalCount + 2);
  V1Manifest get manifest => V1Json.decodeManifest(manifestBytes);
  V1Manifest get localManifest => V1Json.decodeManifest(localManifestBytes);
  V1Commit get commit => V1Json.decodeCommit(commitBytes);

  bool matchesLocalPlan(BackupManifestPlan plan) {
    if (plan.prefix != prefix || !const ListEquality<int>().equals(localManifestBytes, plan.bytes)) return false;
    try {
      return BackupQueue._includesLocal(manifest, localManifest);
    } catch (_) {
      return false;
    }
  }

  void pause() {
    if (_status != BackupJobStatus.completed) _status = BackupJobStatus.paused;
  }

  void resume() {
    if (_status != BackupJobStatus.completed) {
      _status = BackupJobStatus.queued;
      _lastError = null;
    }
  }

  BackupJob copy() => BackupJob.fromJson(toJson());

  /// Swift `Codable` shape: `Data` as Base64 and the completed `Set` as an array.
  factory BackupJob.fromJson(Object? json) {
    final v = JsonFields(json, 'backupJob');
    final status = BackupJobStatus.values.firstWhereOrNull((s) => s.name == v.string('status'));
    if (status == null) throw const ContractError('backupJob.status', 'Invalid backup status.');
    Uint8List bytes(String key) {
      try {
        return base64.decode(v.string(key));
      } on FormatException {
        throw ContractError('backupJob.$key', 'Expected Base64 data.');
      }
    }

    final manifestBytes = bytes('manifestBytes');
    return BackupJob._(
      id: v.string('id'),
      bucket: v.string('bucket'),
      region: v.string('region'),
      prefix: v.string('prefix'),
      writerDeviceID: v.string('writerDeviceID'),
      testBuild: v.boolean('testBuild'),
      // Older jobs contained only local content. They must still pass the
      // remote no-loss check before a queued or resumed job can write anything.
      localManifestBytes: v.has('localManifestBytes') ? bytes('localManifestBytes') : manifestBytes,
      manifestBytes: manifestBytes,
      commitBytes: bytes('commitBytes'),
      commitKey: v.string('commitKey'),
      uploads: v.list('uploads').map(BackupUpload.fromJson).toList(),
      status: status,
      completedObjectKeys: {
        for (final key in v.list('completedObjectKeys'))
          if (key is String) key else throw const ContractError('backupJob.completedObjectKeys', 'Expected a string.'),
      },
      snapshotUploaded: v.boolean('snapshotUploaded'),
      lastError: v.optionalString('lastError'),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'bucket': bucket,
        'region': region,
        'prefix': prefix,
        'writerDeviceID': writerDeviceID,
        'testBuild': testBuild,
        'localManifestBytes': base64.encode(localManifestBytes),
        'manifestBytes': base64.encode(manifestBytes),
        'commitBytes': base64.encode(commitBytes),
        'commitKey': commitKey,
        'uploads': uploads.map((u) => u.toJson()).toList(),
        'status': _status.name,
        'completedObjectKeys': (_completedObjectKeys.toList()..sort()).cast<Object?>(),
        'snapshotUploaded': _snapshotUploaded,
        if (_lastError != null) 'lastError': _lastError,
      };

  @override
  bool operator ==(Object other) => other is BackupJob && _deep.equals(toJson(), other.toJson());

  @override
  int get hashCode => _deep.hash(toJson());
}

abstract final class BackupQueue {
  /// Persist this result before calling [advance]. A retry must reuse its exact bytes and request ID.
  static Future<BackupJob> prepare(CosClient client, AppSession session, {required int now, String? requestID}) async {
    final plan = BackupPlan.manifest(session, now: now);
    if (client.configuration.prefix != plan.prefix ||
        client.configuration.bucket != session.link.bucket ||
        client.configuration.region != session.link.region) {
      throw const CosFailure(ConnectionFailure.configuration);
    }
    final previous = await FamilyReader.latest(client, plan.prefix);
    if (previous != null && previous.commit.writerDeviceID.toUpperCase() != session.deviceID.toUpperCase()) {
      throw const CosFailure(ConnectionFailure.conflict);
    }
    final manifestBytes = V1Json.encodeManifest(_completeSnapshot(previous?.manifest, plan.manifest, plan.prefix));
    final manifestHash = Digest.sha256Hex(manifestBytes);
    final duplicate = previous?.commit.manifestHash == manifestHash;
    final commit = duplicate
        ? previous!.commit
        : V1Commit(
            sequence: (previous?.commit.sequence ?? 0) + 1,
            parentHash: previous?.commitHash,
            writerDeviceID: V1Ids.canonical(session.deviceID, path: 'writerDeviceID'),
            manifestHash: manifestHash,
            manifestKey: '${plan.prefix}snapshots/$manifestHash.json',
            createdAt: now,
            requestID: V1Ids.canonical(requestID ?? newUuid(), path: 'requestID'),
          );
    final commitKey = plan.prefix + V1Json.commitRelativeKey(commit.sequence);
    if (!duplicate) {
      V1Validator.validateCommit(
          commit: commit,
          key: commitKey,
          prefix: plan.prefix,
          previous: previous?.commit,
          previousHash: previous?.commitHash);
    }
    final unique = <String, BackupUpload>{};
    for (final upload in BackupPlan.uploads(session)) {
      final existing = unique[upload.objectKey];
      if (existing != null && (existing.sha256 != upload.sha256 || existing.byteCount != upload.byteCount)) {
        throw const CosFailure(ConnectionFailure.contentMismatch);
      }
      unique.putIfAbsent(upload.objectKey, () => upload);
    }
    final keys = unique.keys.toList()..sort();
    return BackupJob._(
      id: commit.requestID,
      bucket: client.configuration.bucket,
      region: client.configuration.region,
      prefix: plan.prefix,
      writerDeviceID: commit.writerDeviceID,
      testBuild: session.testBuild,
      localManifestBytes: plan.bytes,
      manifestBytes: manifestBytes,
      commitBytes: V1Json.encodeCommit(commit),
      commitKey: commitKey,
      uploads: [for (final key in keys) unique[key]!],
      status: duplicate ? BackupJobStatus.completed : BackupJobStatus.queued,
      completedObjectKeys: duplicate ? keys.toSet() : {},
      snapshotUploaded: duplicate,
      lastError: null,
    );
  }

  /// [shouldPause] is consulted before every object and before snapshot/commit publication.
  /// [persist] runs after each durable step; a failing persist stops before any further write.
  static Future<void> advance(
    CosClient client,
    AppSession session,
    BackupJob job, {
    required String Function(String relativePath) resolve,
    required FutureOr<void> Function(BackupJob job) persist,
    bool Function() shouldPause = _never,
  }) async {
    validate(job, session, client);
    if (job._status == BackupJobStatus.completed || job._status == BackupJobStatus.paused) return;
    Future<bool> pauseIfAsked() async {
      if (!shouldPause()) return false;
      job.pause();
      await persist(job.copy());
      return true;
    }

    try {
      if (await _verifyRemoteBase(client, job)) {
        await _complete(job, persist);
        return;
      }
      job._status = BackupJobStatus.uploading;
      job._lastError = null;
      await persist(job.copy());
      for (final upload in job.uploads) {
        if (await pauseIfAsked()) return;
        if (job._completedObjectKeys.contains(upload.objectKey)) {
          final head = await client.head(upload.objectKey);
          if (head != null && head.byteCount == upload.byteCount && head.sha256 == upload.sha256) continue;
        }
        await client.putImmutableFile(
            key: upload.objectKey,
            filePath: resolve(upload.relativePath),
            byteCount: upload.byteCount,
            sha256: upload.sha256,
            contentType: upload.contentType);
        final head = await client.head(upload.objectKey);
        if (head == null || head.byteCount != upload.byteCount || head.sha256 != upload.sha256) {
          throw const CosFailure(ConnectionFailure.contentMismatch);
        }
        job._completedObjectKeys.add(upload.objectKey);
        await persist(job.copy());
      }
      if (await pauseIfAsked()) return;
      if (await _verifyRemoteBase(client, job, verifyResources: false)) {
        await _complete(job, persist);
        return;
      }
      final commit = job.commit;
      await client.putImmutable(key: commit.manifestKey, body: job.manifestBytes, contentType: 'application/json');
      if (!const ListEquality<int>().equals(await client.get(key: commit.manifestKey), job.manifestBytes)) {
        throw const CosFailure(ConnectionFailure.contentMismatch);
      }
      job._snapshotUploaded = true;
      await persist(job.copy());
      if (await pauseIfAsked()) return;
      if (await _verifyRemoteBase(client, job, verifyResources: false)) {
        await _complete(job, persist);
        return;
      }
      // Immutable PUT checks existing identical bytes, including after a lost response/restart.
      await client.putImmutable(key: job.commitKey, body: job.commitBytes, contentType: 'application/json');
      if (!const ListEquality<int>().equals(await client.get(key: job.commitKey), job.commitBytes)) {
        throw const CosFailure(ConnectionFailure.contentMismatch);
      }
      await _complete(job, persist);
    } catch (error) {
      job._status = BackupJobStatus.failed;
      job._lastError = switch (error) {
        CosFailure(:final failure) => failure.message,
        ContractError(:final message) => message,
        _ => '备份未完成，原件仍保存在本机，可稍后重试。',
      };
      try {
        await persist(job.copy());
      } catch (_) {}
      rethrow;
    }
  }

  static bool _never() => false;

  static Future<void> _complete(BackupJob job, FutureOr<void> Function(BackupJob) persist) async {
    job._completedObjectKeys.addAll(job.uploads.map((upload) => upload.objectKey));
    job._snapshotUploaded = true;
    job._status = BackupJobStatus.completed;
    job._lastError = null;
    await persist(job.copy());
  }

  static bool _includesLocal(V1Manifest manifest, V1Manifest local) {
    bool includes<T>(List<T> complete, List<T> frozen, String Function(T) id) {
      final indexed = {for (final value in complete) id(value).toUpperCase(): value};
      return frozen.every((value) => indexed[id(value).toUpperCase()] == value);
    }

    return includes(manifest.moments, local.moments, (value) => value.id) &&
        includes(manifest.assets, local.assets, (value) => value.id) &&
        includes(manifest.resources, local.resources, (value) => value.id) &&
        includes(manifest.anniversaries, local.anniversaries, (value) => value.id);
  }

  /// The persisted job is not a trusted source of old cloud data. Reconstruct its
  /// snapshot from this bucket's verified, current chain before allowing a PUT.
  /// Only the exact already-published job is an idempotent exception to the base
  /// head check; a different head requires a new plan, never a rewritten job.
  static Future<bool> _verifyRemoteBase(CosClient client, BackupJob job, {bool verifyResources = true}) async {
    final previous = await FamilyReader.latest(client, job.prefix);
    final commit = job.commit;
    if (previous?.commitHash == Digest.sha256Hex(job.commitBytes)) {
      return true;
    }
    if (previous?.commitHash != commit.parentHash) throw const CosFailure(ConnectionFailure.conflict);
    V1Validator.validateCommit(
        commit: commit,
        key: job.commitKey,
        prefix: job.prefix,
        previous: previous?.commit,
        previousHash: previous?.commitHash);
    final expected = _completeSnapshot(previous?.manifest, job.localManifest, job.prefix);
    if (!const ListEquality<int>().equals(V1Json.encodeManifest(expected), job.manifestBytes)) {
      throw const CosFailure(ConnectionFailure.contentMismatch);
    }
    if (verifyResources) {
      final localKeys = job.uploads.map((upload) => upload.objectKey).toSet();
      final checked = <String>{};
      for (final resource in expected.resources) {
        if (localKeys.contains(resource.objectKey) || !checked.add(resource.objectKey)) continue;
        final head = await client.head(resource.objectKey);
        if (head == null || head.byteCount != resource.byteCount || head.sha256 != resource.sha256) {
          throw const CosFailure(ConnectionFailure.contentMismatch);
        }
      }
    }
    return false;
  }

  /// Local-only/test-only records never participate in this merge: [local] is
  /// the independently validated frozen eligible plan. Asset/resource IDs are
  /// immutable across snapshots, including when another record still uses them.
  static V1Manifest _completeSnapshot(V1Manifest? base, V1Manifest local, String prefix) {
    final moments = {for (final value in base?.moments ?? <V1Moment>[]) value.id.toUpperCase(): value};
    final assets = {for (final value in base?.assets ?? <V1Asset>[]) value.id.toUpperCase(): value};
    final resources = {for (final value in base?.resources ?? <V1Resource>[]) value.id.toUpperCase(): value};
    final anniversaries = {for (final value in base?.anniversaries ?? <V1Anniversary>[]) value.id.toUpperCase(): value};
    for (final value in local.moments) {
      moments[value.id.toUpperCase()] = value;
    }
    for (final value in local.assets) {
      final previous = assets[value.id.toUpperCase()];
      if (previous != null && previous != value) throw const CosFailure(ConnectionFailure.contentMismatch);
      assets[value.id.toUpperCase()] = value;
    }
    for (final value in local.resources) {
      final previous = resources[value.id.toUpperCase()];
      if (previous != null && previous != value) throw const CosFailure(ConnectionFailure.contentMismatch);
      resources[value.id.toUpperCase()] = value;
    }
    for (final value in local.anniversaries) {
      anniversaries[value.id.toUpperCase()] = value;
    }
    final assetIDs = {for (final moment in moments.values) ...moment.assetIDs.map((id) => id.toUpperCase())};
    final retainedAssets = [for (final key in assetIDs) if (assets[key] != null) assets[key]!];
    final resourceIDs = {for (final asset in retainedAssets) ...asset.resourceIDs.map((id) => id.toUpperCase())};
    final manifest = V1Manifest(
      version: 2,
      moments: moments.values.toList()..sort((a, b) => a.id.compareTo(b.id)),
      assets: retainedAssets..sort((a, b) => a.id.compareTo(b.id)),
      resources: [for (final key in resourceIDs) if (resources[key] != null) resources[key]!]
        ..sort((a, b) => a.id.compareTo(b.id)),
      anniversaries: anniversaries.values.toList()..sort((a, b) => a.id.compareTo(b.id)),
    );
    V1Validator.validate(manifest: manifest, prefix: prefix);
    return manifest;
  }

  static void validate(BackupJob job, AppSession session, CosClient client) {
    final link = session.link;
    const configuration = CosFailure(ConnectionFailure.configuration);
    if (link is! CloudVerified ||
        link.bucket != job.bucket ||
        link.region != job.region ||
        session.testBuild != job.testBuild ||
        session.deviceID.toUpperCase() != job.writerDeviceID.toUpperCase() ||
        session.writerPrefix() != job.prefix ||
        client.configuration.prefix != job.prefix ||
        client.configuration.bucket != job.bucket ||
        client.configuration.region != job.region ||
        V1Layout.isLegacyRoot(job.prefix)) {
      throw configuration;
    }
    final manifest = job.manifest;
    final local = job.localManifest;
    final commit = job.commit;
    V1Validator.validate(manifest: manifest, prefix: job.prefix);
    V1Validator.validate(manifest: local, prefix: job.prefix);
    const mismatch = CosFailure(ConnectionFailure.contentMismatch);
    if (!_includesLocal(manifest, local) ||
        commit.requestID != job.id ||
        commit.writerDeviceID != job.writerDeviceID ||
        commit.manifestHash != Digest.sha256Hex(job.manifestBytes) ||
        commit.manifestKey != '${job.prefix}snapshots/${commit.manifestHash}.json' ||
        job.commitKey != job.prefix + V1Json.commitRelativeKey(commit.sequence) ||
        commit.sequence <= 0 ||
        commit.kind != 'snapshot') {
      throw mismatch;
    }
    final eligible = session.testBuild ? UploadEligibility.testOnly : UploadEligibility.eligible;
    final allowedIDs = {
      for (final m in session.moments)
        if (m.uploadEligibility == eligible && m.parent == session.identity) V1Ids.map(kind: 'record', localID: m.id),
    };
    final anniversaryIDs = session.backupAnniversaries().map((a) => a.id).toSet();
    if (!local.moments.every((m) => allowedIDs.contains(m.id)) ||
        !local.anniversaries.every((a) => anniversaryIDs.contains(a.id))) {
      throw configuration;
    }
    final resources = <String, V1Resource>{};
    for (final resource in local.resources) {
      resources.putIfAbsent(resource.objectKey, () => resource);
    }
    final uploadKeys = job.uploads.map((u) => u.objectKey).toSet();
    if (uploadKeys.length != resources.length ||
        !uploadKeys.containsAll(resources.keys) ||
        uploadKeys.length != job.uploads.length ||
        !resources.keys.toSet().containsAll(job._completedObjectKeys)) {
      throw mismatch;
    }
    for (final upload in job.uploads) {
      final resource = resources[upload.objectKey];
      if (resource == null ||
          upload.byteCount != resource.byteCount ||
          upload.sha256 != resource.sha256 ||
          upload.contentType != resource.contentType ||
          upload.relativePath.startsWith('/') ||
          upload.relativePath.contains(r'\') ||
          upload.relativePath.split('/').contains('..')) {
        throw mismatch;
      }
    }
  }
}
