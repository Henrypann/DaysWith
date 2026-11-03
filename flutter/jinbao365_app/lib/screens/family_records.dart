import 'package:flutter/material.dart';
import 'package:jinbao_core/jinbao_core.dart';

import '../family_data_controller.dart';
import 'family_media.dart';
import 'family_media_import.dart';

class FamilyRecordsScreen extends StatefulWidget {
  final FamilyGatewayClient client;
  final Family selectedFamily;
  final AppSession Function() currentLocalSession;
  final String localDirectory;
  final FamilyDataController? controller;
  final Future<void> Function()? onAddPhotos;
  final bool wifiOnlyUploads;
  final bool allowCellularOriginals;
  const FamilyRecordsScreen({super.key, required this.client, required this.selectedFamily,
    required this.currentLocalSession, required this.localDirectory, this.controller, this.onAddPhotos,
    this.wifiOnlyUploads = true, this.allowCellularOriginals = false});

  @override
  State<FamilyRecordsScreen> createState() => _FamilyRecordsScreenState();
}

class _FamilyRecordsScreenState extends State<FamilyRecordsScreen> {
  late FamilyDataController _controller;
  bool _ownsController = false;
  String? _screenError;

  @override
  void initState() { super.initState(); _attach(); }
  void _attach() {
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? FamilyDataController(client: widget.client,
      selectedFamily: widget.selectedFamily, currentLocalSession: widget.currentLocalSession,
      localDirectory: widget.localDirectory, wifiOnlyUploads: widget.wifiOnlyUploads,
      allowCellularOriginals: widget.allowCellularOriginals);
    _initialize();
  }
  Future<void> _initialize() async {
    final controller = _controller;
    try { await controller.initialize(); }
    catch (_) { if (mounted && identical(controller, _controller)) setState(() => _screenError = '家庭本机副本暂时无法读取，原记录未改动。'); }
  }
  @override
  void didUpdateWidget(covariant FamilyRecordsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client || oldWidget.selectedFamily.id != widget.selectedFamily.id ||
        oldWidget.localDirectory != widget.localDirectory || oldWidget.controller != widget.controller ||
        oldWidget.wifiOnlyUploads != widget.wifiOnlyUploads || oldWidget.allowCellularOriginals != widget.allowCellularOriginals) {
      if (_ownsController) _controller.dispose();
      _screenError = null;
      _attach();
    }
  }
  @override
  void dispose() { if (_ownsController) _controller.dispose(); super.dispose(); }

  Future<void> _copyLocal() async {
    final controller = _controller;
    final source = widget.currentLocalSession().copy();
    final selected = await showDialog<_LocalSelection>(context: context,
      builder: (_) => _LocalSelectionDialog(session: source));
    if (selected == null || !mounted || !identical(controller, _controller)) return;
    setState(() => _screenError = null);
    try {
      await controller.prepareLocalCopy(recordIDs: selected.records, includeAnniversaries: selected.includeAnniversaries);
      if (!mounted || !identical(controller, _controller) || controller.status != FamilyDataStatus.prepared) return;
      await _confirmUpload();
    } catch (_) {
      if (mounted && identical(controller, _controller)) setState(() => _screenError = '没有可复制的本人记录，或所选原件暂时不可用。');
    }
  }

  Future<void> _addPhotos() async {
    final controller = _controller;
    try {
      final custom = widget.onAddPhotos;
      if (custom != null) {
        await custom();
      } else {
        final continueToConfirm = await showFamilyMediaImport(context, controller: controller);
        if (!continueToConfirm || !mounted || !identical(controller, _controller)) return;
        await controller.prepareRetainedMedia();
        if (!mounted || !identical(controller, _controller) || controller.status != FamilyDataStatus.prepared) return;
        await _confirmUpload();
      }
      if (mounted && identical(controller, _controller)) setState(() => _screenError = null);
    } catch (_) {
      if (mounted && identical(controller, _controller)) setState(() => _screenError = '家庭草稿尚未完成，已导入的本机副本会保留，可以稍后继续。');
    }
  }

  Future<void> _confirmUpload() async {
    final controller = _controller;
    final confirmationID = controller.pendingConfirmationID;
    final summary = controller.pendingCopy;
    if (summary == null) return;
    final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('确认复制到家庭？'),
      content: Text('目标家庭：${summary.familyName}\n'
        '${summary.recordCount} 条记录 · ${summary.mediaCount} 项照片/视频\n'
        '${summary.anniversaryCount} 个纪念日 · 最多 ${_bytes(summary.byteCount)}\n\n'
        '网络规则：${controller.wifiOnlyUploads ? '仅在 Wi-Fi 或有线网络上传；其他网络保留等待' : '允许当前可用网络上传'}。\n\n'
        '只复制这次已选内容，稍后新增或修改的本机记录不包含在内。原本机记录、爸爸/妈妈目录和原件继续保留。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认上传')),
      ],
    ));
    if (!mounted || !identical(controller, _controller) ||
        confirmationID != controller.pendingConfirmationID) return;
    if (accepted != true) { controller.cancel(); return; }
    await controller.confirmAndUpload();
    if (!mounted || !identical(controller, _controller)) return;
    if (controller.status == FamilyDataStatus.verified) await controller.refresh();
  }

  Future<void> _retryPending() async {
    final controller = _controller;
    try {
      if (controller.hasUnpreparedSource) await controller.retryFrozenSource();
      if (mounted && identical(controller, _controller) && controller.pendingConfirmationID != null) {
        await _confirmUpload();
      }
    } catch (_) {
      if (mounted && identical(controller, _controller)) setState(() => _screenError = '草稿仍保存在本机，请检查网络与家庭登录状态后重试。');
    }
  }

  Future<void> _text({FamilyArchiveRecord? editing}) async {
    final controller = _controller;
    final value = await showDialog<_TextValue>(context: context,
      builder: (_) => _TextEditor(editing: editing));
    if (value == null || !mounted || !identical(controller, _controller)) return;
    setState(() => _screenError = null);
    try {
      await controller.prepareText(editing: editing, title: value.title,
        note: value.note, occurredAt: value.occurredAt);
      if (!mounted || !identical(controller, _controller) || controller.status != FamilyDataStatus.prepared) return;
      await _confirmUpload();
    } catch (_) {
      if (mounted && identical(controller, _controller)) setState(() => _screenError = '无法保存这条记录，请刷新并确认当前成员有编辑权限。');
    }
  }

  Future<void> _restore() async {
    final controller = _controller;
    final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('验证完整恢复？'),
      content: const Text('将下载家庭清单、完整原件和缩略图，逐一校验大小与哈希，保存到新的独立恢复目录。可能需要较多时间和本机空间。不会替换当前本机档案，也不会删除任何原件。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('开始验证恢复')),
      ],
    ));
    if (accepted == true && mounted && identical(controller, _controller)) await controller.restoreIsolated();
  }

  Future<void> _moderate(FamilyArchiveRecord record, {required bool hidden}) async {
    final controller = _controller;
    final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(hidden ? '从家庭时光隐藏这条记录？' : '恢复这条记录的展示？'),
      content: Text('家庭：${widget.selectedFamily.name}\n记录：${record.title.trim().isEmpty ? '生活记录' : record.title}\n'
        '署名：${_owner(record.ownerMemberID)}\n\n'
        '${hidden ? '隐藏后不再出现在家庭时光，作者也不能继续编辑。' : '恢复后重新出现在家庭时光。'}'
        '这是一项独立的管理员操作，会保存审计记录；不会删除或改写原件。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(hidden ? '确认隐藏' : '确认恢复展示')),
      ],
    ));
    if (accepted != true || !mounted || !identical(controller, _controller)) return;
    await controller.moderateRecord(record, hidden: hidden);
    if (mounted && identical(controller, _controller) && controller.status == FamilyDataStatus.verified) {
      await controller.refresh();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) {
      final activeRecords = _controller.records.where((record) => record.deletedAt == null && !_controller.isHidden(record)).toList();
      final hiddenRecords = _controller.records.where((record) => record.deletedAt == null && _controller.isHidden(record)).toList();
      final dates = _controller.anniversaries.where((date) => date.deletedAt == null).toList();
      return Scaffold(
        appBar: AppBar(title: Text(widget.selectedFamily.name), actions: [
          IconButton(onPressed: _controller.busy ? null : _controller.refresh,
            tooltip: '刷新家庭记录', icon: const Icon(Icons.refresh)),
        ]),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          const Text('家庭记录', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          if (_controller.showingCachedMetadata)
            const _Notice('当前显示上次已校验的本机清单缓存。原件未在此界面全部下载；离线缓存不授予编辑或上传权限。')
          else
            const _Notice('清单与完整原件分开校验。上传完成后，仍可进行一次独立完整恢复验证。'),
          const SizedBox(height: 12),
          Text(_status(_controller.status), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          if (_controller.busy) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: _controller.pause, icon: const Icon(Icons.pause), label: const Text('暂停操作')),
          ],
          if (_controller.errorMessage != null || _screenError != null)
            Padding(padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_controller.errorMessage ?? _screenError!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 16))),
          const SizedBox(height: 12),
          ...[
            FilledButton.icon(onPressed: _controller.busy || !_controller.canContribute ||
              _controller.hasPendingUpload && !_controller.hasRetainedMediaDraft ? null : _addPhotos,
              icon: const Icon(Icons.add_photo_alternate), label: const Text('添加照片或视频')),
            const SizedBox(height: 8),
            const Text('照片与视频先保存在本机家庭草稿。核对家庭、数量和网络规则并确认后才会分享，不需要爸爸/妈妈署名。', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 12),
          ],
          Wrap(spacing: 12, runSpacing: 12, children: [
            FilledButton.icon(onPressed: _controller.busy || _controller.hasPendingUpload || !_controller.canContribute ? null : () => _text(),
              icon: const Icon(Icons.edit_note), label: const Text('写一条家庭记录')),
            if (widget.currentLocalSession().identity != null)
              OutlinedButton.icon(onPressed: _controller.busy || _controller.hasPendingUpload || !_controller.canContribute ? null : _copyLocal,
                icon: const Icon(Icons.add_photo_alternate_outlined), label: const Text('复制本机照片与记录')),
            OutlinedButton.icon(onPressed: _controller.busy || _controller.familySnapshot == null ? null : _restore,
              icon: const Icon(Icons.fact_check_outlined), label: Text(_controller.hasIncompleteRestore ? '重试完整恢复' : '验证完整恢复')),
          ]),
          if (_controller.hasPendingUpload) ...[
            const SizedBox(height: 16),
            Text(_controller.hasUnpreparedSource ? '已有一份待准备的本机草稿。重试仍使用当时冻结的内容，不会自动上传。' : '已有一份冻结的上传选择，重试仍使用原来的记录与家庭目标。'),
            if (_controller.pendingDraftDescription != null)
              ExpansionTile(title: const Text('查看待上传草稿'), children: [
                Padding(padding: const EdgeInsets.all(12), child: SelectableText(_controller.pendingDraftDescription!)),
              ]),
            Wrap(spacing: 12, children: [
              FilledButton(onPressed: _controller.busy ? null : _retryPending, child: Text(_controller.hasUnpreparedSource ? '重试准备并确认' : '确认并重试上传')),
              TextButton(onPressed: _controller.busy ? null : _controller.cancel, child: const Text('取消这次上传')),
            ]),
          ],
          if (_controller.lastRestore case final result?) ...[
            const SizedBox(height: 20),
            Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('独立恢复校验完成', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text('${result.visibleRecords.where((r) => r.deletedAt == null).length} 条可见记录 · '
                '${result.anniversaries.where((a) => a.deletedAt == null).length} 个纪念日\n'
                '${result.verifiedResourceCount} 份原件/缩略图 · ${_bytes(result.verifiedByteCount)}'),
              const SizedBox(height: 8),
              const Text('文字、日期与成员归属保留在独立恢复副本中。当前本机档案保持原样；在线编辑仍须重新验证本人权限。'),
            ]))),
          ],
          const Divider(height: 36),
          Text('时光 · ${activeRecords.length} 条', style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600)),
          if (activeRecords.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('暂时没有可显示的家庭记录。')),
          for (final record in activeRecords) _recordCard(record),
          if (_controller.canModerate && hiddenRecords.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Text('已隐藏记录 · 管理员', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            for (final record in hiddenRecords) Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(record.title.trim().isEmpty ? '生活记录' : record.title, style: const TextStyle(fontSize: 18)),
                Text(_owner(record.ownerMemberID)),
                TextButton(onPressed: _controller.busy ? null : () => _moderate(record, hidden: false), child: const Text('恢复家庭展示')),
              ],
            ))),
          ],
          const SizedBox(height: 20),
          Text('纪念日 · ${dates.length} 个', style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600)),
          for (final date in dates) ListTile(contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.favorite_border), title: Text(date.title, style: const TextStyle(fontSize: 18)),
            subtitle: Text('${date.date} · ${_owner(date.ownerMemberID)}')),
        ]),
      );
    },
  );

  Widget _recordCard(FamilyArchiveRecord record) => Card(child: Padding(
    padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(record.title.trim().isEmpty ? '生活记录' : record.title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Text('${_date(record.occurredAt)} · ${_owner(record.ownerMemberID)}', style: const TextStyle(fontSize: 16)),
      if (record.note.isNotEmpty) ...[const SizedBox(height: 12), Text(record.note, style: const TextStyle(fontSize: 18))],
      if (record.assets.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('${record.assets.length} 项照片/视频 · 原件信息', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
        for (final asset in record.assets) ...[
          if (!_controller.showingCachedMetadata && _controller.familySnapshot != null)
            FamilyAssetPreview(key: ValueKey('${record.ownerMemberID}:${record.id}:${asset.id}'),
              controller: _controller, record: record, asset: asset)
          else
            const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('当前只有离线清单。联网刷新并验证家庭权限后，可查看照片和视频。')),
          Padding(padding: const EdgeInsets.only(top: 6), child: Text(
            '${asset.kind == 'video' ? '视频' : '照片'} · ${asset.capturedAt == 0 ? '拍摄时间未知' : _date(asset.capturedAt)}\n'
            '${asset.resources.where((r) => r.role != 'preview').map((r) => '${r.originalFilename} (${_bytes(r.byteCount)})').join('、')}',
          )),
        ],
      ],
      if (_controller.canEdit(record)) ...[
        const SizedBox(height: 10),
        TextButton.icon(onPressed: _controller.busy || _controller.hasPendingUpload ? null : () => _text(editing: record),
          icon: const Icon(Icons.edit_outlined), label: const Text('编辑我的文字')),
      ] else ...[
        const SizedBox(height: 8),
        Text('只读 · 编辑权限由当前登录成员决定', style: Theme.of(context).textTheme.bodySmall),
      ],
      if (_controller.canModerate)
        TextButton(onPressed: _controller.busy ? null : () => _moderate(record, hidden: true), child: const Text('从家庭时光隐藏')),
    ]),
  ));
  String _owner(String id) => _controller.ownerNames[id] ?? '成员 ${id.substring(0, 8)}';
}

