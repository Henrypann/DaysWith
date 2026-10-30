import 'dart:convert';

import 'package:jinbao_core/jinbao_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Language-neutral oracles shared with the Android and iOS apps.
void main() {
  for (final name in ['utf8-key-order', 'escapes-and-nesting']) {
    test('canonical JSON matches $name', () {
      final document = JsonWire.parse(fixture('canonical/$name.json').readAsBytesSync(), path: name) as Map;
      final canonical = JsonWire.encodeString(document['input']);
      expect(canonical, document['canonical']);
      expect(Digest.sha256Hex(utf8.encode(canonical)), document['sha256']);
    });
  }

  test('NFC and NFD keys stay distinct when parsed', () {
    final document = JsonWire.parse(fixture('canonical/utf8-key-order.json').readAsBytesSync(), path: 'f') as Map;
    expect((document['input'] as Map).length, 7);
  });

  test('COS signature matches shared signing vectors', () {
    final document = jsonDecode(fixture('credentials/signing.json').readAsStringSync()) as Map;
    for (final item in (document['cases'] as List).cast<Map>()) {
      final signer = CosSigner(
          StorageCredentials(secretID: item['secretID'] as String, secretKey: item['secretKey'] as String));
      final authorization = signer.authorization(
        method: item['method'] as String,
        path: item['path'] as String,
        query: (item['query'] as Map).cast<String, String>(),
        headers: (item['headers'] as Map).cast<String, String>(),
        now: item['now'] as int,
        validFor: item['validFor'] as int,
      );
      expect(authorization, item['authorization'], reason: item['id'] as String);
    }
  });
}
