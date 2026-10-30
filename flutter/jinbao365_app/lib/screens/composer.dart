import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:jinbao_core/jinbao_core.dart';

import '../app_model.dart';
import '../main.dart';
import '../theme.dart';
import 'media_viewer.dart';
import 'shell.dart';
import 'timeline.dart';

class _ImportRequest {
  final XFile file;
  final ImportProvenance provenance;
  String? message;
  _ImportRequest(this.file, this.provenance);
}

/// Port of ComposerView.swift. Every keystroke, time change and media change is saved
/// into the durable draft, so closing or killing the app never loses work.
class ComposerPage extends StatefulWidget {
  final ComposerStart start;
  const ComposerPage({super.key, this.start = ComposerStart.resume});

  @override
  State<ComposerPage> createState() => _ComposerPageState();
}

class _ComposerPageState extends State<ComposerPage> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  final _picker = ImagePicker();
  final List<_ImportRequest> _requests = [];
  bool _importing = false;
  String _progress = '';

  @override
  void initState() {
    super.initState();
    final draft = AppScope.read(context).session.draft;
    _title.text = draft?.title ?? '';
    _note.text = draft?.note ?? '';
    _title.addListener(_sync);
    _note.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      switch (widget.start) {
        case ComposerStart.pickMedia:
          _pickMedia();
        case ComposerStart.camera:
          _camera();
        case ComposerStart.resume:
          break;
      }
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  void _sync() {
    AppScope.read(context).updateDraft(_title.text, _note.text);
    setState(() {});
  }

  List<LocalAsset> get _assets => AppScope.read(context).session.draft?.assets ?? const [];

  bool get _canSave =>
      !_importing && (swiftTrim(_title.text).isNotEmpty || swiftTrim(_note.text).isNotEmpty || _assets.isNotEmpty);

  Future<void> _pickMedia() async {
    FocusScope.of(context).unfocus();
    final remaining = 30 - _assets.length;
    if (remaining <= 0) return;
    try {
      final files = remaining == 1
          ? [?await _picker.pickMedia()]
          : await _picker.pickMultipleMedia(limit: remaining, requestFullMetadata: true);
      if (files.isEmpty) return; // Cancelling never clears the draft.
      _requests.addAll(files.map((f) => _ImportRequest(f, ImportProvenance.systemProvided)));
      await _importRequests();
    } catch (error) {
      if (mounted) AppScope.read(context).show(const ContractError('media', '无法打开相册，请检查权限后重试。'));
    }
  }

  Future<void> _camera() async {
    FocusScope.of(context).unfocus();
    if (_assets.length >= 30) return;
    try {
      final file = await _picker.pickImage(source: ImageSource.camera, requestFullMetadata: true);
      if (file == null) return;
      _requests.add(_ImportRequest(file, ImportProvenance.camera));
      await _importRequests();
    } catch (_) {
      if (mounted) {
        AppScope.read(context)
            .show(const ContractError('camera', '相机权限未开放，可在系统设置中允许后再拍照。你仍可选图或写文字。'));
      }
    }
  }

  Future<void> _importRequests({_ImportRequest? only}) async {
    if (_importing) return;
    final model = AppScope.read(context);
    setState(() => _importing = true);
    final prepared = <LocalAsset>[];
    final done = <_ImportRequest>[];
    final candidates = only != null ? [only] : _requests.where((r) => r.message == null).toList();
    for (final (index, request) in candidates.indexed) {
      if (_assets.length + prepared.length >= 30) {
        request.message = '一条记录最多 30 项媒体，请移除部分内容后重试。';
        continue;
      }
      setState(() => _progress = '正在导入第 ${index + 1}/${candidates.length} 项媒体');
      try {
        prepared.add(await model.storeMedia(request.file.path, request.file.name, request.provenance));
        done.add(request);
        request.message = null;
      } catch (error) {
        request.message = '${error is ContractError ? error.message : '导入失败。'} 请检查文件后重试。';
      }
    }
    if (prepared.isNotEmpty) {
      if (model.importAssets(prepared)) {
        _requests.removeWhere(done.contains);
      } else {
        for (final request in done) {
          request.message = model.banner ?? '保存导入结果失败，请重试。';
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _importing = false;
      _progress = '';
    });
  }

  Future<void> _close() async {
    FocusScope.of(context).unfocus();
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('保留这份草稿吗？', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          ListTile(title: const Text('保留草稿并关闭', textAlign: TextAlign.center), onTap: () => Navigator.pop(context, 'keep')),
          ListTile(
            title: const Text('放弃草稿', textAlign: TextAlign.center, style: TextStyle(color: JinbaoColors.problem)),
            onTap: () => Navigator.pop(context, 'discard'),
          ),
          ListTile(title: const Text('继续编辑', textAlign: TextAlign.center), onTap: () => Navigator.pop(context)),
        ]),
      ),
    );
    if (!mounted) return;
    if (choice == 'keep') Navigator.pop(context);
    if (choice == 'discard' && AppScope.read(context).discardDraft()) Navigator.pop(context);
  }

  void _save() {
    FocusScope.of(context).unfocus();
    final model = AppScope.read(context);
    if (!model.updateDraft(_title.text, _note.text)) return;
    if (model.commitDraft()) Navigator.pop(context);
  }

  Future<void> _pickDate(int occurredAt) async {
    final current = DateTime.fromMillisecondsSinceEpoch(occurredAt);
    final date = await showDatePicker(
        context: context, initialDate: current, firstDate: DateTime(1970, 1, 2), lastDate: DateTime(2100));
    if (date == null || !mounted) return;
    AppScope.read(context).updateDraftOccurredAt(
        DateTime(date.year, date.month, date.day, current.hour, current.minute).millisecondsSinceEpoch);
  }

  Future<void> _pickTime(int occurredAt) async {
    final current = DateTime.fromMillisecondsSinceEpoch(occurredAt);
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(current));
    if (time == null || !mounted) return;
    AppScope.read(context).updateDraftOccurredAt(
        DateTime(current.year, current.month, current.day, time.hour, time.minute).millisecondsSinceEpoch);
  }

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final draft = model.session.draft;
    final assets = draft?.assets ?? const <LocalAsset>[];
    final occurredAt = draft?.occurredAt ?? AppModel.now;
    final occurred = DateTime.fromMillisecondsSinceEpoch(occurredAt);
    final estimated = assets.any((a) => a.capturedAt == 0 || (a.captureMetadata?.isEstimated ?? false));
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_importing) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(draft?.originalMomentID == null ? '记录小日常' : '编辑记录'),
          leading: TextButton(onPressed: _importing ? null : _close, child: const Text('关闭')),
          leadingWidth: 72,
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: _canSave ? _save : null,
                style: FilledButton.styleFrom(
                  backgroundColor: JinbaoColors.gold,
                  foregroundColor: JinbaoColors.ink,
                  disabledBackgroundColor: JinbaoColors.separator,
                  shape: const StadiumBorder(),
                ),
                child: const Text('保存', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('平凡的日子，也是宝贵的时光。', style: TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(hintText: '给这一天起个名字', border: InputBorder.none, enabledBorder: InputBorder.none),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _note,
            minLines: 4,
            maxLines: 10,
            style: const TextStyle(fontSize: 17),
            decoration:
                const InputDecoration(hintText: '今天有哪些小小的美好？', border: InputBorder.none, enabledBorder: InputBorder.none),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: JinbaoColors.surface, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _dateRow('记录日期', '${occurred.year}年${occurred.month}月${occurred.day}日', () => _pickDate(occurredAt)),
              _dateRow('记录时间', clockText(occurredAt), () => _pickTime(occurredAt)),
              if (estimated)
                const Text('部分媒体未提供完整拍摄时间。当前记录日期可修改；原始时间未知的媒体会保留未知状态。',
                    style: TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary))
              else if (assets.isNotEmpty)
                const Text('首次选图取最早拍摄时间，追加媒体不会覆盖记录日期。',
                    style: TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
            ]),
          ),
          if (assets.isNotEmpty) ...[const SizedBox(height: 16), _mediaStrip(model, assets)],
          if (_importing) ...[
            const SizedBox(height: 16),
            Row(children: [
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: JinbaoColors.ink)),
              const SizedBox(width: 12),
              Expanded(child: Text(_progress)),
            ]),
          ],
          for (final request in _requests.where((r) => r.message != null)) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: JinbaoColors.surface, borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${request.file.name}：${request.message}', style: const TextStyle(color: JinbaoColors.problem)),
                Row(children: [
                  TextButton(onPressed: _importing ? null : () => _importRequests(only: request), child: const Text('重试')),
                  TextButton(
                    onPressed: _importing || assets.length >= 30
                        ? null
                        : () {
                            setState(() => _requests.remove(request));
                            _pickMedia();
                          },
                    child: const Text('重新选择'),
                  ),
                  TextButton(
                    onPressed: _importing ? null : () => setState(() => _requests.remove(request)),
                    style: TextButton.styleFrom(foregroundColor: JinbaoColors.problem),
                    child: const Text('移除'),
                  ),
                ]),
              ]),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: _importing || assets.length >= 30 ? null : _pickMedia,
              style: FilledButton.styleFrom(
                backgroundColor: JinbaoColors.surface,
                foregroundColor: JinbaoColors.ink,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: Text(assets.length >= 30 ? '已选满 30 项媒体' : '选照片或视频 · ${assets.length}/30',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            ),
          ),
          TextButton.icon(
            onPressed: _importing || assets.length >= 30 ? null : _camera,
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text('拍照'),
          ),
          if (model.bannerIsError && model.banner != null)
            Text(model.banner!, style: const TextStyle(color: JinbaoColors.problem)),
          if (!_canSave && !_importing)
            const Text('添加媒体、标题或文字，就可以保存这条记录。', style: TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
        ]),
      ),
    );
  }

  Widget _dateRow(String label, String value, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 16))),
          ActionChip(label: Text(value), onPressed: onTap, backgroundColor: JinbaoColors.background),
        ]),
      );

  Widget _mediaStrip(AppModel model, List<LocalAsset> assets) {
    final photos = [
      for (final asset in assets)
        TimelinePhoto(
          id: asset.id,
          localPath: asset.resources.where((r) => r.role == 'preview').firstOrNull?.relativePath,
          fullSizePath:
              asset.resources.where((r) => r.role == 'photo' || r.role == 'livePhotoImage').firstOrNull?.relativePath,
          kind: asset.kind,
          localResources: asset.resources,
        ),
    ];
    return SizedBox(
      height: 252,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: assets.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final asset = assets[index];
          final preview = photos[index].localPath;
          final path = preview == null ? null : model.filePath(preview);
          return Container(
            width: 160,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: JinbaoColors.surface, borderRadius: BorderRadius.circular(16)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              GestureDetector(
                onTap: () => openGallery(context, photos, index),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(children: [
                    SizedBox(
                      width: 144,
                      height: 156,
                      child: path == null
                          ? Container(color: Colors.grey)
                          : Image.file(File(path), fit: BoxFit.cover, semanticLabel: '预览第${index + 1}张照片'),
                    ),
                    if (asset.kind != 'photo') Positioned(left: 4, bottom: 4, child: MediaKindLabel(kind: asset.kind)),
                  ]),
                ),
              ),
              const SizedBox(height: 6),
              Text(ImportProvenance.known(asset.provenance)?.label ?? '来源未知',
                  style: const TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                IconButton(
                  tooltip: '前移第${index + 1}项媒体',
                  onPressed: _importing || index == 0 ? null : () => model.moveDraftAsset(index, index - 1),
                  icon: const Icon(Icons.arrow_back),
                ),
                IconButton(
                  tooltip: '后移第${index + 1}项媒体',
                  onPressed: _importing || index == assets.length - 1 ? null : () => model.moveDraftAsset(index, index + 1),
                  icon: const Icon(Icons.arrow_forward),
                ),
                IconButton(
                  tooltip: '移除第${index + 1}项媒体',
                  color: JinbaoColors.problem,
                  onPressed: _importing ? null : () => model.removeAsset(asset.id),
                  icon: const Icon(Icons.delete_outline),
                ),
              ]),
            ]),
          );
        },
      ),
    );
  }
}
