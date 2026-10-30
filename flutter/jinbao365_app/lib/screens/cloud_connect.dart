import 'package:flutter/material.dart';
import 'package:jinbao_core/jinbao_core.dart';

import '../app_model.dart';
import '../main.dart';
import '../theme.dart';

/// Port of CloudConnectView.swift. Unsubmitted secrets live only in this widget's
/// controllers and are cleared on success, cancel or leaving the page.
class CloudConnectView extends StatefulWidget {
  final bool mandatory;
  final bool editingConfiguration;
  const CloudConnectView({super.key, required this.mandatory, this.editingConfiguration = false});

  @override
  State<CloudConnectView> createState() => _CloudConnectViewState();
}

class _CloudConnectViewState extends State<CloudConnectView> with WidgetsBindingObserver {
  final _bucket = TextEditingController();
  final _region = TextEditingController();
  final _secretID = TextEditingController();
  final _secretKey = TextEditingController();
  final _token = TextEditingController();
  bool _revealID = false;
  bool _obscured = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final model = AppScope.read(context);
    _bucket.text = model.bucket;
    _region.text = model.region;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final controller in [_bucket, _region, _secretID, _secretKey, _token]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Hide the form while the app is in the app switcher.
    setState(() => _obscured = state != AppLifecycleState.resumed);
  }

  void _clearSecrets() {
    _secretID.clear();
    _secretKey.clear();
    _token.clear();
  }

  Future<void> _verify(AppModel model) async {
    FocusScope.of(context).unfocus();
    model.bucket = _bucket.text;
    model.region = _region.text;
    await model.verify(secretID: _secretID.text, secretKey: _secretKey.text, sessionToken: _token.text);
    if (!mounted) return;
    if (model.session.link is CloudVerified && !model.bannerIsError) {
      _clearSecrets();
      if (!widget.mandatory && widget.editingConfiguration) Navigator.of(context).maybePop();
    }
  }

  bool get _showsForm => widget.editingConfiguration || AppScope.read(context).session.link is! CloudVerified;

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    if (_obscured) {
      return const Center(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.lock, color: JinbaoColors.inkSecondary),
          SizedBox(width: 8),
          Text('连接信息已隐藏', style: TextStyle(color: JinbaoColors.inkSecondary)),
        ]),
      );
    }
    final link = model.session.link;
    final identity = model.session.identity;
    final showForm = widget.mandatory || _showsForm;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        const BrandMark(),
        const SizedBox(width: 12),
        Text(widget.mandatory ? '连接云存储' : '云备份', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
      ]),
      const SizedBox(height: 16),
      const Text('让每一份成长记录安心留下', style: TextStyle(fontSize: 16, color: JinbaoColors.inkSecondary)),
      if (link is CloudPlaceholder) ...[
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: JinbaoColors.goldSoft, borderRadius: BorderRadius.circular(12)),
          child: const Row(children: [
            Icon(Icons.smartphone, size: 18),
            SizedBox(width: 8),
            Text('占位连接 · 仅保存在这台手机', style: TextStyle(fontWeight: FontWeight.w600)),
          ]),
        ),
      ],
      if (identity != null) ...[
        const SizedBox(height: 16),
        Row(children: [
          const Text('这台手机', style: TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
          const SizedBox(width: 8),
          ParentBadge(identity),
        ]),
      ],
      const SizedBox(height: 16),
      if (!showForm)
        BrandCard(child: _connectedActions(model))
      else ...[
        const Text('填写具有所需目录权限的腾讯云密钥。密钥只保存在这台手机的安全存储里。',
            style: TextStyle(fontSize: 14, color: JinbaoColors.inkSecondary)),
        const SizedBox(height: 16),
        BrandCard(child: _form(model)),
      ],
      if (model.banner != null) ...[
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: model.bannerIsError ? JinbaoColors.problemSoft : JinbaoColors.goldSoft,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(model.banner!,
              style: TextStyle(color: model.bannerIsError ? JinbaoColors.problem : JinbaoColors.ink)),
        ),
      ],
      const SizedBox(height: 16),
      BrandCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('存储位置',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: JinbaoColors.inkSecondary)),
          const SizedBox(height: 6),
          SelectableText(_writePath(model), style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
          const SizedBox(height: 6),
          const Text('读取爸爸 life/v1/dad/ 和妈妈 life/v1/mom/，含各设备目录。旧根目录只读，云端文件不会删除。',
              style: TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
        ]),
      ),
    ]);
  }

  String _writePath(AppModel model) {
    try {
      return model.session.writerPrefix();
    } catch (_) {
      return '确认署名后才会确定文件夹';
    }
  }

  Widget _field(String title, TextEditingController controller, {bool secure = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: JinbaoColors.inkSecondary)),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            obscureText: secure,
            enableSuggestions: false,
            autocorrect: false,
            keyboardType: TextInputType.visiblePassword,
            decoration: InputDecoration(hintText: title),
          ),
        ]),
      );

  Widget _form(AppModel model) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _field('存储桶', _bucket),
        _field('地域', _region),
        _field('密钥编号', _secretID, secure: !_revealID),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => _revealID = !_revealID),
            child: Text(_revealID ? '隐藏密钥编号' : '显示密钥编号', style: const TextStyle(fontSize: 13)),
          ),
        ),
        _field('密钥', _secretKey, secure: true),
        _field('临时令牌（可选）', _token, secure: true),
        const Text('使用临时密钥时填写临时令牌；长期密钥可留空。令牌过期后需更新。编号和密钥各为 1 至 1024 位。',
            style: TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
        const SizedBox(height: 12),
        GoldButton(title: model.busy ? '正在验证…' : '验证并继续', enabled: !model.busy, onPressed: () => _verify(model)),
        TextButton(
          onPressed: () {
            _clearSecrets();
            model.cancelCloudConfiguration();
            _bucket.text = model.bucket;
            _region.text = model.region;
            if (!widget.mandatory) Navigator.of(context).maybePop();
          },
          child: const Text('取消配置'),
        ),
        if (AppModel.isTestBuild) ...[
          TextButton(
            onPressed: () {
              model.bucket = _bucket.text;
              model.region = _region.text;
              model.connectPlaceholder();
            },
            child: const Text('占位连接，先看时间线', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          const Text('占位只在测试版出现。它不保存密钥，也不上传。',
              style: TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
        ],
      ]);

  Widget _connectedActions(AppModel model) {
    final progress = model.backupProgress;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(model.backupStatusTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      Text('存储桶：${model.bucket}\n地域：${model.region}', style: const TextStyle(color: JinbaoColors.inkSecondary)),
      const SizedBox(height: 12),
      Text(model.backupStatusDetail, style: const TextStyle(color: JinbaoColors.inkSecondary)),
      if (progress != null) ...[
        const SizedBox(height: 12),
        LinearProgressIndicator(value: progress, color: JinbaoColors.ink, backgroundColor: JinbaoColors.separator),
      ],
      const SizedBox(height: 12),
      if (model.backupRunning)
        TextButton(onPressed: model.pauseBackup, child: const Text('暂停备份'))
      else ...[
        GoldButton(title: '立即备份 / 重试', enabled: !model.busy, onPressed: model.backupNow),
        TextButton(onPressed: model.backupNow, child: const Text('继续未完成的备份')),
      ],
      TextButton(onPressed: model.refreshRemote, child: const Text('重新读取家庭时光')),
      TextButton(
        style: TextButton.styleFrom(foregroundColor: JinbaoColors.problem),
        onPressed: () async {
          if (await confirmAction(context,
              title: '断开云存储？', message: '这台手机上的记录仍然保留。', confirm: '断开连接', destructive: true)) {
            await model.disconnect();
          }
        },
        child: const Text('断开云存储'),
      ),
    ]);
  }
}
