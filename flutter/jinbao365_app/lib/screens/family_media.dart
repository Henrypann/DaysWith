import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:jinbao_core/jinbao_core.dart';
import 'package:video_player/video_player.dart';

import '../family_data_controller.dart';

/// Displays bytes only after a live family authorization and complete hash check.
/// The injected loaders are for synthetic widget tests and do not grant access.
class FamilyAssetPreview extends StatefulWidget {
  final FamilyDataController controller;
  final FamilyArchiveRecord record;
  final FamilyArchiveAsset asset;
  final Future<String> Function()? previewLoader;
  final Future<String> Function(bool allowCellular)? originalLoader;
  final Widget Function(BuildContext context, String path)? videoBuilder;
  const FamilyAssetPreview({super.key, required this.controller, required this.record,
    required this.asset, this.previewLoader, this.originalLoader, this.videoBuilder});
  @override
  State<FamilyAssetPreview> createState() => _FamilyAssetPreviewState();
}

class _FamilyAssetPreviewState extends State<FamilyAssetPreview> {
  String? _path, _error;
  bool _loading = false;
  int _generation = 0;
  late int _epoch;
  @override
  void initState() {
    super.initState();
    _epoch = widget.controller.authorizationEpoch;
    widget.controller.addListener(_authorizationChanged);
    _load();
  }
  @override
  void didUpdateWidget(covariant FamilyAssetPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_authorizationChanged);
      widget.controller.addListener(_authorizationChanged);
    }
    if (oldWidget.controller != widget.controller || oldWidget.record.revision != widget.record.revision ||
        oldWidget.record.id != widget.record.id || oldWidget.record.ownerMemberID != widget.record.ownerMemberID ||
        oldWidget.asset.id != widget.asset.id) _load();
  }
  void _authorizationChanged() {
    if (_epoch == widget.controller.authorizationEpoch || !mounted) return;
    _generation++;
    _epoch = widget.controller.authorizationEpoch;
    setState(() { _path = null; _loading = false; _error = '家庭登录状态已变化，请刷新后重试。'; });
  }
  Future<void> _load() async {
    final generation = ++_generation;
    _epoch = widget.controller.authorizationEpoch;
    setState(() { _loading = true; _path = null; _error = null; });
    try {
      final path = await (widget.previewLoader?.call() ?? widget.controller.loadPreview(widget.record, widget.asset));
      if (!mounted || generation != _generation || _epoch != widget.controller.authorizationEpoch) return;
      if (widget.controller.familySnapshot == null || widget.controller.showingCachedMetadata) {
        throw const FamilyDataException('unauthenticated');
      }
      setState(() => _path = path);
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _error = '缩略图暂不可用，可刷新后重试。');
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }
  void _openOriginal() {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FamilyMediaViewer(
      controller: widget.controller, record: widget.record, asset: widget.asset,
      originalLoader: widget.originalLoader, videoBuilder: widget.videoBuilder,
    )));
  }
  @override
  void dispose() { _generation++; widget.controller.removeListener(_authorizationChanged); super.dispose(); }
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_path != null)
        Semantics(label: widget.asset.kind == 'video' ? '查看视频原件' : '查看照片原件', button: true,
          child: InkWell(onTap: _openOriginal, child: Stack(alignment: Alignment.center, children: [
            ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(File(_path!),
              width: double.infinity, height: 210, fit: BoxFit.cover, cacheWidth: 700,
              errorBuilder: (_, _, _) => const SizedBox(height: 160, child: Center(child: Text('缩略图无法显示，请查看原件或重试。'))))),
            if (widget.asset.kind == 'video') const Icon(Icons.play_circle_fill, size: 58, color: Colors.white),
          ]))),
      if (_loading) const SizedBox(height: 100, child: Center(child: CircularProgressIndicator())),
      if (_error != null) ...[
        Text(_error!),
        OutlinedButton.icon(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh), label: const Text('重试缩略图')),
      ],
      TextButton.icon(onPressed: _loading || widget.controller.familySnapshot == null ? null : _openOriginal,
        icon: Icon(widget.asset.kind == 'video' ? Icons.movie_outlined : Icons.open_in_full),
        label: Text(widget.asset.kind == 'video' ? '查看完整视频' : '查看照片原件')),
    ]),
  );
}

class FamilyMediaViewer extends StatefulWidget {
  final FamilyDataController controller;
  final FamilyArchiveRecord record;
  final FamilyArchiveAsset asset;
  final Future<String> Function(bool allowCellular)? originalLoader;
  final Widget Function(BuildContext context, String path)? videoBuilder;
  const FamilyMediaViewer({super.key, required this.controller, required this.record,
    required this.asset, this.originalLoader, this.videoBuilder});
  @override
  State<FamilyMediaViewer> createState() => _FamilyMediaViewerState();
}

