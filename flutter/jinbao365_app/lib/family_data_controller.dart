import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:jinbao_core/jinbao_core.dart';

enum FamilyDataStatus { idle, preparing, prepared, waitingForNetwork, uploading, paused, failed, verified, restoring, cancelled }

class FamilyDataException implements Exception {
  final String code;
  const FamilyDataException(this.code);
  @override
  String toString() => 'FamilyDataException($code)';
}

class FamilyCellularDownloadRequired implements Exception {
  const FamilyCellularDownloadRequired();
}

class FamilyCopySummary {
  final String familyName;
  final int recordCount;
  final int mediaCount;
  final int anniversaryCount;
  final int byteCount;
  const FamilyCopySummary({required this.familyName, required this.recordCount,
    required this.mediaCount, required this.anniversaryCount, required this.byteCount});
  Map<String, Object?> toJson() => {'familyName': familyName, 'recordCount': recordCount,
    'mediaCount': mediaCount, 'anniversaryCount': anniversaryCount, 'byteCount': byteCount};
  factory FamilyCopySummary.fromJson(Map<String, dynamic> data) => FamilyCopySummary(
    familyName: familyDisplayText(data['familyName'] as String),
    recordCount: _integer(data['recordCount']), mediaCount: _integer(data['mediaCount']),
    anniversaryCount: _integer(data['anniversaryCount']), byteCount: _integer(data['byteCount']),
  );
}

/// Authenticated family copies use a separate journal and namespace. No method
/// writes an AppSession, edits its legacy paths, or takes over a restored archive.
/// Loading a journal never starts a transfer; every attempt needs a user action.
class FamilyDataController extends ChangeNotifier {
  final FamilyGatewayClient client;
  final Family selectedFamily;
  final AppSession Function() currentLocalSession;
  final String localDirectory;
  final FamilyArchiveClient _archive;
  final bool wifiOnlyUploads;
  final bool allowCellularOriginals;
  final Future<List<ConnectivityResult>> Function() _connectivityCheck;
  FamilyDataController({required this.client, required this.selectedFamily,
    required this.currentLocalSession, required String localDirectory,
    FamilyArchiveClient? archiveClient, this.wifiOnlyUploads = true, this.allowCellularOriginals = false,
    Future<List<ConnectivityResult>> Function()? connectivityCheck})
      : localDirectory = _canonicalAppRoot(localDirectory),
        _connectivityCheck = connectivityCheck ?? Connectivity().checkConnectivity,
        _archive = archiveClient ?? client.createArchiveClient() {
    if (_archive.origin != client.origin) throw const FamilyDataException('targetMismatch');
  }

  FamilyDataStatus status = FamilyDataStatus.idle;
  String? errorMessage;
  bool busy = false;
  bool showingCachedMetadata = false;
  GatewayFamilySnapshot? familySnapshot;
  List<FamilyArchiveRecord> records = const [];
  List<FamilyArchiveAnniversary> anniversaries = const [];
  List<FamilyArchiveModeration> moderations = const [];
  int moderationVersion = 0;
  Map<String, String> ownerNames = const {};
  FamilyArchiveRestoreResult? lastRestore;
  String? _restoreStage;
  String? _restoreSubjectID, _restoreMemberID, _restoreFingerprint;
  String? _restoreStorageID;
  Map<String, dynamic>? _frozenSource;
  _FamilyIntent? _intent;
  int _generation = 0;
  bool _disposed = false;
  bool _blockedDraft = false;
  int _authorizationEpoch = 0;
  String? _displaySessionBinding;
  _CachedFamilyMetadata? _pendingCache;
  Map<String, dynamic>? _mediaImportContext;
  int get authorizationEpoch => _authorizationEpoch;

  FamilyCopySummary? get pendingCopy => _intent?.summary;
  bool get hasIncompleteRestore => _restoreStage != null;
  bool get _preparedIntentPending => _intent != null && !const {
    FamilyDataStatus.verified, FamilyDataStatus.cancelled,
  }.contains(_intent!.state);
  bool get hasUnpreparedSource => (_frozenSource != null || _blockedDraft) && !_preparedIntentPending;
  bool get hasPendingUpload => _preparedIntentPending || _frozenSource != null || _blockedDraft;
  bool get hasRetainedMediaDraft {
    final source = _frozenSource?['source'];
    return source is Map && source['kind'] == 'media' && source['assets'] is List &&
      !_preparedIntentPending && !_blockedDraft;
  }
  int get retainedMediaCount => hasRetainedMediaDraft
      ? (((_frozenSource!['source'] as Map)['assets'] as List).length) : 0;
  String? get pendingConfirmationID => _preparedIntentPending ? Digest.sha256Hex(JsonWire.encode({
    'origin': _intent!.origin, 'familyID': _intent!.familyID, 'memberID': _intent!.memberID,
    'subjectID': _intent!.subjectID, 'deviceID': _intent!.deviceID,
    'manifestHash': _intent!.manifest.sha256, 'draftID': _intent!.draftID,
    'primaryStorageID': _intent!.primaryStorageID,
  })) : null;
  bool get canContribute => !showingCachedMetadata && familySnapshot != null &&
      familySnapshot!.currentMember.status == FamilyMemberStatus.active &&
      familySnapshot!.currentMember.role != FamilyRole.viewer;
  bool canEdit(FamilyArchiveRecord record) => canContribute &&
      record.ownerMemberID == familySnapshot!.currentMember.id && record.deletedAt == null && !isHidden(record);
  bool get canModerate => !showingCachedMetadata && familySnapshot?.currentMember.role == FamilyRole.admin;
  bool isHidden(FamilyArchiveRecord record) {
    FamilyArchiveModeration? latest;
    for (final event in moderations) {
      if (event.ownerMemberID == record.ownerMemberID && event.recordID == record.id &&
          (latest == null || latest.id < event.id)) latest = event;
    }
    return latest?.hidden ?? false;
  }
  String? get pendingDraftDescription {
    if (_frozenSource == null) return _blockedDraft ? '本机草稿校验未完成。请保留原记录，明确取消这次上传后再重新选择。' : null;
    if (_displaySessionBinding == null || _frozenSource!['authSessionBinding'] != _displaySessionBinding) {
      return '有一份保留的本机草稿。请登录原来的家庭成员后查看或重试。';
    }
    try {
      final source = Map<String, dynamic>.from(_frozenSource!['source'] as Map);
      return source['kind'] == 'text' ? '${source['title']}\n${source['note']}'
          : source['kind'] == 'media' ? '${(source['assets'] as List).length} 项已保留在本机的家庭照片/视频，尚未分享。'
          : '${(source['moments'] as List).length} 条冻结的本人记录，${(source['anniversaries'] as List).length} 个纪念日。';
    } catch (_) { return '本机草稿需要重新校验后才能上传。'; }
  }

  String get _scopeKey => Digest.sha256Hex(utf8.encode('${client.origin}|${selectedFamily.id}'));
  Directory get _stateDirectory => Directory('$localDirectory/.dayswith-family/$_scopeKey');
  File get _journal => File('${_stateDirectory.path}/intent.json');
  File get _cache => File('${_stateDirectory.path}/verified-metadata.json');
  File get _frozenFile => File('${_stateDirectory.path}/frozen-source.json');
  File get _restoreJournal => File('${_stateDirectory.path}/restore-intent.json');

