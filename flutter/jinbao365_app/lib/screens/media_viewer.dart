import 'dart:io';

import 'package:flutter/material.dart';
import 'package:jinbao_core/jinbao_core.dart';
import 'package:video_player/video_player.dart';

import '../app_model.dart';
import '../main.dart';

void openGallery(BuildContext context, List<TimelinePhoto> photos, int initialIndex) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => PhotoGallery(photos: photos, initialIndex: initialIndex),
  ));
}

/// Full-screen swipe gallery (PhotoGallery in TimelineView.swift).
class PhotoGallery extends StatefulWidget {
  final List<TimelinePhoto> photos;
  final int initialIndex;
  const PhotoGallery({super.key, required this.photos, required this.initialIndex});

  @override
  State<PhotoGallery> createState() => _PhotoGalleryState();
}

class _PhotoGalleryState extends State<PhotoGallery> {
  late final PageController _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
        data: ThemeData.dark(useMaterial3: true),
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text('${_index + 1} / ${widget.photos.length}'),
            leading: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭', style: TextStyle(color: Colors.white)),
            ),
            leadingWidth: 72,
          ),
          body: PageView.builder(
            controller: _pages,
            itemCount: widget.photos.length,
            onPageChanged: (index) => setState(() => _index = index),
            itemBuilder: (_, index) => MediaPlayback(photo: widget.photos[index]),
          ),
        ),
      );
}

/// Port of MediaPlaybackView.swift: full photo with zoom, real video playback, Live Photo
/// still with its paired video, and an explicitly labelled static view for Motion Photos.
class MediaPlayback extends StatefulWidget {
  final TimelinePhoto photo;
  const MediaPlayback({super.key, required this.photo});

  @override
  State<MediaPlayback> createState() => _MediaPlaybackState();
}

class _MediaPlaybackState extends State<MediaPlayback> {
  Map<String, String>? _paths;
  String? _error;
  bool _needsCellular = false;
  bool _loading = true;
  bool _playPaired = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool allowCellularOnce = false}) async {
    setState(() {
      _loading = true;
      _error = null;
      _needsCellular = false;
    });
    try {
      final paths = await AppScope.read(context).mediaResourcePaths(widget.photo, allowCellularOnce: allowCellularOnce);
      if (!mounted) return;
      setState(() {
        _paths = paths;
        _loading = false;
      });
    } on CellularDownloadRequired {
      if (!mounted) return;
      setState(() {
        _needsCellular = true;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '原件暂时无法读取，请重试。';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: Colors.white));
    if (_needsCellular) {
      return _message('正在使用蜂窝网络。下载原件可能消耗流量。', action: '这次使用蜂窝网络下载', onAction: () => _load(allowCellularOnce: true));
    }
    if (_error != null) return _message(_error!, action: '重试', onAction: _load);
    final paths = _paths ?? const {};
    switch (widget.photo.kind) {
      case 'video':
        final video = paths['video'];
        return video == null ? _message('视频原件不可用。') : VideoPane(path: video);
      case 'livePhoto':
        final still = paths['livePhotoImage'];
        final paired = paths['livePhotoVideo'];
        if (still == null || paired == null) return _message('实况照片缺少配对资源，无法动态播放。');
        if (_playPaired) return VideoPane(path: paired, autoplay: true, onFinished: () => setState(() => _playPaired = false));
        return Stack(children: [
          _zoomable(still),
          Positioned(
            left: 16,
            bottom: 24,
            child: FilledButton.icon(
              onPressed: () => setState(() => _playPaired = true),
              icon: const Icon(Icons.motion_photos_on),
              label: const Text('播放实况'),
            ),
          ),
        ]);
      case 'motionPhoto':
        final still = paths['motionPhoto'];
        if (still == null) return _message('动态照片原件不可用。');
        return Stack(children: [
          _zoomable(still),
          const Positioned(left: 16, bottom: 24, child: Chip(label: Text('Android 动态照片 · 静态兼容查看'))),
        ]);
      default:
        final photo = paths['photo'];
        return photo == null ? _message('照片原件不可用。') : _zoomable(photo);
    }
  }

  Widget _zoomable(String path) => InteractiveViewer(
        minScale: 1,
        maxScale: 5,
        child: Center(child: Image.file(File(path), fit: BoxFit.contain, semanticLabel: '照片')),
      );

  Widget _message(String text, {String? action, VoidCallback? onAction}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
            if (action != null) TextButton(onPressed: onAction, child: Text(action)),
          ]),
        ),
      );
}

class VideoPane extends StatefulWidget {
  final String path;
  final bool autoplay;
  final VoidCallback? onFinished;
  const VideoPane({super.key, required this.path, this.autoplay = false, this.onFinished});

  @override
  State<VideoPane> createState() => _VideoPaneState();
}

class _VideoPaneState extends State<VideoPane> {
  late final VideoPlayerController _controller = VideoPlayerController.file(File(widget.path));
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTick);
    _controller.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
      if (widget.autoplay) _controller.play();
    }).catchError((Object _) {
      if (mounted) setState(() => _error = '这个视频无法播放。');
    });
  }

  void _onTick() {
    final value = _controller.value;
    if (widget.onFinished != null && value.isInitialized && !value.isPlaying && value.position >= value.duration) {
      widget.onFinished!();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    _controller.dispose();
    super.dispose();
  }

  String _time(Duration value) =>
      '${value.inMinutes.toString().padLeft(2, '0')}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: Colors.white)));
    final value = _controller.value;
    if (!value.isInitialized) return const Center(child: CircularProgressIndicator(color: Colors.white));
    final total = value.duration.inMilliseconds.toDouble();
    return Column(children: [
      Expanded(child: Center(child: AspectRatio(aspectRatio: value.aspectRatio, child: VideoPlayer(_controller)))),
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 16, 24),
        child: Row(children: [
          IconButton(
            tooltip: value.isPlaying ? '暂停' : '播放',
            color: Colors.white,
            iconSize: 32,
            onPressed: () => value.isPlaying ? _controller.pause() : _controller.play(),
            icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
          ),
          Expanded(
            child: Slider(
              value: value.position.inMilliseconds.clamp(0, total).toDouble(),
              max: total <= 0 ? 1 : total,
              onChanged: (ms) => _controller.seekTo(Duration(milliseconds: ms.round())),
            ),
          ),
          Text('${_time(value.position)} / ${_time(value.duration)}', style: const TextStyle(color: Colors.white)),
        ]),
      ),
    ]);
  }
}