class _FamilyMediaViewerState extends State<FamilyMediaViewer> with WidgetsBindingObserver {
  String? _path, _error;
  VideoPlayerController? _video;
  bool _loading = false, _cellular = false;
  int _generation = 0;
  late int _epoch;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _epoch = widget.controller.authorizationEpoch;
    widget.controller.addListener(_authorizationChanged);
    _load();
  }
  @override
  void didUpdateWidget(covariant FamilyMediaViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_authorizationChanged);
      widget.controller.addListener(_authorizationChanged);
    }
    if (oldWidget.controller != widget.controller || oldWidget.record.id != widget.record.id ||
        oldWidget.record.ownerMemberID != widget.record.ownerMemberID ||
        oldWidget.record.revision != widget.record.revision || oldWidget.asset.id != widget.asset.id) {
      _load();
    }
  }
  void _authorizationChanged() {
    if (_epoch == widget.controller.authorizationEpoch || !mounted) return;
    _generation++;
    _epoch = widget.controller.authorizationEpoch;
    final video = _video;
    _video = null;
    unawaited(_closeVideo(video));
    setState(() { _path = null; _loading = false; _cellular = false; _error = '家庭登录状态已变化，已停止显示原件。请返回刷新。'; });
  }
  Future<void> _load({bool allowCellular = false}) async {
    final generation = ++_generation;
    _epoch = widget.controller.authorizationEpoch;
    final oldVideo = _video;
    _video = null;
    setState(() { _path = null; _error = null; _cellular = false; _loading = true; });
    await _closeVideo(oldVideo);
    VideoPlayerController? created;
    try {
      final path = await (widget.originalLoader?.call(allowCellular) ??
          widget.controller.loadOriginal(widget.record, widget.asset, allowCellular: allowCellular));
      if (!mounted || generation != _generation || _epoch != widget.controller.authorizationEpoch) return;
      if (widget.controller.familySnapshot == null || widget.controller.showingCachedMetadata) {
        throw const FamilyDataException('unauthenticated');
      }
      if (widget.asset.kind == 'video' && widget.videoBuilder == null) {
        created = VideoPlayerController.file(File(path));
        await created.initialize();
        if (!mounted || generation != _generation || _epoch != widget.controller.authorizationEpoch) {
          await _closeVideo(created);
          return;
        }
      }
      setState(() { _path = path; _video = created; });
    } on FamilyCellularDownloadRequired {
      if (mounted && generation == _generation) setState(() => _cellular = true);
    } catch (_) {
      await _closeVideo(created);
      if (mounted && generation == _generation) setState(() => _error = '原件未能完成读取或播放，请检查网络后重试。');
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }
  Future<void> _allowCellular() async {
    final epoch = _epoch;
    final generation = _generation;
    final bytes = widget.asset.resources.where((resource) => resource.role != 'preview')
        .fold<int>(0, (count, resource) => count + resource.byteCount);
    final allow = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('这次使用移动网络读取原件？'),
      content: Text('将读取约 ${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB 的完整原件，可能产生流量费用。只允许这一次，不更改默认设置。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('允许这一次')),
      ],
    ));
    if (allow == true && mounted && generation == _generation && epoch == widget.controller.authorizationEpoch) await _load(allowCellular: true);
  }
  Future<void> _toggleVideo() async {
    final video = _video;
    final generation = _generation;
    if (video == null) return;
    try {
      if (video.value.isPlaying) { await video.pause(); } else { await video.play(); }
      if (mounted && generation == _generation && identical(video, _video)) setState(() {});
    } catch (_) {
      await _closeVideo(video);
      if (mounted && generation == _generation && identical(video, _video)) {
        setState(() { _video = null; _path = null; _error = '当前设备未能播放视频，请稍后重试。'; });
      }
    }
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_pauseVideo(_video));
  }
  @override
  void dispose() {
    _generation++;
    widget.controller.removeListener(_authorizationChanged);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_closeVideo(_video));
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(switch (widget.asset.kind) {
      'video' => '完整视频', 'livePhoto' => 'Live Photo 静态原图',
      'motionPhoto' => '动态照片原件 · 静态查看', _ => '照片原件',
    })),
    body: Center(child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      if (_loading) const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
      if (_cellular) Padding(padding: const EdgeInsets.all(20), child: Column(children: [
        const Text('当前网络需要单独确认后才能读取完整原件。', style: TextStyle(fontSize: 18)),
        const SizedBox(height: 16),
        FilledButton(onPressed: _allowCellular, child: const Text('选择这次的网络许可')),
      ])),
      if (_error != null) Padding(padding: const EdgeInsets.all(20), child: Column(children: [
        Text(_error!, style: const TextStyle(fontSize: 18)),
        const SizedBox(height: 16),
        OutlinedButton(onPressed: _loading ? null : _load, child: const Text('重试读取原件')),
      ])),
      if (_path != null && widget.asset.kind != 'video') InteractiveViewer(
        child: Image.file(File(_path!), fit: BoxFit.contain, cacheWidth: 2048,
          errorBuilder: (_, _, _) => const Padding(padding: EdgeInsets.all(24), child: Text('原件校验已完成，但当前设备无法显示此图片格式。'))),
      ),
      if (_path != null && widget.asset.kind == 'livePhoto')
        const Padding(padding: EdgeInsets.all(16), child: Text('此处显示静态原图；配对视频保留在完整恢复副本中。')),
      if (_path != null && widget.asset.kind == 'video')
        if (widget.videoBuilder != null) widget.videoBuilder!(context, _path!)
        else if (_video != null) ...[
          AspectRatio(aspectRatio: _video!.value.aspectRatio > 0 ? _video!.value.aspectRatio : 16 / 9,
            child: VideoPlayer(_video!)),
          FilledButton.icon(onPressed: _toggleVideo, icon: Icon(_video!.value.isPlaying ? Icons.pause : Icons.play_arrow),
            label: Text(_video!.value.isPlaying ? '暂停播放' : '播放视频')),
        ],
    ]))),
  );
}

Future<void> _pauseVideo(VideoPlayerController? video) async {
  try { await video?.pause(); } catch (_) { /* A failed platform handle cannot authorize access. */ }
}
Future<void> _closeVideo(VideoPlayerController? video) async {
  await _pauseVideo(video);
  try { await video?.dispose(); } catch (_) { /* Dispose even when platform initialization failed. */ }
}
