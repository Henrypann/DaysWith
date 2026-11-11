import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:jinbao_core/jinbao_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_legacy_upgrade.dart';
import 'child_profile.dart';
import 'credential_store.dart';
import 'media_import.dart';

enum ShellTab { timeline, anniversaries, review, my }

sealed class PreviewLoad {
  const PreviewLoad();
}

class PreviewLoading extends PreviewLoad {
  const PreviewLoading();
}

class PreviewReady extends PreviewLoad {
  final String relativePath;
  const PreviewReady(this.relativePath);
}

class PreviewFailed extends PreviewLoad {
  final String message;
  const PreviewFailed(this.message);
}

/// Thrown when an original would be downloaded over a metered network without permission.
class CellularDownloadRequired implements Exception {
  const CellularDownloadRequired();
}

/// Port of ios-app/Jinbao365/AppModel.swift. Every change goes through [_mutate], which
/// saves the archive before the new state becomes visible.
class AppModel extends ChangeNotifier {
  /// Like the iOS Debug build: records back up only to `life/v1/test/`, and the placeholder
  /// connection is offered. Build with `--dart-define=JINBAO_TEST_BUILD=false` for family writes.
  static const isTestBuild = bool.fromEnvironment('JINBAO_TEST_BUILD', defaultValue: true);

  final CredentialStore _credentials = CredentialStore();
  late final String directory;

  AppModel();

  /// A ready model over [session] whose archive and media live in [directory].
  /// Used by widget tests and the promo renderer; nothing touches the network.
  AppModel.forSession(this.session,
      {required this.directory, this.child, this.localFirst = false, Set<String>? localFirstRecords}) {
    if (localFirstRecords != null) this.localFirstRecords.addAll(localFirstRecords);
    bucket = session.link.bucket ?? bucket;
    region = session.link.region ?? region;
    _store = ArchiveStore('$directory/archive.json');
    ready = true;
  }
  late ArchiveStore _store;
  late AppSession session;

  bool ready = false;
  String? archiveRecoveryMessage;
  String bucket = '';
  String region = 'ap-shanghai';
  bool busy = false;
  String? banner;
  bool bannerIsError = false;
  ShellTab tab = ShellTab.timeline;
  bool backupRunning = false;
  bool allowCellularOriginals = false;

  /// 4.0: the child profile and the local-first choice live in this phone's preferences.
  ChildProfile? child;
  bool localFirst = false;

  /// IDs of records made while recording on this phone without a connection. Only these may
  /// later join a backup; imported, placeholder and test records never do.
  final Set<String> localFirstRecords = {};
  bool _disposed = false;
  final Map<String, PreviewLoad> previewLoads = {};
  final Map<String, PreviewLoad> originalLoads = {};

  bool _refreshing = false;
  int _connectionGeneration = 0;
  bool _stopBackup = false;
  Timer? _automaticBackup;
  SharedPreferences? _preferences;
  bool _legacyUpgradePending = false;

  static int get now => DateTime.now().millisecondsSinceEpoch;