  /// Reads only app-private, integrity-checked metadata. A cached role never
  /// grants permission. Even a formerly uploading intent reopens paused.
  Future<void> initialize() async {
    _clearMetadata();
    final initialBinding = await client.localCacheSessionBinding();
    if (_disposed) return;
    _ensurePrivateDirectory(_stateDirectory);
    try {
      if (_regular(_journal)) {
        _intent = _FamilyIntent.decode(_readJson(_journal));
        if (_intent!.origin != client.origin.toString() || _intent!.familyID != selectedFamily.id) {
          throw const FamilyDataException('targetMismatch');
        }
        if (_intent!.state != FamilyDataStatus.verified && _intent!.state != FamilyDataStatus.cancelled) {
          _intent = _intent!.withState(FamilyDataStatus.paused);
          _writeIntent();
        }
        status = _intent!.state;
      }
      if (_regular(_frozenFile)) {
        final frozen = _readJson(_frozenFile);
        if (frozen['version'] != 1 || frozen['origin'] != client.origin.toString() ||
            frozen['familyID'] != selectedFamily.id) throw const FamilyDataException('invalidState');
        if (Digest.sha256Hex(JsonWire.encode(frozen['source'])) != frozen['sourceSha256']) {
          throw const FamilyDataException('integrity');
        }
        familyStableID(frozen['draftID'] as String);
        if (frozen['state'] == 'pending') {
          _frozenSource = frozen;
          if (_intent?.draftID == frozen['draftID'] && _intent?.state == FamilyDataStatus.verified) {
            _completeFrozen('completed');
          } else if (_intent?.draftID == frozen['draftID'] && _intent?.state == FamilyDataStatus.cancelled) {
            _frozenSource = null;
          } else if (!_preparedIntentPending) {
            status = FamilyDataStatus.paused;
          }
        }
      }
      if (_regular(_restoreJournal)) {
        final restore = _readJson(_restoreJournal);
        if (restore['version'] != 1 || restore['origin'] != client.origin.toString() ||
            restore['familyID'] != selectedFamily.id) throw const FamilyDataException('invalidState');
        if (restore['state'] == 'incomplete') {
          _restoreStage = restore['stageDirectory'] as String?;
          _restoreSubjectID = familySubjectID(restore['subjectID'] as String);
          _restoreMemberID = familyStableID(restore['memberID'] as String);
          _restoreFingerprint = restore['sessionFingerprint'] as String;
          _restoreStorageID = restore['primaryStorageID'] as String;
          if (_restoreStage != null) {
            _validateRestoreStage(_restoreStage!, allowMissing: true);
            if (FileSystemEntity.typeSync(_restoreStage!, followLinks: false) == FileSystemEntityType.notFound) {
              _restoreStage = null;
              _persist(() => _writeRestoreIntent('stageUnavailable'));
            }
          }
        }
      }
      if (_regular(_cache)) {
        final data = _readJson(_cache);
        if (data['version'] != 1 || data['origin'] != client.origin.toString() ||
            data['familyID'] != selectedFamily.id) throw const FamilyDataException('invalidCache');
        if (initialBinding != null && data['authSessionBinding'] == initialBinding) {
        final manifests = _decodeCachedManifests(data['manifests']);
        final cachedModerations = (data['moderations'] as List).map(FamilyArchiveModeration.fromJson).toList();
        final cachedVersion = _integer(data['moderationVersion']);
        final catalog = FamilyArchiveCatalog(familyID: selectedFamily.id,
          snapshots: manifests.map((manifest) => FamilyArchiveSnapshot(scope: manifest.scope,
            sequence: manifest.sequence, sha256: manifest.sha256, byteCount: manifest.encode().length)).toList(),
          moderations: cachedModerations, moderationVersion: cachedVersion);
        catalog.visibleRecords(mergeFamilyArchiveRecords(manifests, familyID: selectedFamily.id));
        final names = Map<String, dynamic>.from(data['ownerNames'] as Map);
        final validatedNames = Map<String, String>.unmodifiable(names.map((id, name) =>
          MapEntry(familyStableID(id), familyDisplayText(name as String))));
        // Keep plaintext off the observable state until live authentication
        // succeeds or a same-session offline failure explicitly permits cache.
        _pendingCache = _CachedFamilyMetadata(initialBinding, manifests, catalog, validatedNames);
        }
      }
    } catch (_) {
      _blockedDraft = _regular(_frozenFile) || _regular(_journal);
      _intent = null;
      familySnapshot = null;
      records = const [];
      anniversaries = const [];
      ownerNames = const {};
      status = FamilyDataStatus.failed;
      errorMessage = '家庭本机副本未通过校验，已停止自动读取。原记录未改动。';
    }
    final afterBinding = await client.localCacheSessionBinding();
    if (_disposed) return;
    if (initialBinding == null || afterBinding != initialBinding) _clearMetadata();
    _notify();
    await refresh();
  }

  Future<void> refresh() async {
    final binding = await client.localCacheSessionBinding();
    if (_disposed) return;
    if (binding == null || _displaySessionBinding != null && binding != _displaySessionBinding) _clearMetadata();
    await _operation(() async {
    if (binding == null) throw const FamilyDataException('unauthenticated');
    final generation = _generation;
    final snapshot = await client.getFamily(selectedFamily.id);
    _checkGeneration(generation);
    final manifests = await _catalog(generation);
    final after = await client.getFamily(selectedFamily.id);
    _checkGeneration(generation);
    _sameMember(snapshot.currentMember, after.currentMember);
    _sameStorage(snapshot, after);
    await _checkBinding(binding);
    _checkGeneration(generation);
    final changedIdentity = familySnapshot != null &&
      (familySnapshot!.currentMember.id != after.currentMember.id ||
       familySnapshot!.currentMember.subjectID != after.currentMember.subjectID ||
       familySnapshot!.primaryStorageID != after.primaryStorageID);
    final verifiedModerations = moderations;
    final verifiedModerationVersion = moderationVersion;
    if (changedIdentity) _clearMetadata();
    moderations = verifiedModerations;
    moderationVersion = verifiedModerationVersion;
    _displaySessionBinding = binding;
    _pendingCache = null;
    _authorizeDisplay(after);
    ownerNames = Map.unmodifiable({for (final member in after.members) member.id: member.displayName});
    _display(manifests);
    showingCachedMetadata = false;
    _writeJson(_cache, {'version': 1, 'origin': client.origin.toString(),
      'familyID': selectedFamily.id, 'ownerNames': ownerNames,
      'authSessionBinding': binding,
      'moderations': moderations.map((event) => event.toJson()).toList(), 'moderationVersion': moderationVersion,
      'manifests': manifests.map(_encodeManifest).toList()});
    });
  }

  /// Freezes selected OWN local records before the first network operation.
  /// The draft has no authority or upload consent. Identity is obtained afresh
  /// before it becomes a reviewable immutable manifest.
  Future<void> prepareLocalCopy({Set<String>? recordIDs, bool includeAnniversaries = true}) async {
    if (busy) throw const FamilyDataException('busy');
    final session = currentLocalSession().copy();
    final owner = session.identity;
    if (owner == null) throw const FamilyDataException('sourceIdentityRequired');
    final moments = session.moments.where((moment) => moment.parent == owner && moment.trashedAt == null &&
        (recordIDs == null || recordIDs.contains(moment.id))).toList();
    if (recordIDs != null && moments.length != recordIDs.length) {
      throw const FamilyDataException('sourceSelectionMismatch');
    }
    final dates = includeAnniversaries
        ? session.anniversaries.where((item) => item.owner == owner && item.deletedAt == null).toList()
        : <LocalAnniversary>[];
    if (moments.isEmpty && dates.isEmpty) throw const FamilyDataException('emptySelection');
    _beginDraft({'kind': 'legacyCopy', 'moments': moments.map((m) => m.toJson()).toList(),
      'anniversaries': dates.map((a) => a.toJson()).toList(),
      'sessionFingerprint': _sessionFingerprint(session)});
    await _prepareLocalFrozen(session, moments, dates);
  }

