import 'package:flutter/material.dart';
import 'package:jinbao_core/jinbao_core.dart';

import '../app_model.dart';
import '../main.dart';
import '../theme.dart';
import 'cloud_connect.dart';

/// Every explicit backup request reviews the target and data volume first.
/// Queue retries use the same review entry; a changed target needs a new review.
Future<void> confirmStorageBackup(BuildContext context) async {
  final model = AppScope.read(context);
  final link = model.session.link;
  if (!link.isVerified || model.busy || model.backupRunning || model.restoring)
    return;
  final records = model.backupRecordCount;
  final media = model.backupMediaCount;
  final bytes = model.backupByteCount;
  final wifiOnly = model.wifiOnlyBackup;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('确认备份'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('目标：${model.storageTargetLabel}'),
            const SizedBox(height: 12),
            Text('共 $records 条记录，$media 项照片或视频'),
            const SizedBox(height: 8),
            Text('总大小：${storageByteLabel(bytes)}（包含预览）'),
            const SizedBox(height: 8),
            Text(wifiOnly ? '网络策略：Wi-Fi 优先' : '网络策略：允许移动网络'),
            const SizedBox(height: 12),
            const Text('纪念日随清单保存。本机原件会保留；重复重试不会重复创建已有记录。'),
          ],
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('开始备份'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  if (model.session.link != link ||
      records != model.backupRecordCount ||
      media != model.backupMediaCount ||
      bytes != model.backupByteCount ||
      wifiOnly != model.wifiOnlyBackup) {
    model.show(const ContractError('backup', '存储目标或记录已变化，请重新确认备份。'));
    return;
  }
  await model.backupNow();
}

Future<void> confirmIsolatedRestore(BuildContext context) async {
  final model = AppScope.read(context);
  final link = model.session.link;
  if (!link.isVerified ||
      model.busy ||
      model.backupRunning ||
      model.restoring) {
    return;
  }
  final previous = model.lastRestoreResult;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('下载一份独立恢复副本？'),
      content: const SingleChildScrollView(
        child: Text(
          '将从当前存储下载清单和完整原件，校验后保存在新的隔离目录。'
          '本机现有记录不会被替换，云端内容不会改动。此操作用于恢复验证，不能代替新手机上的实际恢复验收。',
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('下载并校验'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  if (model.session.link != link) {
    model.show(const ContractError('restore', '存储目标已变化，请重新确认恢复来源。'));
    return;
  }
  await model.restoreToIsolatedCopy();
  if (!context.mounted) return;
  final result = model.lastRestoreResult;
  if (result != null &&
      !identical(result, previous) &&
      model.restoreError == null) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RestoreSummaryPage(result: result),
      ),
    );
  }
}

String storageByteLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
}

