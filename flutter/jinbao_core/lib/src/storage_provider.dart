import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'cos_client.dart';
import 'digest.dart';

/// A destination binding, never an authentication record. An endpoint identifies
/// a storage namespace, including the dedicated directory for filesystem stores.
class StorageIdentity {
  final String providerId;
  final String endpoint;
  final String prefix;
  final String? accountScope;

  const StorageIdentity({
    required this.providerId,
    required this.endpoint,
    required this.prefix,
    this.accountScope,
  });

  Map<String, Object> toJson() => {
    'providerId': providerId,
    'endpoint': endpoint,
    'prefix': prefix,
    if (accountScope != null) 'accountScope': accountScope!,
  };

  factory StorageIdentity.fromJson(Map<String, dynamic> value) {
    final provider = value['providerId'];
    final endpoint = value['endpoint'];
    final prefix = value['prefix'];
    if (provider is! String ||
        endpoint is! String ||
        prefix is! String ||
        provider.isEmpty ||
        endpoint.isEmpty ||
        prefix.isEmpty) {
      throw const StorageProviderFailure(
        StorageProviderFailureKind.configuration,
      );
    }
    return StorageIdentity(
      providerId: provider,
      endpoint: endpoint,
      prefix: prefix,
      accountScope: value['accountScope'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StorageIdentity &&
      other.providerId == providerId &&
      other.endpoint == endpoint &&
      other.prefix == prefix &&
      other.accountScope == accountScope;
  @override
  int get hashCode => Object.hash(providerId, endpoint, prefix, accountScope);
  @override
  String toString() => 'StorageIdentity($providerId, redacted)';
}

enum StorageVersioning { unknown, unsupported, disabled, enabled }

class StorageCapabilities {
  final bool conditionalWrites;
  final StorageVersioning versioning;
  final bool nativePagination;

  /// Null means unknown. Neither WebDAV nor COS list responses prove quota.
  final int? quotaBytes;
  const StorageCapabilities({
    required this.conditionalWrites,
    required this.versioning,
    required this.nativePagination,
    this.quotaBytes,
  });
}

class StorageListPage {
  final List<String> keys;
  final String? nextCursor;
  StorageListPage(Iterable<String> keys, {this.nextCursor})
    : keys = List.unmodifiable(keys);
}

enum StorageProviderFailureKind {
  configuration,
  permission,
  network,
  timeout,
  notFound,
  conflict,
  integrity,
  unsafeConditionalWrites,
  forbidden,
  invalidResponse,
  staleCursor,
}

/// Fixed categories: no remote response, URL, credential or nested exception.
class StorageProviderFailure implements Exception {
  final StorageProviderFailureKind kind;
  const StorageProviderFailure(this.kind);
  @override
  String toString() => 'StorageProviderFailure(${kind.name})';
}

/// Immutable object semantics shared by cloud storage and a dedicated NAS tree.
/// Implementations stream media through files, verify the complete uploaded bytes,
/// and fail closed if the destination cannot protect a create from overwriting.
abstract class StorageProvider {
  StorageIdentity get identity;
  StorageCapabilities get capabilities;
  Future<void> connect();
  Future<void> healthCheck();
  Future<void> verifyImmutableWritesAllowed();
  Future<StorageListPage> listPage({
    required String prefix,
    String? cursor,
    int limit = 1000,
  });
  Future<ObjectHead?> stat(String key);
  Future<ObjectHead?> head(String key) => stat(key);
  Future<Uint8List> get({
    required String key,
    int responseLimit = 32 * 1024 * 1024,
  });
  Future<void> getFile({
    required String key,
    required String destination,
    required int byteCount,
    required String sha256,
  });
  Future<void> putImmutable({
    required String key,
    required List<int> body,
    required String contentType,
  });
  Future<void> putImmutableFile({
    required String key,
    required String filePath,
    required int byteCount,
    required String sha256,
    required String contentType,
  });
  Future<void> delete(String key) async =>
      throw const StorageProviderFailure(StorageProviderFailureKind.forbidden);

  Future<void> verifyObject({
    required String key,
    required int byteCount,
    required String sha256,
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'dayswith-object-verification-',
    );
    try {
      await getFile(
        key: key,
        destination: '${directory.path}/body',
        byteCount: byteCount,
        sha256: sha256,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  }

  Future<List<String>> list({required String prefix}) async {
    final keys = <String>{};
    final cursors = <String>{};
    String? cursor;
    do {
      final page = await listPage(prefix: prefix, cursor: cursor);
      keys.addAll(page.keys);
      if (keys.length > 100000) {
        throw const StorageProviderFailure(
          StorageProviderFailureKind.invalidResponse,
        );
      }
      cursor = page.nextCursor;
      if (cursor != null && !cursors.add(cursor)) {
        throw const StorageProviderFailure(
          StorageProviderFailureKind.invalidResponse,
        );
      }
    } while (cursor != null);
    return keys.toList()..sort();
  }
}

/// Bound each application cursor to a complete key snapshot. WebDAV has no
/// standard server cursor, and the legacy COS client consumes its server pages.
StorageListPage storageSnapshotPage(
  List<String> source,
  String prefix,
  String? cursor,
  int limit,
) {
  if (limit < 1 || limit > 1000 || source.length > 100000) {
    throw const StorageProviderFailure(
      StorageProviderFailureKind.configuration,
    );
  }
  final keys = source.toSet().toList()..sort();
  final fingerprint = Digest.sha256Hex(
    utf8.encode('$prefix\n${keys.join('\n')}'),
  );
  var offset = 0;
  if (cursor != null) {
    final parts = cursor.split(':');
    if (parts.length != 2 ||
        parts.first != fingerprint ||
        (offset = int.tryParse(parts.last) ?? -1) < 1 ||
        offset >= keys.length) {
      throw const StorageProviderFailure(
        StorageProviderFailureKind.staleCursor,
      );
    }
  }
  final end = (offset + limit).clamp(0, keys.length);
  return StorageListPage(
    keys.sublist(offset, end),
    nextCursor: end < keys.length ? '$fingerprint:$end' : null,
  );
}