  Future<void> _prepareLocalFrozen(AppSession session, List<LocalMoment> moments,
      List<LocalAnniversary> dates) => _prepare(session, (scope, previous) {
      final files = <String, String>{};
      final converted = <FamilyArchiveRecord>[];
      for (final moment in moments) {
        final recordID = V1Ids.map(kind: 'record', localID: moment.id);
        if (moderations.any((event) => event.ownerMemberID == scope.memberID && event.recordID == recordID) &&
            _hiddenKey(scope.memberID, recordID)) continue;
        final assets = <FamilyArchiveAsset>[];
        for (final asset in moment.assets) {
          final resources = <FamilyArchiveResource>[];
          for (final resource in asset.resources) {
            final digest = resource.sha256.toLowerCase();
            _validateRelative(resource.relativePath);
            resources.add(FamilyArchiveResource(id: V1Ids.map(kind: 'resource', localID: resource.id),
              role: resource.role, contentType: resource.contentType,
              originalFilename: BackupPlan.safeFilename(resource.originalFilename),
              byteCount: resource.byteCount, sha256: digest));
            files.putIfAbsent(scope.objectKey(digest), () => resource.relativePath);
          }
          assets.add(FamilyArchiveAsset(id: V1Ids.map(kind: 'asset', localID: asset.id),
            kind: asset.kind, capturedAt: asset.capturedAt, resources: resources));
        }
        converted.add(FamilyArchiveRecord(id: recordID,
          ownerMemberID: scope.memberID, writerDeviceID: scope.deviceID,
          revision: moment.revision < 1 ? 1 : moment.revision,
          occurredAt: moment.occurredAt, updatedAt: moment.updatedAt,
          deletedAt: moment.trashedAt, title: moment.title, note: moment.note, assets: assets));
      }
      final convertedDates = dates.map((date) => FamilyArchiveAnniversary(
        id: _anniversaryID(date.id), ownerMemberID: scope.memberID, title: date.title,
        date: date.date, revision: date.updatedAt < 1 ? 1 : date.updatedAt,
        deletedAt: date.deletedAt)).toList();
      final next = _successor(scope, previous, converted, convertedDates,
        baselineRecords: records.where((r) => r.ownerMemberID == scope.memberID).toList(),
        baselineDates: anniversaries.where((a) => a.ownerMemberID == scope.memberID).toList());
      final uniqueBytes = <String, int>{};
      for (final resource in converted.expand((r) => r.assets).expand((a) => a.resources)) {
        uniqueBytes[resource.sha256] = resource.byteCount;
      }
      return (next, files, FamilyCopySummary(familyName: selectedFamily.name,
        recordCount: converted.length, mediaCount: converted.fold(0, (n, r) => n + r.assets.length),
        anniversaryCount: convertedDates.length, byteCount: uniqueBytes.values.fold(0, (a, b) => a + b)));
    });

  /// A text edit is staged as a manual immutable snapshot; it is not published
  /// by typing or closing the editor. Only the freshly authenticated owner edits.
  Future<void> prepareText({FamilyArchiveRecord? editing, required String title,
    required String note, required int occurredAt}) async {
    if (!canContribute || editing != null && !canEdit(editing)) {
      throw const FamilyDataException('denied');
    }
    final session = currentLocalSession().copy();
    final recordID = editing?.id ?? newUuid();
    final now = DateTime.now().millisecondsSinceEpoch;
    _beginDraft({'kind': 'text', 'recordID': recordID, 'title': title, 'note': note,
      'occurredAt': occurredAt, 'expectedRevision': editing?.revision,
      'updatedAt': now,
      'editing': editing?.toJson(FamilyArchiveScope(familyID: selectedFamily.id,
        memberID: editing.ownerMemberID, deviceID: session.deviceID)),
      'sessionFingerprint': _sessionFingerprint(session)});
    await _prepareTextFrozen(session, recordID: recordID, title: title, note: note,
      occurredAt: occurredAt, now: now, editing: editing);
  }

  Future<void> _prepareTextFrozen(AppSession session, {required String recordID,
    required String title, required String note, required int occurredAt,
    required int now, FamilyArchiveRecord? editing}) => _prepare(session, (scope, previous) {
      if (editing != null && editing.ownerMemberID != scope.memberID) {
        throw const FamilyDataException('denied');
      }
      if (editing != null && isHidden(editing)) throw const FamilyDataException('denied');
      final latest = records.where((r) => r.id == recordID && r.ownerMemberID == scope.memberID);
      if (editing != null && (latest.isEmpty || latest.single.revision != editing.revision)) {
        throw const FamilyDataException('conflict');
      }
      final record = FamilyArchiveRecord(id: recordID, ownerMemberID: scope.memberID,
        writerDeviceID: scope.deviceID, revision: (editing?.revision ?? 0) + 1,
        occurredAt: occurredAt, updatedAt: now, title: title, note: note,
        assets: editing?.assets ?? const []);
      final next = _successor(scope, previous, [record], const [],
        baselineRecords: records.where((r) => r.ownerMemberID == scope.memberID).toList(),
        baselineDates: anniversaries.where((a) => a.ownerMemberID == scope.memberID).toList());
      return (next, <String, String>{}, FamilyCopySummary(familyName: selectedFamily.name,
        recordCount: 1, mediaCount: record.assets.length, anniversaryCount: 0, byteCount: 0));
    });

  Future<void> retryFrozenSource() async {
    if (busy || _frozenSource == null || _preparedIntentPending) {
      throw const FamilyDataException('noUnpreparedSource');
    }
    final source = Map<String, dynamic>.from(_frozenSource!['source'] as Map);
    if (Digest.sha256Hex(JsonWire.encode(source)) != _frozenSource!['sourceSha256']) {
      throw const FamilyDataException('integrity');
    }
    _blockedDraft = false;
    final session = currentLocalSession().copy();
    if (_sessionFingerprint(session) != source['sessionFingerprint']) {
      throw const FamilyDataException('targetMismatch');
    }
    if (source['kind'] == 'legacyCopy') {
      final moments = (source['moments'] as List).map((value) => LocalMoment.fromJson(value)).toList();
      final dates = (source['anniversaries'] as List).map((value) => LocalAnniversary.fromJson(value)).toList();
      if (moments.any((m) => m.parent != session.identity || m.trashedAt != null) ||
          dates.any((d) => d.owner != session.identity || d.deletedAt != null)) {
        throw const FamilyDataException('invalidState');
      }
      await _prepareLocalFrozen(session, moments, dates);
    } else if (source['kind'] == 'text') {
      final data = source['editing'];
      final editing = data == null ? null : FamilyArchiveRecord.fromJson(data,
        FamilyArchiveScope(familyID: selectedFamily.id,
          memberID: (data as Map)['ownerMemberID'] as String, deviceID: session.deviceID));
      await _prepareTextFrozen(session, recordID: source['recordID'] as String,
        title: source['title'] as String, note: source['note'] as String,
        occurredAt: _integer(source['occurredAt']), now: _integer(source['updatedAt']), editing: editing);
    } else if (source['kind'] == 'media') {
      await _prepareMediaFrozen(session, source);
    } else {
      throw const FamilyDataException('invalidState');
    }
  }

  /// Starts an unconfirmed, target-bound family media draft. The legacy Dad/Mom
  /// identity is unrelated to this authenticated member and is never assigned.
  void beginMediaImport() {
    if (_disposed || busy || !canContribute) throw const FamilyDataException('denied');
    if (hasRetainedMediaDraft) {
      _bindFrozen(familySnapshot!);
    } else {
      final session = currentLocalSession().copy();
      final now = DateTime.now().millisecondsSinceEpoch;
      _beginDraft({'kind': 'media', 'recordID': newUuid(), 'title': '家庭照片与视频', 'note': '',
        'occurredAt': now, 'updatedAt': now, 'assets': <Object?>[],
        'sessionFingerprint': _sessionFingerprint(session)});
    }
    _mediaImportContext = Map<String, dynamic>.from(_frozenSource!);
    _notify();
  }

  /// Persist each completed local copy before starting the next async import.
  /// Disposal stops network authority but deliberately still permits this final
  /// metadata retention under the already frozen old target. It never uploads.
  void retainImportedAsset(LocalAsset asset) {
    final copy = asset.copy();
    for (final resource in copy.resources) { _validateRelative(resource.relativePath); }
    if (!hasRetainedMediaDraft) {
      final context = _mediaImportContext;
      if (context != null) {
        _writeJson(File('${_stateDirectory.path}/import-recovery-${newUuid()}.json'), {
          'version': 1, 'frozenTarget': context, 'asset': copy.toJson(), 'state': 'requiresExplicitReview',
        });
      }
      throw const FamilyDataException('importDraftChanged');
    }
    final source = Map<String, dynamic>.from(_frozenSource!['source'] as Map);
    final assets = List<Object?>.from(source['assets'] as List);
    final matches = assets.where((item) => (item as Map)['id'] == copy.id);
    if (matches.isNotEmpty) {
      if (JsonWire.encodeString(matches.single) != JsonWire.encodeString(copy.toJson())) {
        throw const FamilyDataException('integrity');
      }
      return;
    }
    if (assets.length >= 30) throw const FamilyDataException('mediaLimit');
    assets.add(copy.toJson());
    final nextSource = <String, Object?>{...source, 'assets': assets};
    final next = <String, dynamic>{..._frozenSource!, 'source': nextSource,
      'sourceSha256': Digest.sha256Hex(JsonWire.encode(nextSource))};
    _frozenSource = next;
    if (!_persist(() => _writeJson(_frozenFile, next))) {
      _notify();
      throw const FamilyDataException('persistence');
    }
    status = FamilyDataStatus.paused;
    _notify();
  }