  Future<void> start() async {
    final base = await getApplicationSupportDirectory();
    directory = '${base.path}${Platform.pathSeparator}Jinbao365';
    await Directory(directory).create(recursive: true);
    _store = ArchiveStore('$directory/archive.json');
    _preferences = await SharedPreferences.getInstance();
    allowCellularOriginals = _preferences?.getBool('allowCellularOriginals') ?? false;
    localFirst = _preferences?.getBool('localFirst') ?? false;
    localFirstRecords.addAll(_preferences?.getStringList('localFirstRecords') ?? const []);
    child = ChildProfile.decode(
        nickname: _preferences?.getString('childNickname'), birthday: _preferences?.getString('childBirthday'));
    AppSession? loaded;
    try {
      if (Platform.isAndroid) {
        _legacyUpgradePending = !File(_store.path).existsSync() && !File(_store.recoveryPath).existsSync();
        await AndroidLegacyUpgrade(credentials: _credentials).migrateIfNeeded(
          store: _store,
          directory: directory,
          testBuild: isTestBuild,
        );
        _legacyUpgradePending = false;
      }
      loaded = _store.load()?.session();
    } catch (_) {
      archiveRecoveryMessage = _legacyUpgradePending
          ? '旧版本档案暂时无法迁移。原有身份、记录和云存储连接均已保留，请解锁手机后重新读取档案。'
          : '本地档案暂时无法读取。现有文件已保留，请恢复上一份有效档案后继续。';
    }
    final restored = loaded ?? AppSession(deviceID: newUuid().toLowerCase(), testBuild: isTestBuild);
    restored.testBuild = isTestBuild;
    session = restored;
    bucket = restored.link.bucket ?? bucket;
    region = restored.link.region ?? region;
    if (archiveRecoveryMessage == null) {
      try {
        _store.save(PersistedArchive.fromSession(restored));
      } catch (_) {
        archiveRecoveryMessage = '本地档案暂时无法保存。现有记录已保留，请检查存储空间后重试。';
      }
    }
    ready = true;
    notifyListeners();
    activate();
  }

  void recoverArchive() {
    try {
      final restored = _store.restoreRecovery().session()..testBuild = isTestBuild;
      _store.save(PersistedArchive.fromSession(restored));
      session = restored;
      _legacyUpgradePending = false;
      bucket = restored.link.bucket ?? bucket;
      region = restored.link.region ?? region;
      archiveRecoveryMessage = null;
      _setBanner('已恢复有效档案，原损坏文件仍保留。');
    } catch (_) {
      _setBanner('暂时没有可恢复的有效副本，原档案未改动。', error: true);
    }
  }

