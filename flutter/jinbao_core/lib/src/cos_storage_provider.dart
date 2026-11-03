import 'dart:typed_data';

import 'cos_client.dart';
import 'digest.dart';
import 'errors.dart';
import 'storage_provider.dart';

/// Keeps COS signing, versioning checks, path scoping and conditional writes in
/// the existing client. This adapter adds full-byte read-back before success.
class CosStorageProvider extends StorageProvider {
  final CosClient client;
  bool _verified = false;
  CosStorageProvider(this.client);

  @override
  StorageIdentity get identity => StorageIdentity(
    providerId: 'cos',
    endpoint: 'https://${client.configuration.host}/',
    prefix: client.configuration.prefix,
  );
  @override
  StorageCapabilities get capabilities => StorageCapabilities(
    conditionalWrites: _verified,
    versioning: _verified
        ? StorageVersioning.disabled
        : StorageVersioning.unknown,
    nativePagination: false,
  );

  @override
  Future<void> connect() async {
    _verified = false;
    await client.verifyImmutableWritesAllowed();
    _verified = true;
  }

  @override
  Future<void> verifyImmutableWritesAllowed() => connect();
  @override
  Future<void> healthCheck() => connect();
  @override
  Future<ObjectHead?> stat(String key) => client.head(key);
  @override
  Future<Uint8List> get({
    required String key,
    int responseLimit = 32 * 1024 * 1024,
  }) => client.get(key: key, responseLimit: responseLimit);
  @override
  Future<void> getFile({
    required String key,
    required String destination,
    required int byteCount,
    required String sha256,
  }) => client.getFile(
    key: key,
    destination: destination,
    byteCount: byteCount,
    sha256: sha256,
  );

  @override
  Future<StorageListPage> listPage({
    required String prefix,
    String? cursor,
    int limit = 1000,
  }) async {
    // CosClient already validates and consumes the server's continuation pages.
    // Expose stable application pages without pretending they are native cursors.
    return storageSnapshotPage(
      await client.list(prefix: prefix),
      prefix,
      cursor,
      limit,
    );
  }

  @override
  Future<void> putImmutable({
    required String key,
    required List<int> body,
    required String contentType,
  }) async {
    final snapshot = Uint8List.fromList(body);
    await client.putImmutable(
      key: key,
      body: snapshot,
      contentType: contentType,
    );
    final readback = await client.get(
      key: key,
      responseLimit: snapshot.isEmpty ? 1 : snapshot.length,
    );
    if (readback.length != snapshot.length ||
        Digest.sha256Hex(readback) != Digest.sha256Hex(snapshot)) {
      throw const CosFailure(ConnectionFailure.contentMismatch);
    }
  }

  @override
  Future<void> putImmutableFile({
    required String key,
    required String filePath,
    required int byteCount,
    required String sha256,
    required String contentType,
  }) async {
    await client.putImmutableFile(
      key: key,
      filePath: filePath,
      byteCount: byteCount,
      sha256: sha256,
      contentType: contentType,
    );
    await verifyObject(key: key, byteCount: byteCount, sha256: sha256);
  }
}