/// The current target and transport state, rather than a promise of recoverability.
class StorageCenterPage extends StatelessWidget {
  const StorageCenterPage({super.key});

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final lastSuccess = model.lastSuccessfulBackup;
    return Scaffold(
      appBar: AppBar(title: const Text('数据与存储')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          BrandCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '主要存储',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Text(
                  model.storageTargetLabel,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(model.storageHealthLabel),
                const SizedBox(height: 12),
                Text(
                  '最近成功备份：${lastSuccess == null ? '暂无' : _date(lastSuccess)}',
                ),
                const SizedBox(height: 6),
                const Text(
                  '可用空间：未知',
                  style: TextStyle(color: JinbaoColors.inkSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          BrandCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  model.backupStatusTitle,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '待处理 ${model.pendingStorageCount} 项 · 失败 ${model.failedStorageCount} 项',
                ),
                const SizedBox(height: 10),
                Text(model.backupStatusDetail),
                if (model.backupProgress != null) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: model.backupProgress),
                ],
                if (model.banner != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    model.banner!,
                    style: TextStyle(
                      color: model.bannerIsError
                          ? JinbaoColors.problem
                          : JinbaoColors.ink,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                GoldButton(
                  title: model.backupRunning ? '正在传输…' : '备份 / 重试',
                  enabled:
                      !model.busy &&
                      !model.backupRunning &&
                      !model.restoring &&
                      model.session.link.isVerified,
                  onPressed: () => confirmStorageBackup(context),
                ),
                const SizedBox(height: 12),
                const Text(
                  '已验证远端副本表示已完成传输校验，仍需在另一环境完成恢复验证。',
                  style: TextStyle(color: JinbaoColors.inkSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          BrandCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '恢复验证',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                const Text('下载完整清单和原件，在独立目录重建档案，不替换当前记录。'),
                if (model.restoring) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  const Text('正在下载与校验完整原件，请保持应用在前台…'),
                ],
                if (model.restoreError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    model.restoreError!,
                    style: const TextStyle(color: JinbaoColors.problem),
                  ),
                ],
                const SizedBox(height: 12),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed:
                      !model.session.link.isVerified ||
                          model.busy ||
                          model.backupRunning ||
                          model.restoring
                      ? null
                      : () => confirmIsolatedRestore(context),
                  child: const Text('下载独立恢复副本'),
                ),
                if (model.lastRestoreResult != null)
                  TextButton(
                    onPressed: () => _open(
                      context,
                      RestoreSummaryPage(result: model.lastRestoreResult!),
                    ),
                    child: const Text('查看上次恢复验证'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Material(
            color: JinbaoColors.surface,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: SwitchListTile(
              title: const Text('Wi-Fi 优先'),
              subtitle: const Text('开启后，移动网络下的上传等待 Wi-Fi。'),
              value: model.wifiOnlyBackup,
              onChanged: model.busy || model.backupRunning || model.restoring
                  ? null
                  : model.setWifiOnlyBackup,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '连接设置',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          BrandCard(
            padding: 0,
            child: Column(
              children: [
                FeatureRow(
                  title: '腾讯云 COS',
                  subtitle: '保留已有连接与档案格式',
                  icon: Icons.cloud_outlined,
                  onTap: model.busy || model.backupRunning || model.restoring
                      ? null
                      : () => _open(
                          context,
                          Scaffold(
                            appBar: AppBar(title: const Text('连接腾讯云 COS')),
                            body: const SafeArea(
                              child: CloudConnectView(
                                mandatory: false,
                                editingConfiguration: true,
                              ),
                            ),
                          ),
                        ),
                ),
                const Divider(),
                FeatureRow(
                  title: 'NAS · HTTPS WebDAV',
                  subtitle: '使用自己的 NAS 专用目录和账号',
                  icon: Icons.storage_outlined,
                  onTap: model.busy || model.backupRunning || model.restoring
                      ? null
                      : () => _open(context, const WebDavConnectPage()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '每次只使用一个主要存储。更换连接不会自动迁移、合并或删除旧存储中的记录。',
            style: TextStyle(color: JinbaoColors.inkSecondary),
          ),
          if (model.session.link.isVerified) ...[
            const SizedBox(height: 16),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: model.busy || model.backupRunning || model.restoring
                  ? null
                  : () async {
                      if (await confirmAction(
                        context,
                        title: '断开存储连接？',
                        message: '本机记录和原存储中的副本都会保留。',
                        confirm: '断开连接',
                      )) {
                        await model.disconnect();
                      }
                    },
              child: const Text('断开连接'),
            ),
          ],
        ],
      ),
    );
  }

  static String _date(DateTime value) =>
      '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)} '
      '${twoDigits(value.hour)}:${twoDigits(value.minute)}';

  static void _open(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
}

class WebDavConnectPage extends StatefulWidget {
  const WebDavConnectPage({super.key});

  @override
  State<WebDavConnectPage> createState() => _WebDavConnectPageState();
}

class _WebDavConnectPageState extends State<WebDavConnectPage>
    with WidgetsBindingObserver {
  final _name = TextEditingController(text: '家庭 NAS');
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _obscured = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _obscured = state != AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final controller in [_name, _url, _username, _password]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _verify(AppModel model) async {
    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);
    try {
      await model.verifyWebDav(
        name: _name.text,
        url: _url.text,
        username: _username.text,
        password: _password.text,
      );
      if (!mounted) return;
      if (model.session.link.isVerified && !model.bannerIsError) {
        _password.clear();
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (mounted) model.show(const ContractError('webdav', '连接未完成，请检查设置后重试。'));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('连接 NAS')),
      body: _obscured
          ? const Center(child: Text('连接信息已隐藏'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'HTTPS WebDAV',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  '请使用 NAS 管理员准备的专用账号。专用目录须以 DaysWith 或 dayswith-名称结尾。连接仅用于这台手机，不作为家庭成员邀请。',
                ),
                const SizedBox(height: 16),
                _field('连接名称', _name),
                _field(
                  'HTTPS 专用目录地址',
                  _url,
                  hint: 'https://nas.example.com/dav/DaysWith/',
                  keyboard: TextInputType.url,
                ),
                _field('专用账号', _username),
                _field('密码', _password, secret: true),
                const Text(
                  '证书必须有效，无法跳过 TLS 检查。可使用你已配置的 VPN 或隧道。',
                  style: TextStyle(color: JinbaoColors.inkSecondary),
                ),
                const SizedBox(height: 12),
                const Text(
                  '验证会在专用目录写入并读取一份连接测试文件；正式照片仍保存在本机。',
                  style: TextStyle(color: JinbaoColors.inkSecondary),
                ),
                if (model.banner != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    model.banner!,
                    style: TextStyle(
                      color: model.bannerIsError
                          ? JinbaoColors.problem
                          : JinbaoColors.ink,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                GoldButton(
                  title: _submitting || model.busy ? '正在验证…' : '验证并连接',
                  enabled:
                      !_submitting &&
                      !model.busy &&
                      !model.backupRunning &&
                      !model.restoring,
                  onPressed: () => _verify(model),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _submitting
                      ? null
                      : () {
                          _password.clear();
                          Navigator.of(context).pop();
                        },
                  child: const Text('取消'),
                ),
              ],
            ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    bool secret = false,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      controller: controller,
      enabled: !_submitting,
      obscureText: secret,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      autocorrect: false,
      keyboardType: keyboard ?? TextInputType.visiblePassword,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );
}

/// A view of the isolated result only. It never activates a recovered identity,
/// changes the current archive or grants write permissions.
class RestoreSummaryPage extends StatelessWidget {
  final ArchiveRestoreResult result;
  const RestoreSummaryPage({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final entries = result.session.timelineEntries();
    final anniversaries =
        result.session.anniversaries.where((a) => a.deletedAt == null).length +
        result.session.remoteAnniversaries
            .where((a) => a.deletedAt == null)
            .length;
    final originals = <String, ({String name, int bytes, String hash})>{};
    for (final entry in entries) {
      for (final photo in entry.photos) {
        for (final resource in photo.localResources) {
          if (resource.role != 'preview') {
            originals[resource.sha256] = (
              name: resource.originalFilename,
              bytes: resource.byteCount,
              hash: resource.sha256,
            );
          }
        }
        for (final resource in photo.remoteResources) {
          if (resource.role != 'preview') {
            originals[resource.sha256] = (
              name: resource.originalFilename,
              bytes: resource.byteCount,
              hash: resource.sha256,
            );
          }
        }
      }
    }
    return Scaffold(
      appBar: AppBar(title: const Text('独立恢复副本')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          BrandCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '完整下载与哈希校验已完成',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Text('可见记录 ${entries.length} 条 · 已保存纪念日 $anniversaries 项'),
                const SizedBox(height: 8),
                Text(
                  '已校验 ${result.verifiedObjectCount} 个对象，${storageByteLabel(result.verifiedBytes)}',
                ),
                const SizedBox(height: 8),
                Text('完整原件引用 ${result.originalResourceCount} 项（包含来源清单中的回收站项目）'),
                const SizedBox(height: 12),
                const Text('这是独立的离线副本，当前档案没有切换。新设备恢复、存储连接和编辑归属仍须单独核验。'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '记录核对',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: BrandCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title.isEmpty ? '无标题记录' : entry.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text('原署名：${entry.parent.label} · ${entry.mediaCount} 项媒体'),
                    if (entry.note.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(entry.note),
                    ],
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          const Text(
            '可见记录的已验证原件',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          for (final original in originals.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: BrandCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(original.name),
                    const SizedBox(height: 6),
                    Text(storageByteLabel(original.bytes)),
                    const SizedBox(height: 6),
                    SelectableText(
                      'SHA-256 ${original.hash}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          const Text(
            '副本位置',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          SelectableText(result.directory),
        ],
      ),
    );
  }
}