  Future<void> prepareRetainedMedia() async {
    if (!hasRetainedMediaDraft) throw const FamilyDataException('noMediaDraft');
    await retryFrozenSource();
  }

  Future<void> _prepareMediaFrozen(AppSession session, Map<String, dynamic> source) => _prepare(session, (scope, previous) {
    final locals = (source['assets'] as List).map((item) => LocalAsset.fromJson(item)).toList();
    if (locals.isEmpty || locals.length > 30) throw const FamilyDataException('emptySelection');
    final files = <String, String>{};
    final bytes = <String, int>{};
    final assets = <FamilyArchiveAsset>[];
    for (final local in locals) {
      final resources = <FamilyArchiveResource>[];
      for (final resource in local.resources) {
        _validateRelative(resource.relativePath);
        final digest = resource.sha256.toLowerCase();
        resources.add(FamilyArchiveResource(id: V1Ids.map(kind: 'resource', localID: resource.id),
          role: resource.role, contentType: resource.contentType,
          originalFilename: BackupPlan.safeFilename(resource.originalFilename),
          byteCount: resource.byteCount, sha256: digest));
        files[scope.objectKey(digest)] = resource.relativePath;
        bytes[digest] = resource.byteCount;
      }
      assets.add(FamilyArchiveAsset(id: V1Ids.map(kind: 'asset', localID: local.id),
        kind: local.kind, capturedAt: local.capturedAt, resources: resources));
    }
    final record = FamilyArchiveRecord(id: source['recordID'] as String, ownerMemberID: scope.memberID,
      writerDeviceID: scope.deviceID, revision: 1, occurredAt: _integer(source['occurredAt']),
      updatedAt: _integer(source['updatedAt']), title: source['title'] as String,
      note: source['note'] as String, assets: assets);
    final manifest = _successor(scope, previous, [record], const [],
      baselineRecords: records.where((item) => item.ownerMemberID == scope.memberID).toList(),
      baselineDates: anniversaries.where((item) => item.ownerMemberID == scope.memberID).toList());
    return (manifest, files, FamilyCopySummary(familyName: selectedFamily.name,
      recordCount: 1, mediaCount: assets.length, anniversaryCount: 0,
      byteCount: bytes.values.fold<int>(0, (sum, count) => sum + count)));
  });

  void _beginDraft(Map<String, Object?> source) {
    if (busy) throw const FamilyDataException('busy');
    if (hasPendingUpload) throw const FamilyDataException('pendingIntentRequiresReview');
    _generation++;
    _intent = null;
    _ensurePrivateDirectory(_stateDirectory);
    _preserveFrozenBeforeReplace();
    final frozen = <String, dynamic>{
      'version': 1, 'origin': client.origin.toString(), 'familyID': selectedFamily.id,
      'deviceID': currentLocalSession().deviceID, 'draftID': newUuid(),
      'state': 'pending', 'source': source, 'sourceSha256': Digest.sha256Hex(JsonWire.encode(source)),
      'authSessionBinding': _displaySessionBinding,
    };
    _frozenSource = frozen;
    if (!_persist(() => _writeJson(_frozenFile, frozen))) {
      _notify();
      throw const FamilyDataException('persistence');
    }
    if (familySnapshot != null && !showingCachedMetadata) _bindFrozen(familySnapshot!);
  }

  Future<void> _prepare(AppSession frozen,
      (FamilyArchiveManifest, Map<String, String>, FamilyCopySummary) Function(
          FamilyArchiveScope, FamilyArchiveManifest?) convert) => _operation(() async {
    status = FamilyDataStatus.preparing;
    _notify();
    final generation = _generation;
    final fingerprint = _sessionFingerprint(frozen);
    final binding = await client.localCacheSessionBinding();
    if (binding == null) throw const FamilyDataException('unauthenticated');
    final draft = _frozenSource;
    if (draft == null) throw const FamilyDataException('noUnpreparedSource');
    if (draft['targetBound'] != true && draft['authSessionBinding'] != null &&
        draft['authSessionBinding'] != binding) throw const FamilyDataException('targetMismatch');
    // Pin the non-authoritative session partition before the first auth HTTP
    // await too; a failed member-binding save must not permit a silent rebind.
    _frozenSource = {...draft, 'authSessionBinding': binding};
    _writeJson(_frozenFile, _frozenSource!);
    final snapshot = await client.getFamily(selectedFamily.id);
    _checkSource(generation, fingerprint);
    await _checkBinding(binding);
    _checkSource(generation, fingerprint);
    _bindFrozen(snapshot, authSessionBinding: binding);
    if (snapshot.primaryStorageID == null) throw const FamilyDataException('storageUnavailable');
    if (snapshot.currentMember.role == FamilyRole.viewer) throw const FamilyDataException('denied');
    final manifests = await _catalog(generation);
    _checkSource(generation, fingerprint);
    final scope = FamilyArchiveScope(familyID: selectedFamily.id,
      memberID: snapshot.currentMember.id, deviceID: frozen.deviceID);
    final chain = manifests.where((manifest) => manifest.scope == scope).toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    // Fresh data also detects conflicting revisions from another device.
    _display(manifests);
    final (manifest, files, summary) = convert(scope, chain.isEmpty ? null : chain.last);
    final after = await client.getFamily(selectedFamily.id);
    _checkSource(generation, fingerprint);
    _sameMember(snapshot.currentMember, after.currentMember);
    _sameStorage(snapshot, after);
    await _checkBinding(binding);
    _checkSource(generation, fingerprint);
    _intent = _FamilyIntent(origin: client.origin.toString(), familyID: selectedFamily.id,
      draftID: _frozenSource!['draftID'] as String,
      primaryStorageID: after.primaryStorageID!,
      subjectID: after.currentMember.subjectID, memberID: after.currentMember.id,
      deviceID: scope.deviceID, sessionFingerprint: fingerprint, manifest: manifest,
      sourceFiles: Map.unmodifiable(files), summary: summary, state: FamilyDataStatus.prepared);
    _writeIntent();
    _displaySessionBinding = binding;
    _authorizeDisplay(after);
    showingCachedMetadata = false;
    status = FamilyDataStatus.prepared;
  });

  /// The call itself is explicit consent. Resume is never scheduled by load,
  /// refresh, a network change, or an application lifecycle callback.
  Future<void> confirmAndUpload() => _operation(() async {
    final intent = _intent;
    if (intent == null || !_preparedIntentPending) throw const FamilyDataException('noIntent');
    final generation = _generation;
    final binding = await client.localCacheSessionBinding();
    if (binding == null) throw const FamilyDataException('unauthenticated');
    _checkSource(generation, intent.sessionFingerprint);
    final snapshot = await client.getFamily(selectedFamily.id);
    _checkSource(generation, intent.sessionFingerprint);
    _checkIntentMember(intent, snapshot.currentMember, snapshot.primaryStorageID);
    final network = await _connectivityCheck();
    _checkSource(generation, intent.sessionFingerprint);
    if (network.isEmpty || network.contains(ConnectivityResult.none) ||
        wifiOnlyUploads && !_unmetered(network)) {
      _intent = intent.withState(FamilyDataStatus.waitingForNetwork);
      status = FamilyDataStatus.waitingForNetwork;
      _writeIntent();
      _notify();
      return;
    }
    final files = <String, String>{};
    for (final entry in intent.sourceFiles.entries) {
      files[entry.key] = _resolveLocal(entry.value);
    }
    _intent = intent.withState(FamilyDataStatus.uploading);
    status = FamilyDataStatus.uploading;
    _writeIntent();
    _notify();
    final receipt = await _archive.publishManifest(intent.manifest, sourceFiles: files,
      shouldPause: () => _interrupted(generation, intent.sessionFingerprint));
    _checkSource(generation, intent.sessionFingerprint);
    final after = await client.getFamily(selectedFamily.id);
    _checkSource(generation, intent.sessionFingerprint);
    _checkIntentMember(intent, after.currentMember, after.primaryStorageID);
    await _checkBinding(binding);
    _checkSource(generation, intent.sessionFingerprint);
    if (receipt.scope != intent.manifest.scope || receipt.sequence != intent.manifest.sequence ||
        receipt.sha256 != intent.manifest.sha256) throw const FamilyDataException('integrity');
    _intent = intent.withState(FamilyDataStatus.verified);
    _writeIntent();
    _completeFrozen('completed');
    status = FamilyDataStatus.verified;
    _authorizeDisplay(after);
    showingCachedMetadata = false;
    // A successful response is not a full independent device restore.
  });

