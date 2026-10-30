import 'package:flutter/material.dart';
import 'package:jinbao_core/jinbao_core.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_model.dart';
import '../main.dart';
import '../theme.dart';
import 'cloud_connect.dart';
import 'shell.dart';

/// Port of MyView.swift and SettingsView.swift.
class MyScreen extends StatelessWidget {
  const MyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final records = model.session.timelineEntries();
    final identity = model.session.identity;
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        BrandCard(
          padding: 20,
          child: Column(children: [
            Row(children: [
              const BrandMark(size: 58),
              const SizedBox(width: 14),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('共同的生活档案', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                if (identity != null) ...[const SizedBox(height: 6), ParentBadge(identity)],
              ]),
            ]),
            const SizedBox(height: 18),
            Row(children: [
              _count('记录', records.length),
              _count('媒体', records.fold(0, (n, e) => n + e.mediaCount)),
              _count('纪念日', model.session.anniversaryEntries().length),
            ]),
          ]),
        ),
        const SizedBox(height: 16),
        Material(
          color: JinbaoColors.surface,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            FeatureRow(
                title: '家庭时光',
                subtitle: '爸爸和妈妈一起留下的记录',
                icon: Icons.photo_library_outlined,
                onTap: () => model.selectTab(ShellTab.timeline)),
            const Divider(),
            FeatureRow(
                title: '未完成的记录',
                subtitle: model.session.draft == null ? '只在这台手机、最多一条' : '可以继续编辑',
                icon: Icons.edit_note,
                onTap: () => _push(context, const DraftsPage())),
            const Divider(),
            FeatureRow(
                title: '云备份',
                subtitle: model.backupStatusTitle,
                icon: Icons.cloud_outlined,
                onTap: () => _push(context, const CloudPage(title: '云备份'))),
            const Divider(),
            FeatureRow(
                title: '设置', subtitle: '连接、存储与应用信息', icon: Icons.settings_outlined, onTap: () => _push(context, const SettingsPage())),
          ]),
        ),
        const SizedBox(height: 24),
        const Center(child: Text('记录成长，收藏美好', style: TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary))),
      ]),
    );
  }

  Widget _count(String title, int value) => Expanded(
        child: Column(children: [
          Text('$value', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(title, style: const TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
        ]),
      );
}

void _push(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

class CloudPage extends StatelessWidget {
  final String title;
  final bool editing;
  const CloudPage({super.key, required this.title, this.editing = false});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: CloudConnectView(mandatory: false, editingConfiguration: editing),
      );
}

class DraftsPage extends StatelessWidget {
  const DraftsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final draft = model.session.draft;
    return Scaffold(
      appBar: AppBar(title: const Text('未完成的记录')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('只在这台手机、最多一条。没写完就离开，或应用意外退出，会留在这里。',
            style: TextStyle(color: JinbaoColors.inkSecondary)),
        const SizedBox(height: 14),
        if (draft != null)
          BrandCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(draft.title.isEmpty ? '未完成的小日常' : draft.title,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              if (draft.note.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(draft.note, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: JinbaoColors.inkSecondary)),
              ],
              const SizedBox(height: 12),
              Text('${draft.assets.length}个媒体文件 · 保存在这台手机',
                  style: const TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
              const SizedBox(height: 12),
              GoldButton(title: '继续编辑', onPressed: () => openComposer(context)),
              Center(
                child: TextButton(
                  style: TextButton.styleFrom(foregroundColor: JinbaoColors.problem),
                  onPressed: () async {
                    if (await confirmAction(context,
                        title: '放弃这条未完成的记录？',
                        message: '会从这台手机移除，已保存的记录不受影响。',
                        confirm: '放弃',
                        destructive: true)) {
                      model.discardDraft();
                    }
                  },
                  child: const Text('放弃这条记录'),
                ),
              ),
            ]),
          )
        else ...[
          const FeatureEmptyState(title: '还没有未完成的记录', detail: '只在这台手机、最多一条。', icon: Icons.edit_note),
          GoldButton(title: '写一条记录', onPressed: () => openComposer(context)),
        ],
      ]),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  String _bytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    if (value < 1024 * 1024 * 1024) return '${(value / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(value / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  Widget _section(String title, List<Widget> children, {String? footer}) => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(title, style: const TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
          ),
          Material(
            color: JinbaoColors.surface,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Column(children: children),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(footer, style: const TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
            ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final identity = model.session.identity;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _section('这台手机', [
          if (identity != null) ListTile(title: const Text('署名'), trailing: ParentBadge(identity)),
          const ListTile(
              subtitle: Text('署名已确认，用来区分爸爸和妈妈的记录。', style: TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary))),
        ]),
        _section('云备份', [
          ListTile(
            title: Text(model.backupStatusTitle),
            subtitle: Text(model.backupStatusDetail, style: const TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _push(context, const CloudPage(title: '云备份')),
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('编辑连接'),
            onTap: () => _push(context, const CloudPage(title: '连接设置', editing: true)),
          ),
          if (model.session.link.bucket != null)
            ListTile(
              title: const Text('断开云存储', style: TextStyle(color: JinbaoColors.problem)),
              onTap: () async {
                if (await confirmAction(context,
                    title: '断开云存储？',
                    message: '这台手机上的记录仍然保留。重新连接后可继续读取云端档案。',
                    confirm: '断开连接',
                    destructive: true)) {
                  await model.disconnect();
                }
              },
            ),
        ]),
        _section('网络', [
          SwitchListTile(
            title: const Text('允许蜂窝网络下载原件'),
            value: model.allowCellularOriginals,
            onChanged: model.setAllowCellularOriginals,
          ),
        ], footer: '关闭后，使用蜂窝网络查看云端原件时会先询问。已经缓存的原件可以离线查看。'),
        _section('本机档案', [
          ListTile(
              leading: const Icon(Icons.edit_note), title: const Text('未完成的记录'), onTap: () => _push(context, const DraftsPage())),
          ListTile(
              leading: const Icon(Icons.delete_outline), title: const Text('回收站'), onTap: () => _push(context, const TrashPage())),
          ListTile(
            title: const Text('本机存储占用'),
            trailing: Text(_bytes(model.localStorageBytes), style: const TextStyle(color: JinbaoColors.inkSecondary)),
          ),
        ]),
        _section('关于', [
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, info) => ListTile(
              title: const Text('版本'),
              trailing: Text(info.hasData ? '${info.data!.version} (${info.data!.buildNumber})' : '',
                  style: const TextStyle(color: JinbaoColors.inkSecondary)),
            ),
          ),
          ListTile(
            title: const Text('设备编号'),
            subtitle: SelectableText(model.session.deviceID, style: const TextStyle(fontSize: 12)),
          ),
          ListTile(
            title: const Text('写入目录'),
            subtitle: Text(AppModel.isTestBuild ? '测试版：只写入 life/v1/test/' : '正式版：写入本机署名目录',
                style: const TextStyle(fontSize: 12)),
          ),
          const ListTile(
            subtitle: Text('Flutter 版：Android 与 iOS 共用同一套界面和数据格式，与原生版云端档案互通。',
                style: TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
          ),
        ]),
      ]),
    );
  }
}

