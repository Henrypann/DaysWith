import 'dart:convert';
import 'dart:io';

import 'app_session.dart';
import 'errors.dart';
import 'json_wire.dart';
import 'text.dart';
import 'v1_ids.dart';

/// Serial, atomic local snapshots. A corrupt primary is never replaced by a new empty archive.
///
/// The file format is the one the iOS app writes, so an installed iOS archive opens unchanged.
/// All file operations are synchronous so one save cannot interleave with another.
class ArchiveStore {
  final String path;
  ArchiveStore(this.path);

  String get recoveryPath => '$path.recovery';

  PersistedArchive? load() {
    final file = File(path);
    if (!file.existsSync()) {
      if (File(recoveryPath).existsSync()) {
        throw const ContractError('archive.recovery', '主档案暂时缺失，已找到恢复副本，请先恢复。');
      }
      return null;
    }
    return _decode(file.readAsBytesSync());
  }

  void save(PersistedArchive archive) {
    final bytes = utf8.encode(JsonWire.encodeString(archive.toJson()));
    _decode(bytes);
    File(path).parent.createSync(recursive: true);
    final file = File(path);
    if (file.existsSync()) {
      final existing = file.readAsBytesSync();
      final old = _decode(existing); // Fail closed before touching the last known-good copy.
      if (old.deviceID != archive.deviceID ||
          (old.identityFolder != null && old.identityFolder != archive.identityFolder)) {
        throw const ContractError('archive.identity', '档案设备或身份发生变化，已保留原数据。');
      }
      _writeAtomic(recoveryPath, existing);
    } else {
      if (File(recoveryPath).existsSync()) {
        throw const ContractError('archive.recovery', '已找到现有恢复副本，不能创建空档案覆盖。');
      }
      _writeAtomic(recoveryPath, bytes);
    }
    _writeAtomic(path, bytes);
  }

  PersistedArchive loadRecovery() => _decode(File(recoveryPath).readAsBytesSync());

  /// Explicit recovery preserves the unreadable primary for later inspection.
  PersistedArchive restoreRecovery() {
    final bytes = File(recoveryPath).readAsBytesSync();
    final archive = _decode(bytes);
    final file = File(path);
    if (file.existsSync()) {
      _writeAtomic('$path.unreadable-${newUuid()}', file.readAsBytesSync());
    }
    _writeAtomic(path, bytes);
    return archive;
  }

  static void _writeAtomic(String target, List<int> bytes) {
    final temporary = File('$target.tmp-${newUuid()}');
    try {
      temporary.writeAsBytesSync(bytes, flush: true);
      temporary.renameSync(target);
    } catch (_) {
      if (temporary.existsSync()) temporary.deleteSync();
      rethrow;
    }
  }

  static PersistedArchive _decode(List<int> data) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(data));
    } on FormatException {
      throw const ContractError('archive', '档案无法读取，原数据已保留。');
    }
    final archive = PersistedArchive.fromJson(json);
    V1Ids.canonical(archive.deviceID, path: 'archive.deviceID');
    if (archive.moments.map((m) => m.id.toUpperCase()).toSet().length != archive.moments.length) {
      throw const ContractError('archive.moments', '档案包含重复记录编号，原数据已保留。');
    }
    final assets = [...archive.moments.expand((m) => m.assets), ...?archive.draft?.assets];
    for (final resource in assets.expand((a) => a.resources)) {
      final relative = resource.relativePath;
      if (relative.isEmpty || relative.startsWith('/') || relative.contains(r'\') || relative.split('/').contains('..')) {
        throw const ContractError('archive.media', '档案媒体路径无效，原数据已保留。');
      }
    }
    return archive;
  }
}
