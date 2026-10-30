import 'errors.dart';
import 'text.dart';

enum ParentIdentity {
  dad,
  mom;

  String get label => this == dad ? '爸爸' : '妈妈';
  String get folder => name;
  String get prefix => 'life/v1/$folder/';
  ParentIdentity get other => this == dad ? mom : dad;

  static ParentIdentity? fromFolder(String? folder) => switch (folder) {
        'dad' => dad,
        'mom' => mom,
        _ => null,
      };
}

/// Keychain service owned by DaysWith. It must stay distinct from any ootd365 service.
abstract final class CredentialStoreContract {
  static const keychainService = 'com.henrypann.jinbao365.credentials';
  static const bundleIdentifier = 'com.henrypann.jinbao365';
  static const displayName = 'DaysWith';
}

class StorageCredentials {
  final String secretID;
  final String secretKey;
  final String? sessionToken;

  /// Unix seconds. A missing value lets COS enforce the token expiry.
  final int? expiresAt;

  const StorageCredentials({required this.secretID, required this.secretKey, this.sessionToken, this.expiresAt});

  bool get isValid =>
      validID(secretID) &&
      validKey(secretKey) &&
      (sessionToken == null || validSessionToken(sessionToken!)) &&
      (expiresAt == null || expiresAt! > 0);

  /// STS tokens are opaque header values, often longer than access keys.
  /// Printable ASCII excludes CR/LF, whitespace, DEL and Unicode controls.
  static bool validSessionToken(String value) {
    final length = value.length;
    return length >= 1 && length <= 16384 && value.codeUnits.every((unit) => unit >= 33 && unit <= 126);
  }

  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,1024}$');
  static final _key = RegExp(r'^[A-Za-z0-9_+/=-]{1,1024}$');

  static bool validID(String value) => _id.hasMatch(value);
  static bool validKey(String value) => _key.hasMatch(value);

  @override
  bool operator ==(Object other) =>
      other is StorageCredentials &&
      other.secretID == secretID &&
      other.secretKey == secretKey &&
      other.sessionToken == sessionToken &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(secretID, secretKey, sessionToken, expiresAt);

  @override
  String toString() => 'StorageCredentials(redacted)';
}

class StorageConfiguration {
  final String bucket;
  final String region;
  final String prefix;

  const StorageConfiguration({
    this.bucket = '',
    this.region = 'ap-shanghai',
    this.prefix = 'life/v1/',
  });

  String get host => '$bucket.cos.$region.myqcloud.com';

  static final _bucket = RegExp(r'^[a-z0-9][a-z0-9-]{1,48}-[0-9]{5,20}$');
  static final _region = RegExp(r'^[a-z]{2}-[a-z][a-z0-9-]{1,40}$');

  void validate() {
    if (!_bucket.hasMatch(bucket)) throw const ContractError('configuration.bucket', '请检查存储桶和地域代码。');
    if (!_region.hasMatch(region)) throw const ContractError('configuration.region', '请检查存储桶和地域代码。');
    V1Layout.validatePrefix(prefix);
  }

  @override
  bool operator ==(Object other) =>
      other is StorageConfiguration && other.bucket == bucket && other.region == region && other.prefix == prefix;

  @override
  int get hashCode => Object.hash(bucket, region, prefix);
}

/// Multi-device layout shared with Android 2.2.6.
abstract final class V1Layout {
  static const testRoot = 'life/v1/test/';

  static String identityRoot({required ParentIdentity parent, required bool test}) => test ? testRoot : parent.prefix;

  static String chainPrefix({required ParentIdentity parent, required String deviceID, required bool test}) {
    if (!uuidPattern.hasMatch(deviceID)) throw const ContractError('deviceID', 'Invalid device id');
    return '${identityRoot(parent: parent, test: test)}${deviceID.toLowerCase()}/';
  }

  static bool isDeviceSegment(String value) => uuidPattern.hasMatch(value);

  /// Device chains share the identity root's objects/. Legacy roots keep their own.
  static String objectRoot(String prefix) {
    final parts = prefix.split('/');
    final trimmed = prefix.endsWith('/') ? parts.sublist(0, parts.length - 1) : parts;
    if (trimmed.length >= 2 && isDeviceSegment(trimmed.last)) {
      return '${trimmed.sublist(0, trimmed.length - 1).join('/')}/';
    }
    return prefix;
  }

  static String objectKey({required String prefix, required String sha256}) =>
      '${objectRoot(prefix)}objects/${sha256.length >= 2 ? sha256.substring(0, 2) : sha256}/$sha256';

  static bool owns({required ParentIdentity owner, required String prefix}) =>
      prefix == owner.prefix || objectRoot(prefix) == owner.prefix || objectRoot(prefix) == testRoot;

  /// 忽略名单：`objects/`、只有快照没有提交的目录，以及身份根以外的键，都不是一条提交链。
  static List<String> chainsUnder({required String root, required List<String> keys}) {
    final found = <String>[];
    for (final key in keys) {
      if (!key.startsWith(root)) continue;
      final parts = key.substring(root.length).split('/');
      String? chain;
      if (parts.first == 'commits') {
        chain = root;
      } else if (parts.length >= 3 && isDeviceSegment(parts.first) && parts[1] == 'commits') {
        chain = '$root${parts.first}/';
      }
      if (chain != null && !found.contains(chain)) found.add(chain);
    }
    return found..sort();
  }

  static final _segment = RegExp(r'^[A-Za-z0-9_-]+$');

  static void validatePrefix(String prefix) {
    final parts = prefix.split('/');
    final body = prefix.endsWith('/') ? parts.sublist(0, parts.length - 1) : parts;
    final segmentsOK = prefix.endsWith('/') &&
        !prefix.startsWith('/') &&
        body.every((segment) => segment.isNotEmpty && segment != '.' && segment != '..' && _segment.hasMatch(segment));
    if (prefix.isEmpty || prefix.length > 256 || !segmentsOK) {
      throw const ContractError('configuration.prefix', 'The backup configuration is invalid.');
    }
  }

  static bool isLegacyRoot(String prefix) =>
      prefix == ParentIdentity.dad.prefix || prefix == ParentIdentity.mom.prefix;
}
