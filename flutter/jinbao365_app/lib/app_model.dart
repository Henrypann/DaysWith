import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:jinbao_core/jinbao_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_legacy_upgrade.dart';
import 'credential_store.dart';
import 'media_import.dart';
import 'webdav_credential_store.dart';

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

  final CredentialStore _credentials;
  final Future<List<ConnectivityResult>> Function() _connectivityCheck;
  final StorageProvider Function(CloudLink link, String prefix)? _providerFactory;
  AppModel({
    CredentialStore? credentials,
    WebDavCredentialStore? webdavCredentials,
    Future<List<ConnectivityResult>> Function()? connectivityCheck,
    this._providerFactory,
  }) : _credentials = credentials ?? CredentialStore(),
       _webdavCredentials = webdavCredentials ?? WebDavCredentialStore(),
       _connectivityCheck = connectivityCheck ?? Connectivity().checkConnectivity;

  @visibleForTesting
  void initializeForTesting({required String path, required AppSession initial, SharedPreferences? preferences}) {
    if (!initial.testBuild) {
      throw StateError('Synthetic test archive required.');
    }
    directory = path;
    _store = ArchiveStore('$path/archive.json');
    _preferences = preferences;
    session = initial;
    _store.save(PersistedArchive.fromSession(initial));
    ready = true;
    _loadStorageStatus();
  }

  late final String directory;
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
  bool wifiOnlyBackup = true;
  bool _backupRequested = false;
  bool restoring = false;
  ArchiveRestoreResult? lastRestoreResult;
  String? restoreError;
  String storageHealthLabel = '尚未检查';
  DateTime? lastSuccessfulBackup;
  final WebDavCredentialStore _webdavCredentials;

  String get storageTargetLabel => switch (session.link) {
    CloudWebDav(:final name) => name,
    CloudVerified(:final bucket) => '腾讯云 COS · $bucket',
    _ => '仅保存在本机',
  };
  int get pendingStorageCount => _backupRequested || session.backupJob?.status == BackupJobStatus.queued
      ? (session.backupJob?.totalCount ?? backupMediaCount)
      : 0;
  int get failedStorageCount => session.backupJob?.status == BackupJobStatus.failed ? 1 : 0;
  int get backupMediaCount => session.moments.where((m) => m.parent == session.identity).expand((m) => m.assets).length;
  int get backupByteCount => session.moments
      .where((m) => m.parent == session.identity)
      .expand((m) => m.assets)
      .expand((a) => a.resources)
      .fold(0, (sum, r) => sum + r.byteCount);
  int get backupRecordCount => session.moments.where((m) => m.parent == session.identity).length;

  Future<void> setWifiOnlyBackup(bool value) async {
    await _preferences?.setBool('wifiOnlyBackup', value);
    wifiOnlyBackup = value;
    notifyListeners();
  }

  String get _successKey =>
      'storage-success-${Digest.sha256Hex(utf8.encode(jsonEncode(session.link.storageIdentity?.toJson())))}';
  void _loadStorageStatus() {
    final timestamp = _preferences?.getInt(_successKey);
    lastSuccessfulBackup = timestamp == null ? null : DateTime.fromMillisecondsSinceEpoch(timestamp);
    _backupRequested =
        session.link.storageIdentity != null &&
        _preferences?.getString('backupRequestedFor') == jsonEncode(session.link.storageIdentity!.toJson());
  }

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
    wifiOnlyBackup = _preferences?.getBool('wifiOnlyBackup') ?? true;
    AppSession? loaded;
    try {
      if (Platform.isAndroid) {
        _legacyUpgradePending = !File(_store.path).existsSync() && !File(_store.recoveryPath).existsSync();
        await AndroidLegacyUpgrade(credentials: _credentials)
            .migrateIfNeeded(store: _store, directory: directory, testBuild: isTestBuild);
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
    _loadStorageStatus();
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
        await AndroidLegacyUpgrade(credentials: _credentials)
            .migrateIfNeeded(store: _store, directory: directory, testBuild: isTestBuild);
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

  void selectTab(ShellTab value) {
    tab = value;
    notifyListeners();
  }

  void confirm(ParentIdentity parent) => _mutate((s) => s.confirmIdentity(parent));

  void connectPlaceholder() {
    if (!isTestBuild) return;
    if (busy || backupRunning || restoring) {
      show(const ContractError('backup', '请等待连接验证完成，或先暂停备份。'));
      return;
    }
    if (!_mutate((s) => s.connectPlaceholder(bucket: swiftTrim(bucket), region: swiftTrim(region)))) {
      return;
    }
    _connectionGeneration++;
    _refreshing = false;
    _setBanner('这是占位连接，没有保存密钥，也不会上传。');
  }

  Future<void> verify({required String secretID, required String secretKey, required String sessionToken}) async {
    if (busy || backupRunning || restoring) return;
    final credentials = StorageCredentials(
      secretID: swiftTrim(secretID),
      secretKey: swiftTrim(secretKey),
      sessionToken: sessionToken.isEmpty ? null : sessionToken,
    );
    final configuration = StorageConfiguration(
      bucket: swiftTrim(bucket),
      region: swiftTrim(region),
      prefix: 'life/v1/',
    );
    try {
      configuration.validate();
      if (!credentials.isValid) {
        throw const CosFailure(ConnectionFailure.configuration);
      }
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
        configuration: configuration,
        credentials: credentials,
        transport: HttpObjectTransport(configuration),
      );
      await client.list(prefix: ParentIdentity.dad.prefix);
      await client.list(prefix: ParentIdentity.mom.prefix);
      if (_connectionGeneration != generation) return;
      final previous = await _credentials.load();
      if (_connectionGeneration != generation) return;
      await _credentials.save(credentials);
      if (_connectionGeneration != generation) {
        if (previous != null) {
          await _credentials.save(previous);
        } else {
          await _credentials.delete();
        }
        return;
      }
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
      storageHealthLabel = '读取连接正常；写入按备份任务校验';
      await _preferences?.remove('backupRequestedFor');
      _loadStorageStatus();
      _setBanner('云存储已连接，历史本地记录需手动确认备份。');
      _refreshing = false;
      refreshRemote();
      _scheduleAutomaticBackup();
    } catch (error) {
      if (_connectionGeneration != generation) return;
      busy = false;
      show(error);
    } finally {
      busy = false;
      notifyListeners();
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
    final disconnectedLink = session.link;
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
      if (disconnectedLink is CloudWebDav) {
        await _webdavCredentials.delete();
      } else {
        await _credentials.delete();
      }
      await _preferences?.remove('backupRequestedFor');
      _backupRequested = false;
      lastSuccessfulBackup = null;
      storageHealthLabel = '未连接';
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
    if (!_mutate((s) => s.commitDraft(now: now))) return false;
    tab = ShellTab.timeline;
    notifyListeners();
    _scheduleAutomaticBackup();
    return true;
  }

  void trashMoment(String id) {
    if (_mutate((s) => s.trashMoment(id: id, now: now))) {
      _scheduleAutomaticBackup();
    }
  }

  void restoreMoment(String id) {
    if (_mutate((s) => s.restoreMoment(id: id, now: now))) {
      _scheduleAutomaticBackup();
    }
  }

  bool saveAnniversary({String? id, required String title, required String date}) {
    final ok = _mutate((s) => s.saveAnniversary(id: id, title: title, date: date, now: now));
    if (ok) _scheduleAutomaticBackup();
    return ok;
  }

  void deleteAnniversary(String id) {
    if (_mutate((s) => s.deleteAnniversary(id: id, now: now))) {
      _scheduleAutomaticBackup();
    }
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

  Future<StorageProvider> _client(String prefix) async {
    final link = session.link;
    final injected = _providerFactory;
    if (injected != null) return injected(link, prefix);
    if (link case CloudWebDav(:final endpoint)) {
      final saved = await _webdavCredentials.load();
      if (saved == null || saved.url != endpoint) {
        throw const CosFailure(ConnectionFailure.secureStorage);
      }
      final provider = WebDavStorageProvider(
        configuration: WebDavConfiguration(baseUrl: endpoint, prefix: prefix),
        credentials: WebDavCredentials(username: saved.username, password: saved.password),
      );
      if (provider.identity.accountScope != link.storageIdentity?.accountScope) {
        throw const CosFailure(ConnectionFailure.secureStorage);
      }
      return provider;
    }
    final credentials = await _credentials.load();
    if (credentials == null || link is! CloudVerified) {
      throw const CosFailure(ConnectionFailure.secureStorage);
    }
    final configuration = StorageConfiguration(bucket: link.bucket, region: link.region, prefix: prefix);
    return CosStorageProvider(
      CosClient(configuration: configuration, credentials: credentials, transport: HttpObjectTransport(configuration)),
    );
  }

  Future<void> verifyWebDav({
    required String name,
    required String url,
    required String username,
    required String password,
  }) async {
    if (busy || backupRunning || restoring || archiveRecoveryMessage != null) {
      return;
    }
    final generation = ++_connectionGeneration;
    _refreshing = false;
    busy = true;
    notifyListeners();
    try {
      final configuration = WebDavConfiguration(baseUrl: url);
      final saved = WebDavSavedConnection(
        name: name,
        url: configuration.baseUri.toString(),
        username: username,
        password: password,
      );
      final provider = WebDavStorageProvider(
        configuration: configuration,
        credentials: WebDavCredentials(username: username, password: password),
      );
      await provider.connect();
      if (_connectionGeneration != generation) return;
      final previous = await _webdavCredentials.load();
      if (_connectionGeneration != generation) return;
      await _webdavCredentials.save(saved);
      if (_connectionGeneration != generation) {
        if (previous != null) {
          await _webdavCredentials.save(previous);
        } else {
          await _webdavCredentials.delete();
        }
        return;
      }
      if (!_mutate((s) {
        final changed = s.link.storageIdentity != provider.identity;
        s.link = CloudWebDav(
          name: name,
          endpoint: configuration.baseUri.toString(),
          accountScope: provider.identity.accountScope,
        );
        if (changed) {
          s.remote = [];
          s.remoteAnniversaries = [];
          s.backupJob = null;
        }
      })) {
        if (previous == null) {
          await _webdavCredentials.delete();
        } else {
          await _webdavCredentials.save(previous);
        }
        return;
      }
      previewLoads.clear();
      originalLoads.clear();
      await _preferences?.remove('backupRequestedFor');
      _loadStorageStatus();
      storageHealthLabel = 'HTTPS、读写及防覆盖检查通过';
      _setBanner('NAS 已连接。记录仍在本机，确认后才会备份；尚未完成独立恢复验证。');
      await refreshRemote();
    } catch (error) {
      show(error);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> refreshRemote() async {
    final link = session.link;
    final owner = session.identity;
    if (_refreshing || archiveRecoveryMessage != null || !link.isVerified || owner == null) {
      return;
    }
    _refreshing = true;
    final generation = _connectionGeneration;
    try {
      final client = await _client('life/v1/');
      final remote = await FamilyReader.readStorageArchive(
        client,
        owner: owner,
        deviceID: session.deviceID,
        testBuild: session.testBuild,
      );
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
    final target = session.link.storageIdentity;
    return target != null &&
        job.storageIdentity.providerId == target.providerId &&
        job.storageIdentity.endpoint == target.endpoint &&
        job.prefix == prefix &&
        job.testBuild == session.testBuild;
  }

  String get backupStatusTitle {
    if (!session.link.isVerified) return '仅保存在这台手机';
    final job = session.backupJob;
    if (job == null || !_backupMatchesScope(job)) return '尚未备份';
    switch (job.status) {
      case BackupJobStatus.queued:
        return '等待继续备份';
      case BackupJobStatus.uploading:
        return backupRunning ? '正在备份' : '备份已中断，可继续';
      case BackupJobStatus.verifying:
        return '正在校验远端副本';
      case BackupJobStatus.paused:
        return '备份已暂停';
      case BackupJobStatus.failed:
        return '备份未完成';
      case BackupJobStatus.completed:
        try {
          final plan = BackupPlan.manifest(session, now: now);
          if (!job.matchesLocalPlan(plan)) return '有新的内容待备份';
        } catch (_) {}
        return '已验证远端副本';
    }
  }

  String get backupStatusDetail {
    if (!session.link.isVerified) return '仅保存在本机。可随时记录，连接存储并确认后再备份。';
    final job = session.backupJob;
    if (job == null || !_backupMatchesScope(job)) {
      return '手动确认后备份，默认仅 Wi-Fi；原片始终保留在本机。';
    }
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
    final activeJob = session.backupJob;
    if (_backupRequested ||
        (activeJob != null &&
            _backupMatchesScope(activeJob) &&
            (status == BackupJobStatus.queued ||
                status == BackupJobStatus.uploading ||
                status == BackupJobStatus.verifying))) {
      backupNow(includeLocalRecords: false);
    } else if (status != BackupJobStatus.paused && status != BackupJobStatus.failed) {
      _scheduleAutomaticBackup();
    }
  }

  void _scheduleAutomaticBackup() {
    // v3.1 is manual-first. Saving/editing/connecting never grants upload consent.
    _automaticBackup?.cancel();
  }

  void pauseBackup() {
    _backupRequested = false;
    _preferences?.remove('backupRequestedFor');
    _automaticBackup?.cancel();
    _stopBackup = true;
    if (!backupRunning) _mutate((s) => s.backupJob?.pause());
    _setBanner(backupRunning ? '正在暂停，当前文件完成后停止。' : '备份已暂停。');
  }

  Future<void> backupNow({bool includeLocalRecords = true}) async {
    if (backupRunning || busy || restoring || archiveRecoveryMessage != null) {
      return;
    }
    final approvedLink = session.link;
    if (!approvedLink.isVerified) {
      _setBanner('请先连接存储；记录仍仅保存在本机。', error: true);
      return;
    }
    // Lock and bind consent before the first await. A slow network query cannot
    // turn approval for destination A into permission to upload to destination B.
    final generation = _connectionGeneration;
    backupRunning = true;
    _stopBackup = false;
    notifyListeners();
    void checkScope() {
      if (_connectionGeneration != generation || session.link != approvedLink || archiveRecoveryMessage != null) {
        throw const CosFailure(ConnectionFailure.configuration);
      }
    }

    try {
      if (includeLocalRecords &&
          !_mutate((s) {
            final eligibility = s.testBuild ? UploadEligibility.testOnly : UploadEligibility.eligible;
            s.moments = [
              for (final m in s.moments)
                if (m.parent == s.identity && m.uploadEligibility == UploadEligibility.localOnly)
                  LocalMoment.fromJson({...m.toJson(), 'uploadEligibility': eligibility.rawValue})
                else
                  m,
            ];
            s.anniversaries = [
              for (final a in s.anniversaries)
                if (a.owner == s.identity && a.uploadEligibility == UploadEligibility.localOnly)
                  LocalAnniversary.fromJson({...a.toJson(), 'uploadEligibility': eligibility.rawValue})
                else
                  a,
            ];
          })) {
        return;
      }
      final pendingStore = ArchiveStore('$directory/pending-upload.json');
      final AppSession snapshot;
      if (includeLocalRecords) {
        snapshot = session.copy();
        pendingStore.save(PersistedArchive.fromSession(snapshot));
      } else {
        final pending = pendingStore.load()?.session();
        if (pending == null || pending.link != approvedLink || pending.deviceID != session.deviceID) {
          throw const ContractError('backup', '等待上传的确认已失效，请重新检查目标并确认。');
        }
        snapshot = pending;
      }
      await _preferences?.setString('backupRequestedFor', jsonEncode(approvedLink.storageIdentity!.toJson()));
      _backupRequested = true;
      final networks = await _connectivityCheck();
      checkScope();
      if (networks.contains(ConnectivityResult.none) ||
          (wifiOnlyBackup &&
              !networks.contains(ConnectivityResult.wifi) &&
              !networks.contains(ConnectivityResult.ethernet))) {
        storageHealthLabel = '等待可用网络';
        _setBanner(wifiOnlyBackup ? '等待 Wi-Fi，备份请求已保留；可以继续本地记录。' : '等待网络，备份请求已保留。');
        return;
      }
      final prefix = snapshot.writerPrefix();
      final client = await _client(prefix);
      checkScope();
      final existing = session.backupJob;
      final BackupJob job;
      if (existing != null &&
          existing.status != BackupJobStatus.completed &&
          existing.prefix == prefix &&
          existing.storageIdentity == client.identity &&
          existing.testBuild == snapshot.testBuild &&
          existing.matchesLocalPlan(BackupPlan.manifest(snapshot, now: now))) {
        job = existing.copy()..resume();
      } else {
        job = await BackupQueue.prepareWithProvider(client, snapshot, now: now);
      }
      void checkpoint(BackupJob updated) {
        checkScope();
        if (session.deviceID != snapshot.deviceID) {
          throw const CosFailure(ConnectionFailure.configuration);
        }
        final latest = session.copy()..backupJob = updated;
        _store.save(PersistedArchive.fromSession(latest));
        session = latest;
        notifyListeners();
      }

      checkpoint(job.copy());
      final root = Directory(directory).absolute.path;
      await BackupQueue.advanceWithProvider(
        client,
        snapshot,
        job,
        resolve: (relative) {
          final path = File('$root/$relative').absolute.path;
          if (relative.split('/').contains('..') || !path.startsWith('$root/')) {
            throw const CosFailure(ConnectionFailure.contentMismatch);
          }
          return path;
        },
        persist: checkpoint,
        shouldPause: () => _stopBackup,
      );
      checkScope();
      final completed = job.status == BackupJobStatus.completed;
      if (completed) {
        await _preferences?.remove('backupRequestedFor');
        _backupRequested = false;
        lastSuccessfulBackup = DateTime.now();
        await _preferences?.setInt(_successKey, lastSuccessfulBackup!.millisecondsSinceEpoch);
        storageHealthLabel = '已验证远端副本';
      }
      _setBanner(completed ? '已验证远端副本；原片保留，尚不等于独立恢复验证。' : '备份已暂停，可稍后继续。');
    } catch (error) {
      storageHealthLabel = '备份未完成，可重试';
      show(error);
    } finally {
      backupRunning = false;
      notifyListeners();
    }
  }

  Future<void> restoreToIsolatedCopy() async {
    if (busy || backupRunning || restoring || !session.link.isVerified || session.identity == null) {
      return;
    }
    restoring = true;
    restoreError = null;
    final link = session.link;
    final generation = _connectionGeneration;
    notifyListeners();
    try {
      final provider = await _client('life/v1/');
      final chains = <RestoreChain>[];
      for (final parent in ParentIdentity.values) {
        final keys = await provider.list(prefix: parent.prefix);
        for (final prefix in V1Layout.chainsUnder(root: parent.prefix, keys: keys)) {
          chains.add(RestoreChain(parent: parent, prefix: prefix));
        }
      }
      if (session.testBuild) {
        final testPrefix = session.writerPrefix();
        if ((await provider.list(prefix: '${testPrefix}commits/')).isNotEmpty) {
          chains.add(RestoreChain(parent: session.identity!, prefix: testPrefix));
        }
      }
      final parent = Directory('$directory/restores');
      await parent.create(recursive: true);
      final result = await ArchiveRestore.restore(
        provider,
        destination: '${parent.path}/${newUuid()}',
        owner: session.identity!,
        deviceID: newUuid(),
        chains: chains,
        testBuild: session.testBuild,
      );
      if (_connectionGeneration != generation || session.link != link) {
        throw const CosFailure(ConnectionFailure.configuration);
      }
      lastRestoreResult = result;
      _setBanner('已在本机建立隔离恢复副本并校验全部原件；当前档案未替换。');
    } catch (error) {
      restoreError = '完整恢复尚未完成，当前档案及原件保持原样。';
      show(error);
    } finally {
      restoring = false;
      notifyListeners();
    }
  }

  // Media files.

  String? filePath(String relative) {
    if (relative.isEmpty || relative.contains('..') || relative.startsWith('/')) {
      return null;
    }
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
        if (!link.isVerified) {
          throw const CosFailure(ConnectionFailure.configuration);
        }
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
      if (path == null || !await File(path).exists()) {
        throw const CosFailure(ConnectionFailure.notFound);
      }
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
        final digest = await Digest.sha256File(
          path,
          maximumBytes: resource.byteCount,
        ).catchError((_) => (hash: '', byteCount: -1));
        if (digest.hash == resource.sha256 && digest.byteCount == resource.byteCount) {
          result[resource.role] = path;
          continue;
        }
        // A corrupt cache is disposable; originals in media/ are never removed.
        await file.delete();
      }
      if (!link.isVerified) {
        throw const CosFailure(ConnectionFailure.configuration);
      }
      final connectivity = await Connectivity().checkConnectivity();
      final metered =
          connectivity.contains(ConnectivityResult.mobile) && !connectivity.contains(ConnectivityResult.wifi);
      if (metered && !allowCellularOriginals && !allowCellularOnce) {
        throw const CellularDownloadRequired();
      }
      originalLoads[resource.id] = const PreviewLoading();
      notifyListeners();
      try {
        final client = await _client(resource.parent.prefix);
        await client.getFile(
          key: resource.objectKey,
          destination: path,
          byteCount: resource.byteCount,
          sha256: resource.sha256,
        );
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
      StorageProviderFailure(:final kind) => switch (kind) {
        StorageProviderFailureKind.permission => '存储认证或权限不足，请更新连接；原片保留在本机。',
        StorageProviderFailureKind.conflict => '目标已有不同内容，已停止写入，不会覆盖。',
        StorageProviderFailureKind.integrity => '远端副本校验失败，尚未备份成功。',
        StorageProviderFailureKind.unsafeConditionalWrites => '存储不能可靠阻止覆盖，已停止备份。',
        StorageProviderFailureKind.configuration => '请检查 HTTPS 专用目录和连接配置。',
        _ => '存储暂时不可用，原片在本机，稍后可重试。',
      },
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