class _Notice extends StatelessWidget {
  final String text;
  const _Notice(this.text);
  @override
  Widget build(BuildContext context) => Card(child: Padding(padding: const EdgeInsets.all(14), child: Text(text, style: const TextStyle(fontSize: 16))));
}

class _LocalSelection {
  final Set<String> records;
  final bool includeAnniversaries;
  const _LocalSelection(this.records, this.includeAnniversaries);
}
class _LocalSelectionDialog extends StatefulWidget {
  final AppSession session;
  const _LocalSelectionDialog({required this.session});
  @override
  State<_LocalSelectionDialog> createState() => _LocalSelectionDialogState();
}
class _LocalSelectionDialogState extends State<_LocalSelectionDialog> {
  late final _records = widget.session.moments.where((moment) => moment.parent == widget.session.identity && moment.trashedAt == null).toList();
  late final _selected = _records.map((record) => record.id).toSet();
  late final _dates = widget.session.anniversaries.where((date) => date.owner == widget.session.identity && date.deletedAt == null).length;
  bool _includeDates = true;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('选择复制到家庭的本机记录'),
    content: SizedBox(width: double.maxFinite, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('只显示本机当前爸爸/妈妈署名的记录。若家庭已有更新版本，请仅勾选新记录；不会用本机旧版本覆盖家庭记录。'),
      for (final record in _records) CheckboxListTile(
        key: ValueKey('local-family-copy:${record.id}'),
        contentPadding: EdgeInsets.zero,
        value: _selected.contains(record.id),
        title: Text(record.title.trim().isEmpty ? '生活记录' : record.title),
        subtitle: Text('${_date(record.occurredAt)} · ${record.assets.length} 项照片/视频'),
        onChanged: (selected) => setState(() { if (selected == true) { _selected.add(record.id); } else { _selected.remove(record.id); } }),
      ),
      if (_dates > 0) CheckboxListTile(contentPadding: EdgeInsets.zero, value: _includeDates,
        title: Text('同时复制 $_dates 个本人纪念日'), onChanged: (value) => setState(() => _includeDates = value ?? false)),
      if (_records.isEmpty && _dates == 0) const Padding(padding: EdgeInsets.all(16), child: Text('当前没有可复制的本人记录。可以先在本机添加照片或视频。')),
    ]))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: _selected.isEmpty && (!_includeDates || _dates == 0) ? null :
        () => Navigator.pop(context, _LocalSelection(Set.unmodifiable(_selected), _includeDates && _dates > 0)),
        child: const Text('准备复制')),
    ],
  );
}