class TrashPage extends StatelessWidget {
  const TrashPage({super.key});

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final moments = model.session.moments.where((m) => m.trashedAt != null).toList()
      ..sort((a, b) => (b.trashedAt ?? 0).compareTo(a.trashedAt ?? 0));
    return Scaffold(
      appBar: AppBar(title: const Text('回收站')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (moments.isEmpty)
          const FeatureEmptyState(title: '回收站是空的', detail: '移除的本机记录会保留在这里，可以随时恢复。', icon: Icons.delete_outline)
        else ...[
          const Text('这里只保留这台手机移除的记录。恢复会重新显示记录，云端原件不会被删除。',
              style: TextStyle(color: JinbaoColors.inkSecondary)),
          const SizedBox(height: 14),
          for (final moment in moments) ...[
            _card(context, model, moment),
            const SizedBox(height: 14),
          ],
        ],
      ]),
    );
  }

  Widget _card(BuildContext context, AppModel model, LocalMoment moment) {
    final title = moment.title.isEmpty ? (moment.note.isEmpty ? '值得留住的小日常' : moment.note) : moment.title;
    final when = moment.occurredAt > 0 ? DateTime.fromMillisecondsSinceEpoch(moment.occurredAt) : null;
    return BrandCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Text(
            when == null
                ? '日期未知'
                : '${when.year}年${when.month}月${when.day}日 ${clockText(moment.occurredAt)}',
            style: const TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
        const SizedBox(height: 4),
        Text('${moment.assets.length}个媒体文件', style: const TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
        const SizedBox(height: 12),
        GoldButton(title: '恢复记录', onPressed: () => model.restoreMoment(moment.id)),
      ]),
    );
  }
}
