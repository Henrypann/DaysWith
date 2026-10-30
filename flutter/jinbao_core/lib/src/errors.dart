class ContractError implements Exception {
  final String path;
  final String message;
  const ContractError(this.path, this.message);

  @override
  bool operator ==(Object other) => other is ContractError && other.path == path && other.message == message;

  @override
  int get hashCode => Object.hash(path, message);

  @override
  String toString() => '$path: $message';
}

enum ConnectionFailure {
  permission,
  invalidSecretID,
  expiredCredentials,
  signature,
  network,
  timeout,
  contentMismatch,
  configuration,
  secureStorage,
  conflict,
  notFound,
  unsafeVersioning;

  String get message => switch (this) {
        permission => '云存储权限不足，请检查两个家长文件夹的读取权限和本机文件夹的写入权限。',
        invalidSecretID => '密钥编号无法识别，请核对后重试。',
        expiredCredentials => '密钥已过期，请重新填写。',
        signature => '密钥或签名校验失败，请检查密钥和手机时间。',
        network => '暂时无法连接云存储，请检查网络后重试。',
        timeout => '连接超时，请检查网络后重试。',
        contentMismatch => '云端内容校验失败，请检查存储设置。',
        configuration => '请检查存储桶和地域代码。',
        secureStorage => '暂时无法安全保存密钥，请解锁手机后重试。',
        conflict => '云端已有不同内容，DaysWith 不会覆盖它。',
        notFound => '云端还没有这一份记录。',
        unsafeVersioning => '无法确认云存储的防覆盖状态。请检查版本控制查询权限；已启用或暂停版本控制的存储桶不能备份。',
      };
}

class CosFailure implements Exception {
  final ConnectionFailure failure;
  const CosFailure(this.failure);

  @override
  bool operator ==(Object other) => other is CosFailure && other.failure == failure;

  @override
  int get hashCode => failure.hashCode;

  @override
  String toString() => 'CosFailure(${failure.name})';
}