class _TextValue {
  final String title, note;
  final int occurredAt;
  const _TextValue(this.title, this.note, this.occurredAt);
}
class _TextEditor extends StatefulWidget {
  final FamilyArchiveRecord? editing;
  const _TextEditor({this.editing});
  @override
  State<_TextEditor> createState() => _TextEditorState();
}
class _TextEditorState extends State<_TextEditor> {
  late final _title = TextEditingController(text: widget.editing?.title ?? '');
  late final _note = TextEditingController(text: widget.editing?.note ?? '');
  late DateTime _occurredAt = DateTime.fromMillisecondsSinceEpoch(widget.editing?.occurredAt ?? DateTime.now().millisecondsSinceEpoch);
  String? _error;
  @override
  void dispose() { _title.dispose(); _note.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.editing == null ? '写一条家庭记录' : '编辑我的文字'),
    content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: _title, maxLength: 200, decoration: const InputDecoration(labelText: '标题')),
      TextField(controller: _note, maxLength: 10000, minLines: 3, maxLines: 8, decoration: const InputDecoration(labelText: '想记住的事')),
      TextButton.icon(onPressed: () async {
        final picked = await showDatePicker(context: context, initialDate: _occurredAt,
          firstDate: DateTime(1970), lastDate: DateTime(9999, 12, 31));
        if (picked != null && mounted) setState(() => _occurredAt = picked);
      }, icon: const Icon(Icons.calendar_today_outlined), label: Text(_date(_occurredAt.millisecondsSinceEpoch))),
      if (_error != null) Text(_error!),
    ])),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: () {
        if (_title.text.trim().isEmpty && _note.text.trim().isEmpty && (widget.editing?.assets.isEmpty ?? true)) {
          setState(() => _error = '请写下标题或想记住的事。');
          return;
        }
        Navigator.pop(context, _TextValue(_title.text, _note.text, _occurredAt.millisecondsSinceEpoch));
      }, child: const Text('继续确认上传')),
    ],
  );
}
String _bytes(int count) => count < 1024 ? '$count B' : count < 1024 * 1024
    ? '${(count / 1024).toStringAsFixed(1)} KB' : '${(count / (1024 * 1024)).toStringAsFixed(1)} MB';
String _date(int timestamp) {
  final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}
String _status(FamilyDataStatus status) => switch (status) {
  FamilyDataStatus.idle => '等待手动操作', FamilyDataStatus.preparing => '正在准备待确认的副本',
  FamilyDataStatus.prepared => '副本已冻结，等待确认', FamilyDataStatus.uploading => '正在上传并校验',
  FamilyDataStatus.waitingForNetwork => '等待符合规则的网络，不会自动继续上传',
  FamilyDataStatus.paused => '已暂停，不会自动继续', FamilyDataStatus.failed => '操作未完成',
  FamilyDataStatus.verified => '本次操作已校验', FamilyDataStatus.restoring => '正在下载并独立校验完整副本',
  FamilyDataStatus.cancelled => '已取消这次上传',
};
