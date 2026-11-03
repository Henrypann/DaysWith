import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:jinbao_core/jinbao_core.dart';

import '../family_data_controller.dart';
import '../media_import.dart';

/// Importing preserves local copies only. True means the user explicitly chose
/// to continue to a separate family-target/network/upload confirmation.
Future<bool> showFamilyMediaImport(
  BuildContext context, {
  required FamilyDataController controller,
  Future<List<XFile>> Function()? pickGallery,
  Future<XFile?> Function()? takePhoto,
  Future<XFile?> Function()? takeVideo,
  Future<LocalAsset> Function(XFile file, ImportProvenance provenance)? importAsset,
}) async =>
    await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => FamilyMediaImportScreen(
      controller: controller,
      pickGallery: pickGallery,
      takePhoto: takePhoto,
      takeVideo: takeVideo,
      importAsset: importAsset,
    ))) ??
    false;

class FamilyMediaImportScreen extends StatefulWidget {
  final FamilyDataController controller;
  final Future<List<XFile>> Function()? pickGallery;
  final Future<XFile?> Function()? takePhoto;
  final Future<XFile?> Function()? takeVideo;
  final Future<LocalAsset> Function(XFile file, ImportProvenance provenance)? importAsset;

  const FamilyMediaImportScreen({super.key, required this.controller,
    this.pickGallery, this.takePhoto, this.takeVideo, this.importAsset});

  @override
  State<FamilyMediaImportScreen> createState() => _FamilyMediaImportScreenState();
}

class _FamilyMediaImportScreenState extends State<FamilyMediaImportScreen> {
  final _picker = ImagePicker();
  bool _busy = false;
  bool _stopRequested = false;
  String? _message;
  String? _error;
  int _generation = 0;

  int get _count => widget.controller.retainedMediaCount;
  bool get _otherDraft => widget.controller.hasPendingUpload && !widget.controller.hasRetainedMediaDraft;
  bool get _mayAdd => !_busy && !_otherDraft && widget.controller.canContribute && _count < 30;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
  }

  void _controllerChanged() {
    if (!widget.controller.canContribute && _busy) _stopRequested = true;
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant FamilyMediaImportScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _stopRequested = true;
      _generation++;
      _busy = false;
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
    }
  }

  Future<List<XFile>> _gallery(int remaining) async {
    if (widget.pickGallery != null) return widget.pickGallery!();
    if (remaining == 1) {
      final file = await _picker.pickMedia();
      return file == null ? const [] : [file];
    }
    return _picker.pickMultipleMedia(limit: remaining, requestFullMetadata: true);
  }

  Future<void> _pick(String source) async {
    if (!_mayAdd) return;
    final controller = widget.controller;
    final importer = widget.importAsset ?? (XFile file, ImportProvenance provenance) => MediaImport.store(
      source: file.path, filename: file.name, provenance: provenance, directory: controller.localDirectory);
    final generation = ++_generation;
    final remaining = 30 - controller.retainedMediaCount;
    setState(() { _busy = true; _stopRequested = false; _message = null; _error = null; });
    try {
      controller.beginMediaImport();
      final List<XFile> files;
      final ImportProvenance provenance;
      switch (source) {
        case 'gallery':
          files = await _gallery(remaining);
          provenance = ImportProvenance.systemProvided;
        case 'photo':
          final file = await (widget.takePhoto?.call() ??
              _picker.pickImage(source: ImageSource.camera, requestFullMetadata: true));
          files = file == null ? const [] : [file];
          provenance = ImportProvenance.camera;
        case 'video':
          final file = await (widget.takeVideo?.call() ?? _picker.pickVideo(source: ImageSource.camera));
          files = file == null ? const [] : [file];
          provenance = ImportProvenance.camera;
        default:
          return;
      }
      if (!mounted || generation != _generation || _stopRequested) return;
      if (files.length > remaining) {
        setState(() => _error = '一条家庭记录最多 30 项媒体，请减少选择后重试。');
        return;
      }
      for (var index = 0; index < files.length; index++) {
        if (!mounted || generation != _generation || _stopRequested || !controller.canContribute) break;
        setState(() => _message = '正在保留第 ${index + 1}/${files.length} 项媒体');
        final asset = await importer(files[index], provenance);
        // Retain immediately, even when the route closed during the copy. Never
        // start the next asynchronous import before this metadata is journaled.
        controller.retainImportedAsset(asset);
        if (!mounted || generation != _generation || _stopRequested || !controller.canContribute) break;
        setState(() => _message = '已在本机保留 ${controller.retainedMediaCount} 项媒体');
      }
      if (mounted && generation == _generation) {
        setState(() => _message = _stopRequested
            ? '已停止继续导入，完成的副本与草稿仍保留在本机。'
            : files.isEmpty
                ? '未新增媒体，已有草稿保持原样。'
                : '导入完成，尚未上传到家庭。');
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = controller.errorMessage ??
            '这项媒体未完成保留。已完成的副本和草稿继续保留，请检查文件或本机空间后重试；不会自动上传。');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  void _close() {
    if (_busy) {
      setState(() { _stopRequested = true; _message = '当前副本完成并保存后停止，不会继续处理后面的媒体。'; });
      return;
    }
    Navigator.of(context).pop(false);
  }

  @override
  void dispose() {
    _stopRequested = true;
    _generation++;
    widget.controller.removeListener(_controllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    onPopInvokedWithResult: (didPop, _) { if (!didPop) _close(); },
    child: Scaffold(
      appBar: AppBar(title: const Text('添加家庭照片或视频'),
        leading: TextButton(onPressed: _close, child: Text(_busy ? '停止' : '关闭')),
        leadingWidth: 72),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('先保留在本机', style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        const Text('每完成一项媒体，就保存原件副本与草稿。这里不会上传；继续后仍需确认目标家庭、数量、大小和网络规则。', style: TextStyle(fontSize: 17)),
        const SizedBox(height: 20),
        Text('已保留 $_count / 30 项媒体', style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600)),
        if (_otherDraft) const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('已有其他未完成的家庭草稿，请返回查看或取消后再添加媒体。')),
        if (!widget.controller.canContribute) const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('当前家庭登录或投稿权限不可用。已完成的本机副本保留，重新登录后可继续。')),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: _mayAdd ? () => _pick('gallery') : null,
          icon: const Icon(Icons.photo_library_outlined), label: const Text('从相册选择照片或视频')),
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: _mayAdd ? () => _pick('photo') : null,
          icon: const Icon(Icons.camera_alt_outlined), label: const Text('拍一张照片')),
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: _mayAdd ? () => _pick('video') : null,
          icon: const Icon(Icons.videocam_outlined), label: const Text('拍摄视频')),
        if (_busy) ...[
          const SizedBox(height: 20), const LinearProgressIndicator(),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _close, child: const Text('停止后续导入')),
        ],
        if (_message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(_message!, style: const TextStyle(fontSize: 17))),
        if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(_error!, style: TextStyle(fontSize: 17, color: Theme.of(context).colorScheme.error))),
        const SizedBox(height: 24),
        FilledButton(onPressed: !_busy && _count > 0 && widget.controller.canContribute && !_otherDraft
            ? () => Navigator.of(context).pop(true) : null, child: const Text('保留并继续确认')),
        const SizedBox(height: 12),
        TextButton(onPressed: _close, child: Text(_busy ? '停止并保留已完成副本' : '保留草稿并关闭')),
      ]),
    ),
  );
}
