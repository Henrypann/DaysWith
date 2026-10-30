import 'dart:convert';

import 'digest.dart';
import 'errors.dart';
import 'text.dart';

/// Published legacy v1 identities depend on this namespace. Never change it after publication.
abstract final class V1Ids {
  static const namespace = '6F0F3B0E-6B2F-5C55-9E57-0D365A7D0001';

  static String map({required String kind, required String localID}) {
    if (kind != 'record' && kind != 'asset' && kind != 'resource') {
      throw const ContractError('id', 'Unsupported v1 identity kind.');
    }
    final stripped = (kind == 'record' && localID.startsWith('rec-')) ? localID.substring(4) : localID;
    if (uuidPattern.hasMatch(stripped)) return stripped.toUpperCase();
    return legacyID(kind: kind, localID: localID);
  }

  static String legacyID({required String kind, required String localID}) {
    if (kind != 'record' && kind != 'asset' && kind != 'resource') {
      throw const ContractError('id', 'Unsupported v1 identity kind.');
    }
    if (uuidPattern.hasMatch(localID)) {
      throw const ContractError('id', 'Canonical UUIDs must be uploaded directly.');
    }
    return uuidV5(namespace: namespace, name: '$kind:$localID').toUpperCase();
  }

  static String canonical(String value, {required String path}) {
    if (!uuidPattern.hasMatch(value)) throw ContractError(path, 'Expected a UUID.');
    return value.toUpperCase();
  }

  /// RFC 4122 version 5. The returned text is lowercase.
  static String uuidV5({required String namespace, required String name}) {
    final digest = Digest.sha1([...uuidBytes(namespace), ...utf8.encode(name)]).toList();
    digest[6] = (digest[6] & 0x0f) | 0x50;
    digest[8] = (digest[8] & 0x3f) | 0x80;
    return format(digest.sublist(0, 16), upper: false);
  }

  static List<int> uuidBytes(String value) {
    final hex = value.replaceAll('-', '');
    return [for (var i = 0; i + 2 <= hex.length; i += 2) int.tryParse(hex.substring(i, i + 2), radix: 16) ?? 0];
  }

  static String format(List<int> bytes, {required bool upper}) {
    var hex = Digest.hex(bytes);
    if (upper) hex = hex.toUpperCase();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
