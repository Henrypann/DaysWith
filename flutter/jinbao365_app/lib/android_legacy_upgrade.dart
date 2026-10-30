import 'dart:io';

import 'package:flutter/services.dart';
import 'package:jinbao_core/jinbao_core.dart';

import 'credential_store.dart';

/// Imports the original Android archive once, without changing its database,
/// media or Keystore document. The native bridge returns secrets only to the
/// credential call; they are never part of an archive or migration manifest.
class AndroidLegacyUpgrade {
  static const channel = MethodChannel(
    'com.henrypann.jinbao365/legacy_upgrade',
  );

  final MethodChannel _channel;
  final CredentialStore _credentials;

  AndroidLegacyUpgrade({
    MethodChannel? platformChannel,
    CredentialStore? credentials,
  }) : _channel = platformChannel ?? channel,
       _credentials = credentials ?? CredentialStore();

  /// A primary archive is the durable commit marker. In particular, disconnecting
  /// later cannot cause old credentials to be imported again on the next launch.
  Future<void> migrateIfNeeded({
    required ArchiveStore store,
    required String directory,
    required bool testBuild,
  }) async {
    if (File(store.path).existsSync() ||
        File(store.recoveryPath).existsSync()) {
      store.load(); // An unreadable archive must block, rather than re-import.
      return;
    }

    final raw = await _channel.invokeMethod<Object?>('prepareMigration', {
      'testBuild': testBuild,
    });
    if (raw == null) return;
    final payload = _map(raw);
    if (payload['sourceFingerprint'] is! String ||
        (payload['sourceFingerprint'] as String).isEmpty) {
      throw _invalid();
    }
    final rootPath = payload['mediaRoot'];
    final rawFiles = payload['mediaFiles'];
    final requiredCredentials = payload['credentialsRequired'];
    if (rootPath is! String ||
        !rootPath.startsWith('/') ||
        rawFiles is! List ||
        requiredCredentials is! bool) {
      throw _invalid();
    }

    // Derive all write eligibility from this build, never from old backup jobs or
    // the native bridge. Imported family records remain local until explicitly
    // supported by a future transfer flow.
    final archiveJson = _map(payload['archive']);
    archiveJson['testBuild'] = testBuild;
    archiveJson.remove('backupJob');
    for (final key in ['moments', 'anniversaries']) {
      final values = archiveJson[key];
      if (values is! List) throw _invalid();
      archiveJson[key] = [for (final value in values) _localOnly(value)];
    }
    if (archiveJson['draft'] != null) {
      archiveJson['draft'] = _localOnly(archiveJson['draft']);
    }
    final session = PersistedArchive.fromJson(archiveJson).session()
      ..testBuild = testBuild;
    final archive = PersistedArchive.fromSession(session);
    if (requiredCredentials != (session.link is CloudVerified)) {
      throw _invalid();
    }

    final destination = Directory(directory)..createSync(recursive: true);
    final staged = await destination.createTemp('.legacy-upgrade-');
    try {
      // Reuse the real archive validator before copying media or loading secrets.
      ArchiveStore('${staged.path}/archive.json').save(archive);
      final expected = _resources(archive);
      final files = <String, _MediaFile>{};
      for (final value in rawFiles) {
        final file = _MediaFile.fromJson(value);
        final resource = expected[file.targetPath];
        if (resource == null ||
            resource.sha256.toLowerCase() != file.sha256 ||
            resource.byteCount != file.byteCount ||
            files.containsKey(file.targetPath)) {
          throw _invalid();
        }
        files[file.targetPath] = file;
      }
      if (files.length != expected.length) throw _invalid();
      final sourceRoot = await Directory(rootPath).resolveSymbolicLinks();
      for (final file in files.values) {
        await _copy(
          file,
          sourceRoot: sourceRoot,
          destination: destination.path,
        );
      }

      if (requiredCredentials) {
        final response = await _channel.invokeMethod<Object?>(
          'readLegacyCredentials',
          {'bucket': session.link.bucket, 'region': session.link.region},
        );
        final fields = _map(response);
        final secretID = fields['secretID'];
        final secretKey = fields['secretKey'];
        final token = fields['sessionToken'];
        final expiry = fields['expiresAt'];
        if (secretID is! String ||
            secretKey is! String ||
            (token != null && token is! String) ||
            (expiry != null && expiry is! int)) {
          throw const CosFailure(ConnectionFailure.secureStorage);
        }
        final credentials = StorageCredentials(
          secretID: secretID,
          secretKey: secretKey,
          sessionToken: token as String?,
          expiresAt: expiry as int?,
        );
        if (!credentials.isValid) {
          throw const CosFailure(ConnectionFailure.secureStorage);
        }
        await _credentials.save(credentials);
        final restored = await _credentials.load();
        if (restored?.secretID != credentials.secretID ||
            restored?.secretKey != credentials.secretKey ||
            restored?.sessionToken != credentials.sessionToken ||
            restored?.expiresAt != credentials.expiresAt) {
          throw const CosFailure(ConnectionFailure.secureStorage);
        }
      }

      // The archive is published only after every media file and the secure
      // credential write have been verified. A failed attempt is safe to retry.
      store.save(archive);
      await _writeReceipt(directory, {
        'version': 1,
        'sourceFingerprint': payload['sourceFingerprint'],
        'deviceID': archive.deviceID,
        'identityFolder': archive.identityFolder,
        'recordCount': archive.moments.length,
        'mediaCount': files.length,
        'credentialsCopiedAndVerified': requiredCredentials,
        'testBuild': testBuild,
      });
    } finally {
      await staged.delete(recursive: true);
    }
  }