  Future<void> retryArchive() async {
    if (busy) return;
    busy = true;
    try {
      if (_legacyUpgradePending) {
        await AndroidLegacyUpgrade(credentials: _credentials).migrateIfNeeded(
          store: _store,
          directory: directory,
          testBuild: isTestBuild,
        );
        _legacyUpgradePending = false;
      }
      final restored = _store.load()?.session();
      if (restored == null) throw const CosFailure(ConnectionFailure.notFound);
      restored.testBuild = isTestBuild;
      _store.save(PersistedArchive.fromSession(restored));
      session = restored;
      bucket = restored.link.bucket ?? bucket;
      region = restored.link.region ?? region;
      archiveRecoveryMessage = null;
      notifyListeners();
      activate();
    } catch (error) {
      show(error);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    // Work that finishes after the app shell is gone must not reach removed listeners.
    _disposed = true;
    _automaticBackup?.cancel();
    _stopBackup = true;
    _connectionGeneration++;
    super.dispose();
  }

  /// Whether the timeline is shown: connected, or the user chose to record on this phone first.
  bool get showsTimeline => session.phase == AppPhase.timeline || (session.identity != null && localFirst);

  Future<void> chooseLocalFirst() async {
    localFirst = true;
    banner = null;
    notifyListeners();
    await _preferences?.setBool('localFirst', true);
  }

  Future<bool> saveChild({required String nickname, required DateParts birthday}) async {
    final name = swiftTrim(nickname);
    final today = JinbaoCalendar.parts(now, const DeviceZone());
    if (name.isEmpty || name.length > ChildProfile.maxNicknameLength) {
      show(const ContractError('child', '请填写 1–12 字的小名。'));
      return false;
    }
    if (JinbaoCalendar.compare(birthday, today) > 0) {
      show(const ContractError('child', '生日不能晚于今天。'));
      return false;
    }
    child = ChildProfile(nickname: name, birthday: birthday);
    notifyListeners();
    await _preferences?.setString('childNickname', name);
    await _preferences?.setString('childBirthday', child!.storedBirthday);
    return true;
  }

  Future<void> clearChild() async {
    child = null;
    notifyListeners();
    await _preferences?.remove('childNickname');
    await _preferences?.remove('childBirthday');
  }

  bool get _recordingLocalFirst => localFirst && session.link is CloudMissing;

  void _rememberLocalFirst(String id) {
    if (localFirstRecords.add(id)) _preferences?.setStringList('localFirstRecords', localFirstRecords.toList());
  }

  /// Records made in local-first mode that can still be added to the backup.
  int get adoptableCount => session.link is CloudVerified ? session.adoptableCount(localFirstRecords) : 0;

  /// After explicit consent, the records made in local-first mode join the verified backup scope.
  int adoptLocalRecords() {
    if (busy || backupRunning) {
      show(const ContractError('backup', '请等待当前备份或验证完成后再试。'));
      return 0;
    }
    var adopted = 0;
    if (!_mutate((s) => adopted = s.adoptLocalOnlyRecords(localFirstRecords))) return 0;
    _setBanner(adopted == 0 ? '没有可以加入备份的本机记录。' : '已把 $adopted 条本机记录加入备份。');
    _scheduleAutomaticBackup();
    return adopted;
  }

  void selectTab(ShellTab value) {
    tab = value;
    notifyListeners();
  }

  void confirm(ParentIdentity parent) => _mutate((s) => s.confirmIdentity(parent));

  void connectPlaceholder() {
    if (!isTestBuild) return;
    if (busy || backupRunning) {
      show(const ContractError('backup', '请等待连接验证完成，或先暂停备份。'));
      return;
    }
    if (!_mutate((s) => s.connectPlaceholder(bucket: swiftTrim(bucket), region: swiftTrim(region)))) return;
    _connectionGeneration++;
    _refreshing = false;
    _setBanner('这是占位连接，没有保存密钥，也不会上传。');
  }

  Future<void> verify({required String secretID, required String secretKey, required String sessionToken}) async {
    if (busy || backupRunning) return;
    final credentials = StorageCredentials(
      secretID: swiftTrim(secretID),
      secretKey: swiftTrim(secretKey),
      sessionToken: sessionToken.isEmpty ? null : sessionToken,
    );
    final configuration = StorageConfiguration(bucket: swiftTrim(bucket), region: swiftTrim(region), prefix: 'life/v1/');
    try {
      configuration.validate();
      if (!credentials.isValid) throw const CosFailure(ConnectionFailure.configuration);
    } catch (error) {
      show(error);
      return;
    }
    _connectionGeneration++;
    _refreshing = false;
    final generation = _connectionGeneration;
    busy = true;
    banner = null;
    notifyListeners();
    try {
      final client = CosClient(
          configuration: configuration, credentials: credentials, transport: HttpObjectTransport(configuration));
      await client.list(prefix: ParentIdentity.dad.prefix);
      await client.list(prefix: ParentIdentity.mom.prefix);
      if (_connectionGeneration != generation) return;
      busy = false;
      final previous = await _credentials.load().catchError((_) => null);
      await _credentials.save(credentials);
      final ok = _mutate((s) {
        final changed = s.link.bucket != configuration.bucket || s.link.region != configuration.region;
        s.connectVerified(bucket: configuration.bucket, region: configuration.region);
        if (changed) {
          s.remote = [];
          s.remoteAnniversaries = [];
        }
        final job = s.backupJob;
        if (job != null &&
            (job.bucket != configuration.bucket ||
                job.region != configuration.region ||
                job.prefix != s.writerPrefix() ||
                job.testBuild != s.testBuild)) {
          s.backupJob = null;
        }
      });
      if (!ok) {
        if (previous != null) {
          await _credentials.save(previous);
        } else {
          await _credentials.delete();
        }
        return;
      }
      previewLoads.clear();
      originalLoads.clear();
      _setBanner('云存储已连接');
      _refreshing = false;
      refreshRemote();
      _scheduleAutomaticBackup();
    } catch (error) {
      if (_connectionGeneration != generation) return;
      busy = false;
      show(error);
    }
  }

  Future<void> disconnect() async {
    if (busy) {
      _setBanner('正在验证连接，请稍后再断开。');
      return;
    }
    if (backupRunning) {
      pauseBackup();
      _setBanner('正在暂停备份，完成当前文件后可断开连接。');
      return;
    }
    if (!_mutate((s) {
      s.disconnectCloud();
      s.remote = [];
      s.remoteAnniversaries = [];
    })) {
      return;
    }
    _connectionGeneration++;
    _refreshing = false;
    try {
      await _credentials.delete();
    } catch (error) {
      show(error);
      return;
    }
    previewLoads.clear();
    originalLoads.clear();
    _setBanner('已断开云存储。这台手机上的记录还在。');
  }

  void cancelCloudConfiguration() {
    if (busy) {
      _connectionGeneration++;
      busy = false;
      _refreshing = false;
    }
    bucket = session.link.bucket ?? bucket;
    region = session.link.region ?? region;
    notifyListeners();
  }

  // Drafts and records.

  bool beginDraft() => session.draft != null || _mutate((s) => s.beginDraft(now: now));

  bool beginEditing(String id) => _mutate((s) => s.beginEdit(id: id, now: now));

  bool updateDraft(String title, String note) => _mutate((s) => s.updateDraft(title: title, note: note), quiet: true);

  void updateDraftOccurredAt(int millis) => _mutate((s) => s.setDraftOccurredAt(millis));

  void moveDraftAsset(int from, int to) => _mutate((s) => s.moveAsset(from: from, to: to));

  void removeAsset(String id) => _mutate((s) => s.removeAsset(id));

  bool discardDraft() => _mutate((s) => s.discardDraft());

  bool importAssets(List<LocalAsset> assets) {
    if (assets.isEmpty) return true;
    final ok = _mutate((s) {
      if (s.draft == null) s.beginDraft(now: now);
      s.addAssets(assets);
    });
    if (ok) _setBanner('已加入 ${assets.length} 项媒体，原文件保存在这台手机。');
    return ok;
  }

  Future<LocalAsset> storeMedia(String path, String filename, ImportProvenance provenance) =>
      MediaImport.store(source: path, filename: filename, provenance: provenance, directory: directory);

  bool commitDraft() {
    final local = _recordingLocalFirst && session.draft?.originalMomentID == null;
    String? saved;
    if (!_mutate((s) => saved = s.commitDraft(now: now).id)) return false;
    if (local && saved != null) _rememberLocalFirst(saved!);
    tab = ShellTab.timeline;
    notifyListeners();
    _scheduleAutomaticBackup();
    return true;
  }

  void trashMoment(String id) {
    if (_mutate((s) => s.trashMoment(id: id, now: now))) _scheduleAutomaticBackup();
  }

  void restoreMoment(String id) {
    if (_mutate((s) => s.restoreMoment(id: id, now: now))) _scheduleAutomaticBackup();
  }

  bool saveAnniversary({String? id, required String title, required String date}) {
    final local = _recordingLocalFirst && id == null;
    String? saved;
    final ok = _mutate((s) => saved = s.saveAnniversary(id: id, title: title, date: date, now: now).id);
    if (ok && local && saved != null) _rememberLocalFirst(saved!);
    if (ok) _scheduleAutomaticBackup();
    return ok;
  }

  void deleteAnniversary(String id) {
    if (_mutate((s) => s.deleteAnniversary(id: id, now: now))) _scheduleAutomaticBackup();
  }

  Future<void> setAllowCellularOriginals(bool allowed) async {
    allowCellularOriginals = allowed;
    notifyListeners();
    await _preferences?.setBool('allowCellularOriginals', allowed);
  }

  int get localStorageBytes {
    var total = 0;
    try {
      for (final entity in Directory(directory).listSync(recursive: true, followLinks: false)) {
        if (entity is File) total += entity.lengthSync();
      }
    } catch (_) {}
    return total;
  }

  // Family read.

  Future<CosClient> _client(String prefix) async {
    final link = session.link;
    final credentials = await _credentials.load();
    if (credentials == null) throw const CosFailure(ConnectionFailure.secureStorage);
    final configuration = StorageConfiguration(bucket: link.bucket ?? '', region: link.region ?? '', prefix: prefix);
    return CosClient(configuration: configuration, credentials: credentials, transport: HttpObjectTransport(configuration));
  }

  Future<void> refreshRemote() async {
    final link = session.link;
    final owner = session.identity;
    if (_refreshing || archiveRecoveryMessage != null || link is! CloudVerified || owner == null) return;
    _refreshing = true;
    final generation = _connectionGeneration;
    try {
      final client = await _client('life/v1/');
      final remote = await FamilyReader.readArchive(client,
          owner: owner, deviceID: session.deviceID, testBuild: session.testBuild);
      if (_connectionGeneration != generation) return;
      _refreshing = false;
      if (session.link != link) return;
      _mutate((s) {
        s.remote = remote.moments;
        s.remoteAnniversaries = remote.anniversaries;
      });
    } catch (error) {
      if (_connectionGeneration == generation) {
        _refreshing = false;
        show(error);
      }
    }
  }

  // Backup.

  bool _backupMatchesScope(BackupJob job) {
    String? prefix;
    try {
      prefix = session.writerPrefix();
    } catch (_) {}
    return job.bucket == session.link.bucket &&
        job.region == session.link.region &&
        job.prefix == prefix &&
        job.testBuild == session.testBuild;
  }

  String get backupStatusTitle {
    if (session.link is! CloudVerified) return '仅保存在这台手机';
    final job = session.backupJob;
    if (job == null || !_backupMatchesScope(job)) return '尚未备份';
    switch (job.status) {
      case BackupJobStatus.queued:
        return '等待继续备份';
      case BackupJobStatus.uploading:
        return backupRunning ? '正在备份' : '备份已中断，可继续';
      case BackupJobStatus.paused:
        return '备份已暂停';
      case BackupJobStatus.failed:
        return '备份未完成';
      case BackupJobStatus.completed:
        try {
          final plan = BackupPlan.manifest(session, now: now);
          if (!job.matchesLocalPlan(plan)) return '有新的内容待备份';
        } catch (_) {}
        return '已备份';
    }
  }

  String get backupStatusDetail {
    if (session.link is! CloudVerified) return '未连接或占位连接时不会上传。连接后，可以选择把本机记录加入备份。';
    final job = session.backupJob;
    if (job == null || !_backupMatchesScope(job)) return '新建的可备份记录会在应用打开时自动备份。';
    return job.lastError ?? '原件已核验 ${job.completedCount} / ${job.totalCount}；本机记录始终保留。';
  }

  double? get backupProgress {
    final job = session.backupJob;
    if (job == null || !_backupMatchesScope(job)) return null;
    return job.progress;
  }

  void activate() {
    if (archiveRecoveryMessage != null || !ready) return;
    refreshRemote();
    final status = session.backupJob?.status;
    if (status == BackupJobStatus.queued || status == BackupJobStatus.uploading) {
      backupNow();
    } else if (status != BackupJobStatus.paused && status != BackupJobStatus.failed) {
      _scheduleAutomaticBackup();
    }
  }

  void _scheduleAutomaticBackup() {
    _automaticBackup?.cancel();
    if (session.link is! CloudVerified) return;
    final BackupManifestPlan plan;
    try {
      plan = BackupPlan.manifest(session, now: now);
    } catch (_) {
      return;
    }
    final job = session.backupJob;
    if (job?.status == BackupJobStatus.paused || job?.status == BackupJobStatus.failed) return;
    if (job != null &&
        job.status == BackupJobStatus.completed &&
        _backupMatchesScope(job) &&
        job.matchesLocalPlan(plan)) {
      return;
    }
    _automaticBackup = Timer(const Duration(milliseconds: 700), backupNow);
  }

  void pauseBackup() {
    _automaticBackup?.cancel();
    _stopBackup = true;
    if (!backupRunning) _mutate((s) => s.backupJob?.pause());
    _setBanner(backupRunning ? '正在暂停，当前文件完成后停止。' : '备份已暂停。');
  }

  Future<void> backupNow() async {
    if (backupRunning || busy || archiveRecoveryMessage != null) return;
    if (session.link is! CloudVerified) {
      _setBanner('占位连接不会上传。请在填写密钥后再备份。', error: true);
      return;
    }
    final snapshot = session.copy();
    final generation = _connectionGeneration;
    _stopBackup = false;
    backupRunning = true;
    notifyListeners();
    try {
      final prefix = snapshot.writerPrefix();
      final client = await _client(prefix);
      final existing = snapshot.backupJob;
      final BackupJob job;
      if (existing != null &&
          existing.status != BackupJobStatus.completed &&
          existing.prefix == prefix &&
          existing.bucket == snapshot.link.bucket &&
          existing.region == snapshot.link.region &&
          existing.testBuild == snapshot.testBuild) {
        job = existing.copy()..resume();
      } else {
        job = await BackupQueue.prepare(client, snapshot, now: now);
      }
      void checkpoint(BackupJob updated) {
        if (_connectionGeneration != generation ||
            session.link != snapshot.link ||
            session.deviceID != snapshot.deviceID ||
            archiveRecoveryMessage != null) {
          throw const CosFailure(ConnectionFailure.configuration);
        }
        final latest = session.copy()..backupJob = updated;
        _store.save(PersistedArchive.fromSession(latest));
        session = latest;
        notifyListeners();
      }

      checkpoint(job.copy());
      final root = Directory(directory).absolute.path;
      await BackupQueue.advance(client, snapshot, job,
          resolve: (relative) {
            final path = File('$root/$relative').absolute.path;
            if (relative.split('/').contains('..') || !path.startsWith(root)) {
              throw const CosFailure(ConnectionFailure.contentMismatch);
            }
            return path;
          },
          persist: checkpoint,
          shouldPause: () => _stopBackup);
      backupRunning = false;
      final completed = job.status == BackupJobStatus.completed;
      _setBanner(completed ? '已备份到云端，本机记录仍然保留。' : '备份已暂停，可稍后继续。');
      if (completed) _scheduleAutomaticBackup();
    } catch (error) {
      backupRunning = false;
      show(error);
    }
  }

  // Media files.

  String? filePath(String relative) {
    if (relative.isEmpty || relative.contains('..') || relative.startsWith('/')) return null;
    return '$directory/$relative';
  }

  String? previewPath(TimelinePhoto photo) {
    if (photo.localPath != null) return photo.localPath;
    final reference = photo.remote;
    if (reference == null) return null;
    final load = previewLoads[reference.id];
    return load is PreviewReady ? load.relativePath : null;
  }

  Future<void> loadPreview(RemotePreview reference, {bool retry = false}) async {
    if (!retry && previewLoads.containsKey(reference.id)) return;
    final link = session.link;
    if (link is! CloudVerified) {
      previewLoads[reference.id] = const PreviewFailed('请先连接云存储，再读取照片。');
      notifyListeners();
      return;
    }
    previewLoads[reference.id] = const PreviewLoading();
    scheduleMicrotask(notifyListeners);
    try {
      reference.validate();
      final relative = 'preview-cache/${reference.parent.folder}-${reference.sha256}';
      final file = File('$directory/$relative');
      var valid = false;
      if (await file.exists() && await file.length() == reference.byteCount) {
        try {
          reference.validateData(await file.readAsBytes());
          valid = true;
        } catch (_) {}
      }
      if (!valid) {
        final client = await _client(reference.parent.prefix);
        final head = await client.head(reference.objectKey);
        if (head == null || head.byteCount != reference.byteCount) {
          throw const CosFailure(ConnectionFailure.contentMismatch);
        }
        final bytes = await client.get(key: reference.objectKey, responseLimit: RemotePreview.maximumBytes);
        reference.validateData(bytes);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
      }
      if (session.link != link) return;
      previewLoads[reference.id] = PreviewReady(relative);
    } catch (_) {
      if (session.link != link) return;
      previewLoads[reference.id] = const PreviewFailed('照片暂时无法读取，请重试。');
    }
    notifyListeners();
  }

  /// Local or cached-and-verified originals for viewing, keyed by role.
  Future<Map<String, String>> mediaResourcePaths(TimelinePhoto photo, {bool allowCellularOnce = false}) async {
    final result = <String, String>{};
    for (final resource in photo.localResources) {
      if (resource.role == 'preview') continue;
      final path = filePath(resource.relativePath);
      if (path == null || !await File(path).exists()) throw const CosFailure(ConnectionFailure.notFound);
      result[resource.role] = path;
    }
    final full = photo.fullSizePath;
    if (result.isEmpty && full != null) {
      final path = filePath(full);
      if (path != null && await File(path).exists()) result['photo'] = path;
    }
    if (photo.remoteResources.isEmpty) return result;
    final link = session.link;
    final generation = _connectionGeneration;
    for (final resource in photo.remoteResources) {
      if (resource.role == 'preview') continue;
      resource.validate();
      final dot = resource.originalFilename.lastIndexOf('.');
      final ext = dot < 0 ? '' : resource.originalFilename.substring(dot + 1).toLowerCase();
      final safeExt = RegExp(r'^[a-z0-9]{1,10}$').hasMatch(ext) ? ext : 'bin';
      final relative = 'original-cache/${resource.parent.folder}-${resource.sha256}.$safeExt';
      final path = '$directory/$relative';
      final file = File(path);
      if (await file.exists()) {
        final digest = await Digest.sha256File(path, maximumBytes: resource.byteCount).catchError((_) => (hash: '', byteCount: -1));
        if (digest.hash == resource.sha256 && digest.byteCount == resource.byteCount) {
          result[resource.role] = path;
          continue;
        }
        // A corrupt cache is disposable; originals in media/ are never removed.
        await file.delete();
      }
      if (link is! CloudVerified) throw const CosFailure(ConnectionFailure.configuration);
      final connectivity = await Connectivity().checkConnectivity();
      final metered = connectivity.contains(ConnectivityResult.mobile) && !connectivity.contains(ConnectivityResult.wifi);
      if (metered && !allowCellularOriginals && !allowCellularOnce) throw const CellularDownloadRequired();
      originalLoads[resource.id] = const PreviewLoading();
      notifyListeners();
      try {
        final client = await _client(resource.parent.prefix);
        await client.getFile(
            key: resource.objectKey, destination: path, byteCount: resource.byteCount, sha256: resource.sha256);
        if (_connectionGeneration != generation || session.link != link) {
          throw const CosFailure(ConnectionFailure.configuration);
        }
        originalLoads[resource.id] = PreviewReady(relative);
        result[resource.role] = path;
      } catch (error) {
        originalLoads[resource.id] = const PreviewFailed('原件暂时无法读取，请重试。');
        notifyListeners();
        rethrow;
      }
    }
    notifyListeners();
    return result;
  }

  // Messages.

  void show(Object error) {
    bannerIsError = true;
    banner = switch (error) {
      CosFailure(:final failure) => failure.message,
      ContractError(:final message) => message,
      _ => '暂时无法完成，请稍后再试。',
    };
    notifyListeners();
  }

  void clearBanner() {
    banner = null;
    notifyListeners();
  }

  void _setBanner(String text, {bool error = false}) {
    banner = text;
    bannerIsError = error;
    notifyListeners();
  }

  bool _mutate(void Function(AppSession session) body, {bool quiet = false}) {
    if (archiveRecoveryMessage != null) return false;
    final copy = session.copy();
    try {
      body(copy);
      _store.save(PersistedArchive.fromSession(copy));
      session = copy;
      if (!quiet) notifyListeners();
      return true;
    } catch (error) {
      show(error);
      return false;
    }
  }
}