  void pause() {
    _generation++;
    var persisted = true;
    if (_preparedIntentPending) {
      _intent = _intent!.withState(FamilyDataStatus.paused);
      persisted = _persist(_writeIntent);
    }
    status = FamilyDataStatus.paused;
    if (!persisted) errorMessage = _persistenceMessage;
    _notify();
  }

  void cancel() {
    _generation++;
    var persisted = true;
    if (_intent != null) {
      _intent = _intent!.withState(FamilyDataStatus.cancelled);
      persisted = _persist(_writeIntent);
    }
    persisted = _persist(() => _completeFrozen('cancelled')) && persisted;
    if (_blockedDraft) {
      final cleared = _persist(() {
        _preserveFrozenBeforeReplace();
        _writeJson(_frozenFile, {'version': 1, 'origin': client.origin.toString(),
          'familyID': selectedFamily.id, 'draftID': newUuid(), 'state': 'cancelled',
          'source': <String, Object?>{}, 'sourceSha256': Digest.sha256Hex(JsonWire.encode(<String, Object?>{}))});
      });
      if (cleared) _blockedDraft = false;
      persisted = cleared && persisted;
    }
    status = FamilyDataStatus.cancelled;
    if (!persisted) errorMessage = _persistenceMessage;
    _notify();
  }

  Future<void> restoreIsolated() => _operation(() async {
    final generation = _generation;
    final fingerprint = _sessionFingerprint(currentLocalSession());
    final binding = await client.localCacheSessionBinding();
    if (binding == null) throw const FamilyDataException('unauthenticated');
    final before = await client.getFamily(selectedFamily.id);
    _checkSource(generation, fingerprint);
    if (before.primaryStorageID == null) throw const FamilyDataException('storageUnavailable');
    if (_restoreStage != null && (_restoreSubjectID != before.currentMember.subjectID ||
        _restoreMemberID != before.currentMember.id || _restoreFingerprint != fingerprint ||
        _restoreStorageID != before.primaryStorageID)) {
      throw const FamilyDataException('targetMismatch');
    }
    _restoreSubjectID = before.currentMember.subjectID;
    _restoreMemberID = before.currentMember.id;
    _restoreFingerprint = fingerprint;
    _restoreStorageID = before.primaryStorageID;
    _writeRestoreIntent('incomplete');
    status = FamilyDataStatus.restoring;
    _notify();
    final parent = Directory('$localDirectory/family-restores');
    _ensurePrivateDirectory(parent);
    try {
      final result = await _archive.restoreFamily(familyID: selectedFamily.id,
        restoreParent: parent, resumeDirectory: _restoreStage,
        onStageCreated: (stage) {
          _validateRestoreStage(stage);
          _restoreStage = stage;
          _writeRestoreIntent('incomplete');
        },
        shouldPause: () => _interrupted(generation, fingerprint));
      // The core client already published the verified stage into a new final
      // directory. Never leave a vanished .pending pointer across another await.
      _restoreStage = null;
      _writeRestoreIntent('completedUnconfirmed', completedDirectory: result.directory);
      final after = await client.getFamily(selectedFamily.id);
      _checkSource(generation, fingerprint);
      _sameMember(before.currentMember, after.currentMember);
      _sameStorage(before, after);
      await _checkBinding(binding);
      _checkSource(generation, fingerprint);
      _writeRestoreIntent('completed', completedDirectory: result.directory);
      lastRestore = result;
      _authorizeDisplay(after);
      status = FamilyDataStatus.verified;
    } on FamilyArchiveClientException catch (error) {
      _restoreStage = error.stageDirectory;
      if (_restoreStage != null) _validateRestoreStage(_restoreStage!);
      if (!_persist(() => _writeRestoreIntent('incomplete'))) throw const FamilyDataException('persistence');
      rethrow;
    }
  });

  Future<String> loadPreview(FamilyArchiveRecord record, FamilyArchiveAsset asset) {
    final known = _knownAsset(record, asset.id);
    final previews = known.resources.where((resource) => resource.role == 'preview');
    if (previews.length != 1) throw const FamilyDataException('integrity');
    return _loadMedia(record, previews.single, original: false);
  }

  Future<String> loadOriginal(FamilyArchiveRecord record, FamilyArchiveAsset asset,
      {bool allowCellular = false}) {
    final known = _knownAsset(record, asset.id);
    final role = switch (known.kind) {
      'video' => 'video', 'photo' => 'photo', 'livePhoto' => 'livePhotoImage',
      'motionPhoto' => 'motionPhoto', _ => throw const FamilyDataException('unsupportedMedia'),
    };
    final originals = known.resources.where((resource) => resource.role == role);
    if (originals.isEmpty) throw const FamilyDataException('integrity');
    return _loadMedia(record, originals.first, original: true, allowCellular: allowCellular);
  }

  FamilyArchiveAsset _knownAsset(FamilyArchiveRecord record, String assetID) {
    final matches = records.where((current) => current.id == record.id &&
      current.ownerMemberID == record.ownerMemberID && current.revision == record.revision);
    if (matches.length != 1 || matches.single.deletedAt != null || isHidden(matches.single)) {
      throw const FamilyDataException('denied');
    }
    final assets = matches.single.assets.where((asset) => asset.id == assetID);
    if (assets.length != 1) throw const FamilyDataException('integrity');
    return assets.single;
  }

  Future<String> _loadMedia(FamilyArchiveRecord record, FamilyArchiveResource resource,
      {required bool original, bool allowCellular = false}) async {
    final expected = familySnapshot;
    final generation = _generation;
    final fingerprint = _sessionFingerprint(currentLocalSession());
    try {
      final binding = await client.localCacheSessionBinding();
      if (binding == null || binding != _displaySessionBinding || expected == null || showingCachedMetadata) {
        throw const FamilyDataException('unauthenticated');
      }
      final before = await client.getFamily(selectedFamily.id);
      _checkSource(generation, fingerprint);
      _sameMember(expected.currentMember, before.currentMember);
      _sameStorage(expected, before);
      final catalog = await _archive.loadCatalog(selectedFamily.id,
        shouldPause: () => _interrupted(generation, fingerprint));
      catalog.visibleRecords(records);
      moderations = catalog.moderations;
      moderationVersion = catalog.moderationVersion;
      if (isHidden(record)) throw const FamilyDataException('denied');
      if (original) {
        final network = await _connectivityCheck();
        _checkSource(generation, fingerprint);
        if (network.isEmpty || network.contains(ConnectivityResult.none)) throw const FamilyDataException('offline');
        if (!_unmetered(network) && !allowCellularOriginals && !allowCellular) {
          throw const FamilyCellularDownloadRequired();
        }
      }
      final scope = FamilyArchiveScope(familyID: selectedFamily.id,
        memberID: record.ownerMemberID, deviceID: record.writerDeviceID);
      final path = await _archive.loadResource(scope: scope, resource: resource,
        cacheParent: Directory('$localDirectory/family-media-cache'),
        shouldPause: () => _interrupted(generation, fingerprint));
      final after = await client.getFamily(selectedFamily.id);
      _checkSource(generation, fingerprint);
      _sameMember(before.currentMember, after.currentMember);
      _sameStorage(before, after);
      final finalCatalog = await _archive.loadCatalog(selectedFamily.id,
        shouldPause: () => _interrupted(generation, fingerprint));
      finalCatalog.visibleRecords(records);
      moderations = finalCatalog.moderations;
      moderationVersion = finalCatalog.moderationVersion;
      if (isHidden(record)) throw const FamilyDataException('denied');
      await _checkBinding(binding);
      _checkSource(generation, fingerprint);
      _notify();
      return path;
    } catch (error) {
      final denied = error is FamilyGatewayException && const {
        FamilyGatewayFailure.unauthenticated, FamilyGatewayFailure.denied, FamilyGatewayFailure.revoked,
      }.contains(error.failure) || error is FamilyArchiveClientException && const {
        FamilyArchiveClientFailure.unauthenticated, FamilyArchiveClientFailure.denied, FamilyArchiveClientFailure.revoked,
      }.contains(error.failure) || error is FamilyDataException && const {
        'targetMismatch', 'denied', 'unauthenticated',
      }.contains(error.code);
      if (denied) {
        _clearMetadata();
        _generation++;
        _notify();
      }
      if (error is FamilyCellularDownloadRequired) rethrow;
      throw const FamilyDataException('mediaUnavailable');
    }
  }