  static Map<String, Object?> _map(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw _invalid();
    }
    return Map<String, Object?>.from(value);
  }

  static Map<String, Object?> _localOnly(Object? value) =>
      _map(value)..['uploadEligibility'] = UploadEligibility.localOnly.rawValue;

  static Map<String, LocalResource> _resources(PersistedArchive archive) {
    final resources = <String, LocalResource>{};
    for (final asset in [
      ...archive.moments.expand((m) => m.assets),
      ...?archive.draft?.assets,
    ]) {
      for (final resource in asset.resources) {
        final existing = resources[resource.relativePath];
        if (existing != null &&
            (existing.byteCount != resource.byteCount ||
                existing.sha256.toLowerCase() !=
                    resource.sha256.toLowerCase())) {
          throw _invalid();
        }
        resources[resource.relativePath] = resource;
      }
    }
    return resources;
  }

  static Future<void> _copy(
    _MediaFile media, {
    required String sourceRoot,
    required String destination,
  }) async {
    if (!media.sourcePath.startsWith('/') ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(media.sha256) ||
        media.byteCount < 1 ||
        media.byteCount > V1Validator.maxResourceBytes ||
        !media.targetPath.startsWith('legacy-media/') ||
        media.targetPath.contains(r'\') ||
        media.targetPath
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw _invalid();
    }
    if (await FileSystemEntity.type(media.sourcePath, followLinks: false) !=
        FileSystemEntityType.file) {
      throw _invalid();
    }
    final source = File(await File(media.sourcePath).resolveSymbolicLinks());
    if (!source.path.startsWith('$sourceRoot/')) throw _invalid();
    await _verify(source, media);

    final target = File('$destination/${media.targetPath}');
    // Reject symlinks anywhere in an existing target path before creating dirs.
    var parent = Directory(destination);
    for (final part
        in media.targetPath
            .split('/')
            .take(media.targetPath.split('/').length - 1)) {
      parent = Directory('${parent.path}/$part');
      final type = await FileSystemEntity.type(parent.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory) {
        throw _invalid();
      }
    }
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      if (type != FileSystemEntityType.file) throw _invalid();
      await _verify(
        target,
        media,
      ); // Reuse only an identical prior staged copy.
      return;
    }
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp-${newUuid()}');
    try {
      await source.copy(temporary.path);
      await _verify(temporary, media);
      final handle = await temporary.open(mode: FileMode.append);
      try {
        await handle.flush();
      } finally {
        await handle.close();
      }
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static Future<void> _verify(File file, _MediaFile media) async {
    final digest = await Digest.sha256File(file.path);
    if (digest.hash != media.sha256 || digest.byteCount != media.byteCount) {
      throw _invalid();
    }
  }

  static Future<void> _writeReceipt(
    String directory,
    Map<String, Object?> value,
  ) async {
    final temporary = File(
      '$directory/native-upgrade-v1.json.tmp-${newUuid()}',
    );
    try {
      await temporary.writeAsBytes(JsonWire.encode(value), flush: true);
      await temporary.rename('$directory/native-upgrade-v1.json');
    } catch (_) {
      // The committed archive, rather than this optional diagnostic receipt,
      // decides whether to import again. Never invalidate a successful upgrade.
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static ContractError _invalid() =>
      const ContractError('legacyUpgrade', '旧版本档案暂时无法迁移，原数据已保留。');
}

class _MediaFile {
  final String sourcePath;
  final String targetPath;
  final String sha256;
  final int byteCount;

  _MediaFile(this.sourcePath, this.targetPath, this.sha256, this.byteCount);

  factory _MediaFile.fromJson(Object? raw) {
    final value = AndroidLegacyUpgrade._map(raw);
    final source = value['sourcePath'];
    final target = value['targetPath'];
    final sha = value['sha256'];
    final bytes = value['byteCount'];
    if (source is! String ||
        target is! String ||
        sha is! String ||
        bytes is! int) {
      throw AndroidLegacyUpgrade._invalid();
    }
    return _MediaFile(source, target, sha.toLowerCase(), bytes);
  }
}
