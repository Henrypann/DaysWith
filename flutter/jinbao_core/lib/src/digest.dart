import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'errors.dart';
import 'v1_validator.dart';

/// SHA-1 is required by the COS signature. SHA-256 identifies file bytes. Neither result is logged with a secret.
abstract final class Digest {
  static List<int> sha1(List<int> message) => crypto.sha1.convert(message).bytes;

  static List<int> sha256(List<int> message) => crypto.sha256.convert(message).bytes;

  static String sha256Hex(List<int> data) => crypto.sha256.convert(data).toString();

  static List<int> hmacSha1({required List<int> key, required List<int> message}) =>
      crypto.Hmac(crypto.sha1, key).convert(message).bytes;

  static String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Bounded reads; media bytes are never accumulated in memory.
  static Future<({String hash, int byteCount})> sha256File(String path,
      {int maximumBytes = V1Validator.maxResourceBytes}) async {
    final output = _DigestSink();
    final input = crypto.sha256.startChunkedConversion(output);
    var count = 0;
    final file = await File(path).open();
    try {
      while (true) {
        final chunk = await file.read(1024 * 1024);
        if (chunk.isEmpty) break;
        count += chunk.length;
        if (count > maximumBytes) throw const CosFailure(ConnectionFailure.contentMismatch);
        input.add(chunk);
      }
    } finally {
      await file.close();
    }
    input.close();
    return (hash: output.value.toString(), byteCount: count);
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}