  Future<List<FamilyArchiveManifest>> _catalog(int generation) async {
    final catalog = await _archive.loadCatalog(selectedFamily.id,
      shouldPause: () => _disposed || generation != _generation);
    final descriptors = catalog.snapshots;
    if (descriptors.fold<int>(0, (size, descriptor) => size + descriptor.byteCount) > 8 * 1024 * 1024) {
      throw const FamilyDataException('metadataLimit');
    }
    final manifests = <FamilyArchiveManifest>[];
    for (final descriptor in descriptors) {
      _checkGeneration(generation);
      manifests.add(await _archive.getManifest(descriptor,
        shouldPause: () => _disposed || generation != _generation));
    }
    _validateChains(manifests);
    final after = await _archive.loadCatalog(selectedFamily.id,
      shouldPause: () => _disposed || generation != _generation);
    if (after.fingerprint != catalog.fingerprint) {
      throw const FamilyDataException('conflict');
    }
    catalog.visibleRecords(mergeFamilyArchiveRecords(manifests, familyID: selectedFamily.id));
    moderations = List.unmodifiable(catalog.moderations);
    moderationVersion = catalog.moderationVersion;
    return manifests;
  }

  bool _hiddenKey(String owner, String record) {
    FamilyArchiveModeration? latest;
    for (final event in moderations) {
      if (event.ownerMemberID == owner && event.recordID == record &&
          (latest == null || latest.id < event.id)) latest = event;
    }
    return latest?.hidden ?? false;
  }

  Future<void> moderateRecord(FamilyArchiveRecord record, {required bool hidden}) => _operation(() async {
    if (!canModerate) throw const FamilyDataException('denied');
    final generation = _generation;
    final expected = familySnapshot!;
    final current = await client.getFamily(selectedFamily.id);
    _checkGeneration(generation);
    _sameMember(expected.currentMember, current.currentMember);
    _sameStorage(expected, current);
    if (current.currentMember.role != FamilyRole.admin) throw const FamilyDataException('denied');
    await _archive.moderateRecord(familyID: selectedFamily.id, ownerMemberID: record.ownerMemberID,
      recordID: record.id, expectedRevision: record.revision, hidden: hidden);
    _checkGeneration(generation);
    status = FamilyDataStatus.verified;
  });

  void _display(List<FamilyArchiveManifest> manifests) {
    records = mergeFamilyArchiveRecords(manifests, familyID: selectedFamily.id)
        .toList()..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    final dates = <String, FamilyArchiveAnniversary>{};
    final revisions = <String, String>{};
    for (final manifest in manifests) {
      for (final item in manifest.anniversaries) {
        final key = '${item.ownerMemberID}:${item.id}';
        final revisionKey = '$key:${item.revision}';
        final fingerprint = JsonWire.encodeString(item.toJson());
        if (revisions[revisionKey] != null && revisions[revisionKey] != fingerprint) {
          throw const FamilyDataException('conflict');
        }
        revisions[revisionKey] = fingerprint;
        if (dates[key] == null || dates[key]!.revision < item.revision) dates[key] = item;
      }
    }
    anniversaries = List.unmodifiable(dates.values);
  }

  Future<void> _operation(Future<void> Function() operation) async {
    if (_disposed) throw const FamilyDataException('disposed');
    if (busy) throw const FamilyDataException('busy');
    final generation = _generation;
    busy = true;
    errorMessage = null;
    _notify();
    try {
      await operation();
    } catch (error) {
      if (_disposed || generation != _generation) return;
      final binding = await client.localCacheSessionBinding();
      if (_disposed || generation != _generation) return;
      if (_authorizationFailure(error) || binding == null) {
        _clearMetadata();
      } else if (binding != _displaySessionBinding && !_showPendingCache(binding)) {
        _clearMetadata();
      } else {
        familySnapshot = null;
        _authorizationEpoch++;
        showingCachedMetadata = records.isNotEmpty || anniversaries.isNotEmpty;
      }
      status = error is FamilyArchiveClientException && error.failure == FamilyArchiveClientFailure.paused
          ? FamilyDataStatus.paused : FamilyDataStatus.failed;
      if (_preparedIntentPending) {
        _intent = _intent!.withState(status);
        if (!_persist(_writeIntent)) {
          errorMessage = _persistenceMessage;
          return;
        }
      }
      errorMessage = error is FileSystemException || error is FamilyDataException && error.code == 'persistence'
          ? _persistenceMessage : _friendlyError(error);
    } finally {
      busy = false;
      _notify();
    }
  }

  void _checkIntentMember(_FamilyIntent intent, GatewayMember member, String? storageID) {
    if (intent.origin != client.origin.toString() || intent.familyID != selectedFamily.id ||
        intent.subjectID != member.subjectID || intent.memberID != member.id ||
        member.status != FamilyMemberStatus.active || member.role == FamilyRole.viewer ||
        storageID != intent.primaryStorageID ||
        intent.deviceID != familyStableID(currentLocalSession().deviceID)) {
      throw const FamilyDataException('targetMismatch');
    }
  }
  void _sameMember(GatewayMember before, GatewayMember after) {
    if (before.id != after.id || before.subjectID != after.subjectID ||
        before.role != after.role || after.status != FamilyMemberStatus.active) {
      throw const FamilyDataException('targetMismatch');
    }
  }
  void _sameStorage(GatewayFamilySnapshot before, GatewayFamilySnapshot after) {
    if (before.primaryStorageID != after.primaryStorageID) throw const FamilyDataException('targetMismatch');
  }
  void _authorizeDisplay(GatewayFamilySnapshot snapshot) {
    if (familySnapshot?.currentMember.id != snapshot.currentMember.id ||
        familySnapshot?.currentMember.subjectID != snapshot.currentMember.subjectID ||
        familySnapshot?.primaryStorageID != snapshot.primaryStorageID || showingCachedMetadata) {
      _authorizationEpoch++;
    }
    familySnapshot = snapshot;
  }
  void _clearMetadata() {
    familySnapshot = null;
    records = const [];
    anniversaries = const [];
    ownerNames = const {};
    moderations = const [];
    moderationVersion = 0;
    lastRestore = null;
    showingCachedMetadata = false;
    _displaySessionBinding = null;
    _pendingCache = null;
    _authorizationEpoch++;
  }
  bool _showPendingCache(String binding) {
    final cache = _pendingCache;
    if (cache == null || cache.binding != binding) return false;
    try {
      _display(cache.manifests);
      moderations = cache.catalog.moderations;
      moderationVersion = cache.catalog.moderationVersion;
      ownerNames = cache.ownerNames;
      showingCachedMetadata = true;
      familySnapshot = null;
      _displaySessionBinding = binding;
      _pendingCache = null;
      return true;
    } catch (_) {
      _clearMetadata();
      return false;
    }
  }
  Future<void> _checkBinding(String binding) async {
    final latest = await client.localCacheSessionBinding();
    if (latest == null || latest != binding) throw const FamilyDataException('targetMismatch');
  }
  bool _authorizationFailure(Object error) =>
      error is FamilyGatewayException && const {FamilyGatewayFailure.unauthenticated,
        FamilyGatewayFailure.denied, FamilyGatewayFailure.revoked}.contains(error.failure) ||
      error is FamilyArchiveClientException && const {FamilyArchiveClientFailure.unauthenticated,
        FamilyArchiveClientFailure.denied, FamilyArchiveClientFailure.revoked}.contains(error.failure) ||
      error is FamilyDataException && const {'targetMismatch', 'unauthenticated', 'denied'}.contains(error.code);
  static const _persistenceMessage = '本机保存未完成，操作已停止。暂停或取消可能尚未写入磁盘；重新打开也不会自动上传。请检查空间或权限后重试。';
  bool _persist(void Function() write) {
    try { write(); return true; }
    catch (_) { errorMessage = _persistenceMessage; return false; }
  }
  void _checkGeneration(int generation) {
    if (_disposed || generation != _generation) throw const FamilyDataException('paused');
  }
  void _checkSource(int generation, String fingerprint) {
    _checkGeneration(generation);
    if (_sessionFingerprint(currentLocalSession()) != fingerprint) {
      throw const FamilyDataException('targetMismatch');
    }
  }
  bool _interrupted(int generation, String fingerprint) => _disposed ||
      generation != _generation || _sessionFingerprint(currentLocalSession()) != fingerprint;
  String _sessionFingerprint(AppSession session) => Digest.sha256Hex(JsonWire.encode({
    'deviceID': familyStableID(session.deviceID), 'identity': session.identity?.folder,
    'link': session.link.toJson(),
  }));

