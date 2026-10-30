import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jinbao_core/jinbao_core.dart';

/// In-memory COS with the same behaviour as the Swift `MemoryCOS` test transport.
class MemoryCos implements ObjectTransport {
  final objects = <String, Uint8List>{};
  final requests = <ObjectRequest>[];
  String versioningBody = '<VersioningConfiguration/>';
  int versioningStatus = 200;

  @override
  Future<ObjectResponse> execute(ObjectRequest request) async {
    requests.add(request);
    switch (request.method) {
      case 'GET':
        if (request.path == '/') {
          if (request.query.containsKey('versioning')) {
            return ObjectResponse(status: versioningStatus, body: utf8.encode(versioningBody));
          }
          final prefix = request.query['prefix'] ?? '';
          final keys = objects.keys.where((k) => k.startsWith(prefix)).toList()..sort();
          final body = '<ListBucketResult><Name>example-1234567890</Name>'
              '${keys.map((k) => '<Contents><Key>$k</Key></Contents>').join()}'
              '<IsTruncated>false</IsTruncated></ListBucketResult>';
          return ObjectResponse(status: 200, body: utf8.encode(body));
        }
        final data = objects[request.path.substring(1)];
        if (data == null) return ObjectResponse(status: 404);
        if (request.responseFilePath != null) {
          File(request.responseFilePath!).writeAsBytesSync(data);
          return ObjectResponse(status: 200, headers: {'Content-Length': '${data.length}'});
        }
        return ObjectResponse(status: 200, headers: {'Content-Length': '${data.length}'}, body: data);
      case 'HEAD':
        final data = objects[request.path.substring(1)];
        if (data == null) return ObjectResponse(status: 404);
        return ObjectResponse(status: 200, headers: {
          'Content-Length': '${data.length}',
          'x-cos-meta-sha256': Digest.sha256Hex(data),
          'ETag': 'not-a-file-hash',
        });
      case 'PUT':
        final key = request.path.substring(1);
        if (objects.containsKey(key)) return ObjectResponse(status: 409, headers: {'ETag': 'not-a-file-hash'});
        objects[key] = request.bodyFilePath != null ? File(request.bodyFilePath!).readAsBytesSync() : request.body;
        return ObjectResponse(status: 200);
      default:
        return ObjectResponse(status: 405);
    }
  }
}

String uuid(int number) => '00000000-0000-4000-8000-${number.toString().padLeft(12, '0')}';

int millis(int year, int month, int day) => DateTime.utc(year, month, day, 12).millisecondsSinceEpoch;

const exampleCredentials = StorageCredentials(secretID: 'AKIDExample', secretKey: 'ExampleSecretKey');

CosClient memoryClient(MemoryCos memory, {String prefix = 'life/v1/'}) => CosClient(
      configuration: StorageConfiguration(bucket: 'example-1234567890', prefix: prefix),
      credentials: exampleCredentials,
      transport: memory,
      now: () => 1700000000,
    );

/// Repository-level shared fixtures (`spec/fixtures`), read from the package directory.
File fixture(String relative) => File('../../spec/fixtures/$relative');

Future<Object?> throwsOf(Future<void> Function() body) async {
  try {
    await body();
  } catch (error) {
    return error;
  }
  return null;
}

Object? syncThrowsOf(void Function() body) {
  try {
    body();
  } catch (error) {
    return error;
  }
  return null;
}
