import 'dart:io';
import 'dart:typed_data';

import 'package:jinbao_core/jinbao_core.dart';
import 'package:test/test.dart';

import 'support.dart';

class CorruptReadbackCos extends MemoryCos {
  @override
  Future<ObjectResponse> execute(ObjectRequest request) async {
    final response = await super.execute(request);
    if (request.method == 'GET' &&
        request.path != '/' &&
        response.status == 200) {
      if (request.responseFilePath != null) {
        final file = File(request.responseFilePath!);
        await file.writeAsBytes(List.filled(await file.length(), 0));
        return response;
      }
      return ObjectResponse(
        status: 200,
        body: Uint8List.fromList(List.filled(response.body.length, 0)),
      );
    }
    return response;
  }
}

void main() {
  test('adapter preserves COS safety gate and immutable headers', () async {
    final memory = MemoryCos();
    final provider = CosStorageProvider(memoryClient(memory));
    expect(provider.identity.providerId, 'cos');
    expect(provider.capabilities.quotaBytes, isNull);
    await provider.connect();
    expect(provider.capabilities.versioning, StorageVersioning.disabled);
    await provider.putImmutable(
      key: 'life/v1/test.json',
      body: [1, 2, 3],
      contentType: 'application/json',
    );
    final put = memory.requests.singleWhere((r) => r.method == 'PUT');
    expect(put.headers['x-cos-forbid-overwrite'], 'true');
    expect(
      memory.requests.any(
        (r) => r.method == 'GET' && r.path == '/life/v1/test.json',
      ),
      isTrue,
    );
    await expectLater(
      provider.delete('life/v1/test.json'),
      throwsA(isA<StorageProviderFailure>()),
    );
    memory.versioningBody = '<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>';
    await expectLater(
      provider.verifyImmutableWritesAllowed(),
      throwsA(const CosFailure(ConnectionFailure.unsafeVersioning)),
    );
    expect(provider.capabilities.conditionalWrites, isFalse);
    expect(memory.requests.every((r) => r.method != 'DELETE'), isTrue);
  });
  test(
    'adapter rejects successful metadata PUT with corrupt full readback',
    () async {
      final provider = CosStorageProvider(memoryClient(CorruptReadbackCos()));
      await expectLater(
        provider.putImmutable(
          key: 'life/v1/test.json',
          body: [1, 2, 3],
          contentType: 'application/json',
        ),
        throwsA(const CosFailure(ConnectionFailure.contentMismatch)),
      );
    },
  );
  test(
    'adapter media uploads and readback are file-backed and hash checked',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cos-provider-test-',
      );
      try {
        final file = File('${directory.path}/original')
          ..writeAsBytesSync([1, 2, 3, 4]);
        final facts = await Digest.sha256File(file.path);
        final memory = CorruptReadbackCos();
        final provider = CosStorageProvider(memoryClient(memory));
        await expectLater(
          provider.putImmutableFile(
            key: V1Layout.objectKey(prefix: 'life/v1/', sha256: facts.hash),
            filePath: file.path,
            byteCount: facts.byteCount,
            sha256: facts.hash,
            contentType: 'image/jpeg',
          ),
          throwsA(const CosFailure(ConnectionFailure.contentMismatch)),
        );
        expect(file.readAsBytesSync(), [1, 2, 3, 4]);
        expect(
          memory.requests.any(
            (r) => r.method == 'GET' && r.responseFilePath != null,
          ),
          isTrue,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