  String _resolveLocal(String relative) {
    _validateRelative(relative);
    _ensurePrivateDirectory(Directory(localDirectory), create: false);
    var path = Directory(localDirectory).absolute.path;
    final components = relative.split('/');
    for (var index = 0; index < components.length; index++) {
      path = '$path${Platform.pathSeparator}${components[index]}';
      final expected = index == components.length - 1 ? FileSystemEntityType.file : FileSystemEntityType.directory;
      if (FileSystemEntity.typeSync(path, followLinks: false) != expected) {
        throw const FamilyDataException('invalidLocalPath');
      }
    }
    return path;
  }

  void _writeIntent() {
    _ensurePrivateDirectory(_stateDirectory);
    if (_regular(_journal)) {
      try {
        _FamilyIntent.decode(_readJson(_journal));
      } catch (_) {
        _preserveLocalBeforeReplace(_journal, 'retained-intents');
      }
    }
    _writeJson(_journal, _intent!.toJson());
  }
  void _bindFrozen(GatewayFamilySnapshot snapshot, {String? authSessionBinding}) {
    final frozen = _frozenSource;
    if (frozen == null) throw const FamilyDataException('noUnpreparedSource');
    if (frozen['targetBound'] == true &&
        (frozen['boundSubjectID'] != snapshot.currentMember.subjectID ||
         frozen['boundMemberID'] != snapshot.currentMember.id ||
         frozen['boundStorageID'] != snapshot.primaryStorageID)) {
      throw const FamilyDataException('targetMismatch');
    }
    final bound = <String, dynamic>{...frozen, 'targetBound': true,
      'boundSubjectID': snapshot.currentMember.subjectID, 'boundMemberID': snapshot.currentMember.id,
      'boundStorageID': snapshot.primaryStorageID,
      'authSessionBinding': authSessionBinding ?? frozen['authSessionBinding']};
    _writeJson(_frozenFile, bound);
    _frozenSource = bound;
  }
  void _completeFrozen(String state) {
    if (_frozenSource == null) return;
    _writeJson(_frozenFile, {..._frozenSource!, 'state': state});
    _frozenSource = null;
  }

  // Cancelling upload does not authorize losing the only local text/media
  // selection when another draft starts. Keep prior bytes independently of the
  // rotating working journal, including an unreadable draft explicitly cleared.
  void _preserveFrozenBeforeReplace() =>
      _preserveLocalBeforeReplace(_frozenFile, 'retained-drafts');

  void _preserveLocalBeforeReplace(File source, String folderName) {
    if (!_regular(source)) return;
    if (source.lengthSync() > 16 * 1024 * 1024) {
      throw const FamilyDataException('tooLarge');
    }
    final bytes = source.readAsBytesSync();
    final digest = Digest.sha256Hex(bytes);
    final folder = Directory('${_stateDirectory.path}/$folderName');
    _ensurePrivateDirectory(folder);
    final target = File('${folder.path}/$digest.json');
    if (_regular(target)) {
      if (target.lengthSync() != bytes.length || Digest.sha256Hex(target.readAsBytesSync()) != digest) {
        throw const FamilyDataException('integrity');
      }
      return;
    }
    final temporary = File('${target.path}.tmp-${newUuid()}');
    temporary.createSync(exclusive: true);
    try {
      temporary.writeAsBytesSync(bytes, flush: true);
      if (FileSystemEntity.typeSync(target.path, followLinks: false) != FileSystemEntityType.notFound) {
        throw const FamilyDataException('invalidLocalPath');
      }
      temporary.renameSync(target.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }
  void _validateRestoreStage(String stage, {bool allowMissing = false}) {
    final parent = Directory('$localDirectory/family-restores').absolute.path;
    final directory = Directory(stage).absolute;
    if (directory.parent.path != parent ||
        !RegExp(r'^\.family-restore-[A-F0-9-]{36}\.pending$').hasMatch(directory.path.split(Platform.pathSeparator).last)) {
      throw const FamilyDataException('invalidState');
    }
    if (allowMissing && FileSystemEntity.typeSync(directory.path, followLinks: false) == FileSystemEntityType.notFound) {
      _ensurePrivateDirectory(directory.parent, create: false);
      return;
    }
    _ensurePrivateDirectory(directory, create: false);
  }
  void _writeRestoreIntent(String state, {String? completedDirectory}) {
    _writeJson(_restoreJournal, {'version': 1, 'origin': client.origin.toString(),
      'familyID': selectedFamily.id, 'subjectID': _restoreSubjectID, 'memberID': _restoreMemberID,
      'sessionFingerprint': _restoreFingerprint, 'primaryStorageID': _restoreStorageID,
      'stageDirectory': _restoreStage, 'state': state, 'completedDirectory': completedDirectory});
  }
  void _notify() { if (!_disposed) notifyListeners(); }
  @override
  void dispose() {
    if (_disposed) return;
    familySnapshot = null;
    _authorizationEpoch++;
    try { pause(); } catch (_) { /* Stop generation even when private storage is unavailable. */ }
    finally { _disposed = true; super.dispose(); }
  }
}

class _FamilyIntent {
  final String origin, familyID, subjectID, memberID, deviceID, sessionFingerprint, draftID, primaryStorageID;
  final FamilyArchiveManifest manifest;
  final Map<String, String> sourceFiles;
  final FamilyCopySummary summary;
  final FamilyDataStatus state;
  const _FamilyIntent({required this.origin, required this.familyID, required this.subjectID,
    required this.memberID, required this.deviceID, required this.sessionFingerprint,
    required this.manifest, required this.sourceFiles, required this.summary, required this.state,
    required this.draftID, required this.primaryStorageID});
  _FamilyIntent withState(FamilyDataStatus next) => _FamilyIntent(origin: origin, familyID: familyID,
    subjectID: subjectID, memberID: memberID, deviceID: deviceID, sessionFingerprint: sessionFingerprint,
    manifest: manifest, sourceFiles: sourceFiles, summary: summary, state: next,
    draftID: draftID, primaryStorageID: primaryStorageID);
  Map<String, Object?> toJson() => {'version': 1, 'origin': origin, 'familyID': familyID,
    'subjectID': subjectID, 'memberID': memberID, 'deviceID': deviceID,
    'sessionFingerprint': sessionFingerprint, 'draftID': draftID, 'manifest': _encodeManifest(manifest),
    'primaryStorageID': primaryStorageID,
    'sourceFiles': sourceFiles, 'summary': summary.toJson(), 'state': state.name};
  factory _FamilyIntent.decode(Map<String, dynamic> data) {
    if (data['version'] != 1) throw const FamilyDataException('invalidIntent');
    final manifest = _decodeManifest(data['manifest']);
    if (manifest.scope.familyID != data['familyID'] || manifest.scope.memberID != data['memberID'] ||
        manifest.scope.deviceID != data['deviceID']) throw const FamilyDataException('invalidIntent');
    final files = Map<String, String>.from(data['sourceFiles'] as Map);
    for (final path in files.values) { _validateRelative(path); }
    final keys = manifest.records.expand((r) => r.assets).expand((a) => a.resources)
        .map((r) => manifest.scope.objectKey(r.sha256)).toSet();
    if (files.keys.any((key) => !keys.contains(key))) throw const FamilyDataException('invalidIntent');
    return _FamilyIntent(origin: data['origin'] as String, familyID: familyStableID(data['familyID'] as String),
      subjectID: familySubjectID(data['subjectID'] as String), memberID: manifest.scope.memberID,
      deviceID: manifest.scope.deviceID, sessionFingerprint: data['sessionFingerprint'] as String,
      draftID: familyStableID(data['draftID'] as String),
      primaryStorageID: familyDisplayText(data['primaryStorageID'] as String, max: 256),
      manifest: manifest, sourceFiles: Map.unmodifiable(files),
      summary: FamilyCopySummary.fromJson(Map<String, dynamic>.from(data['summary'] as Map)),
      state: FamilyDataStatus.values.byName(data['state'] as String));
  }
}

class _CachedFamilyMetadata {
  final String binding;
  final List<FamilyArchiveManifest> manifests;
  final FamilyArchiveCatalog catalog;
  final Map<String, String> ownerNames;
  const _CachedFamilyMetadata(this.binding, this.manifests, this.catalog, this.ownerNames);
}

FamilyArchiveManifest _successor(FamilyArchiveScope scope, FamilyArchiveManifest? previous,
    List<FamilyArchiveRecord> changed, List<FamilyArchiveAnniversary> dates, {
    List<FamilyArchiveRecord> baselineRecords = const [],
    List<FamilyArchiveAnniversary> baselineDates = const [],
  }) {
  final records = {for (final item in previous?.records ?? <FamilyArchiveRecord>[]) item.id: item};
  for (final item in baselineRecords) { records[item.id] = item; }
  for (final item in changed) {
    final old = records[item.id];
    if (old != null && (old.deletedAt != null && item.deletedAt == null || item.revision < old.revision || item.revision == old.revision &&
        JsonWire.encodeString(item.toJson(scope)) != JsonWire.encodeString(old.toJson(scope)))) {
      throw const FamilyDataException('conflict');
    }
    records[item.id] = item;
  }
  final anniversaries = {for (final item in previous?.anniversaries ?? <FamilyArchiveAnniversary>[]) item.id: item};
  for (final item in baselineDates) { anniversaries[item.id] = item; }
  for (final item in dates) {
    final old = anniversaries[item.id];
    if (old != null && (old.deletedAt != null && item.deletedAt == null || item.revision < old.revision || item.revision == old.revision &&
        JsonWire.encodeString(item.toJson()) != JsonWire.encodeString(old.toJson()))) {
      throw const FamilyDataException('conflict');
    }
    anniversaries[item.id] = item;
  }
  final next = FamilyArchiveManifest(scope: scope, sequence: (previous?.sequence ?? 0) + 1,
    parentHash: previous?.sha256, records: records.values.toList(), anniversaries: anniversaries.values.toList());
  next.validateSuccessor(previous);
  return next;
}

void _validateChains(List<FamilyArchiveManifest> manifests) {
  final chains = <FamilyArchiveScope, List<FamilyArchiveManifest>>{};
  for (final manifest in manifests) {
    chains.putIfAbsent(manifest.scope, () => []).add(manifest);
  }
  for (final chain in chains.values) {
    chain.sort((a, b) => a.sequence.compareTo(b.sequence));
    FamilyArchiveManifest? previous;
    for (final manifest in chain) { manifest.validateSuccessor(previous); previous = manifest; }
  }
}
String _anniversaryID(String localID) {
  try { return familyStableID(localID); } catch (_) {
    return V1Ids.uuidV5(namespace: V1Ids.namespace, name: 'anniversary:$localID').toUpperCase();
  }
}
Map<String, Object?> _encodeManifest(FamilyArchiveManifest manifest) => {
  'scope': {'familyID': manifest.scope.familyID, 'memberID': manifest.scope.memberID, 'deviceID': manifest.scope.deviceID},
  'bytes': base64Encode(manifest.encode()), 'sha256': manifest.sha256,
};
FamilyArchiveManifest _decodeManifest(Object? value) {
  final data = Map<String, dynamic>.from(value as Map);
  final scope = Map<String, dynamic>.from(data['scope'] as Map);
  final bytes = base64Decode(data['bytes'] as String);
  if (Digest.sha256Hex(bytes) != data['sha256']) throw const FamilyDataException('integrity');
  return FamilyArchiveManifest.decode(bytes, expectedScope: FamilyArchiveScope(
    familyID: scope['familyID'] as String, memberID: scope['memberID'] as String,
    deviceID: scope['deviceID'] as String));
}
List<FamilyArchiveManifest> _decodeCachedManifests(Object? value) {
  if (value is! List || value.length > 10000) throw const FamilyDataException('invalidCache');
  final result = value.map(_decodeManifest).toList();
  if (result.fold<int>(0, (size, manifest) => size + manifest.encode().length) > 8 * 1024 * 1024) {
    throw const FamilyDataException('metadataLimit');
  }
  _validateChains(result);
  return result;
}
int _integer(Object? value) {
  if (value is! int || value < 0 || value > 9007199254740991) throw const FamilyDataException('invalidState');
  return value;
}
String _friendlyError(Object error) {
  final code = error is FamilyDataException ? error.code :
      error is FamilyArchiveClientException ? error.failure.name : '';
  return switch (code) {
    'targetMismatch' => '家庭登录成员或存储目标已变化，请保留草稿并重新确认正确目标。',
    'conflict' => '家庭中已有更新的记录。原内容未覆盖，请取消这次选择后勾选新记录，或刷新后编辑家庭记录。',
    'metadataLimit' => '家庭清单超过当前本机校验上限，请分批整理后重试。',
    'invalidLocalPath' || 'integrity' => '所选原件缺失、路径不安全或校验不一致，已停止上传。原记录未删除。',
    'storageUnavailable' => '家庭存储尚未就绪，草稿保留在本机，不会自动上传。',
    'emptySelection' => '家庭草稿还没有可分享的媒体，请继续添加或取消这次选择。',
    _ => '家庭操作未完成，请检查网络或重新登录后重试。',
  };
}
bool _unmetered(List<ConnectivityResult> network) =>
    network.contains(ConnectivityResult.wifi) || network.contains(ConnectivityResult.ethernet);
void _validateRelative(String path) {
  if (path.isEmpty || path.startsWith('/') || path.contains(r'\') || path.contains(':') ||
      path.split('/').any((component) => component.isEmpty || component == '.' || component == '..') ||
      path.runes.any((r) => r < 32 || r == 127)) throw const FamilyDataException('invalidLocalPath');
}
void _ensurePrivateDirectory(Directory directory, {bool create = true}) {
  final absolute = directory.absolute;
  var current = Platform.isWindows ? absolute.path.substring(0, 3) : Platform.pathSeparator;
  for (final component in absolute.path.substring(current.length).split(Platform.pathSeparator).where((s) => s.isNotEmpty)) {
    current = current.endsWith(Platform.pathSeparator) ? '$current$component' : '$current${Platform.pathSeparator}$component';
    var type = FileSystemEntity.typeSync(current, followLinks: false);
    if (type == FileSystemEntityType.notFound && create) { Directory(current).createSync(); type = FileSystemEntityType.directory; }
    if (type != FileSystemEntityType.directory) throw const FamilyDataException('invalidLocalPath');
  }
}
String _canonicalAppRoot(String path) {
  // The host supplies the app's trusted private directory. iOS may spell it
  // through the OS /var alias; resolve that root once, then reject symlinks in
  // every relative resource/state path beneath the pinned canonical root.
  final root = Directory(path).absolute.resolveSymbolicLinksSync();
  _ensurePrivateDirectory(Directory(root), create: false);
  return root;
}
bool _regular(File file) {
  final type = FileSystemEntity.typeSync(file.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return false;
  if (type != FileSystemEntityType.file) throw const FamilyDataException('invalidLocalPath');
  return true;
}
Map<String, dynamic> _readJson(File file) {
  if (!_regular(file) || file.lengthSync() > 16 * 1024 * 1024) throw const FamilyDataException('invalidState');
  return Map<String, dynamic>.from(jsonDecode(file.readAsStringSync()) as Map);
}
void _writeJson(File target, Map<String, Object?> data) {
  _ensurePrivateDirectory(target.parent);
  _regular(target);
  final bytes = utf8.encode(jsonEncode(data));
  if (bytes.length > 16 * 1024 * 1024) throw const FamilyDataException('tooLarge');
  final temporary = File('${target.path}.tmp-${newUuid()}');
  temporary.createSync(exclusive: true);
  try { temporary.writeAsBytesSync(bytes, flush: true); temporary.renameSync(target.path); }
  finally { if (temporary.existsSync()) temporary.deleteSync(); }
}
