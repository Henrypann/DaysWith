import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:jinbao_core/jinbao_core.dart';

import '../app_model.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/waterfall.dart';
import 'anniversaries.dart';
import 'media_viewer.dart';
import 'shell.dart';

/// Port of TimelineView.swift: one sticky section per month (always with its year), a two-column
/// waterfall, search over titles and notes, and a trailing non-sticky "日期未知" section.
class TimelineScreen extends StatefulWidget {
  const TimelineScreen({super.key});

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  bool _searchVisible = false;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _clock = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _clock?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  String get _query => swiftTrim(_search.text).toLowerCase();

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final query = _query;
    final entries = model.session.timelineEntries().where((e) =>
        query.isEmpty || e.title.toLowerCase().contains(query) || e.note.toLowerCase().contains(query)).toList();
    final months = JinbaoCalendar.months(entries.where((e) => e.occurredAt > 0).toList(), const DeviceZone());
    final unknown = entries.where((e) => e.occurredAt <= 0).toList();
    final draft = model.session.draft;
    return LayoutBuilder(builder: (context, constraints) {
      final columns = constraints.maxWidth < 360 || MediaQuery.textScalerOf(context).scale(1) >= 1.6 ? 1 : 2;
      return CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverToBoxAdapter(child: _header()),
          if (_searchVisible) SliverToBoxAdapter(child: _searchField()),
          if (!_searchVisible) const SliverToBoxAdapter(child: AnniversaryReminder()),
          if (draft != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Material(
                  color: JinbaoColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => openComposer(context),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(children: [
                        const Icon(Icons.edit_note, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(draft.title.isEmpty ? '继续未完成的记录' : '未完成：${draft.title}',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                        const Icon(Icons.chevron_right, size: 16),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          if (entries.isEmpty)
            SliverToBoxAdapter(child: _emptyState(query.isEmpty))
          else ...[
            for (final month in months)
              SliverMainAxisGroup(slivers: [
                PinnedHeaderSliver(child: _sectionHeader(month.title, month.days.fold(0, (n, d) => n + d.moments.length))),
                SliverToBoxAdapter(child: _grid(columns, [for (final day in month.days) ...day.moments])),
              ]),
            // Follows every dated month. Same waterfall and count, but the header is not pinned.
            if (unknown.isNotEmpty)
              SliverMainAxisGroup(slivers: [
                SliverToBoxAdapter(child: _sectionHeader('日期未知', unknown.length)),
                SliverToBoxAdapter(child: _grid(columns, unknown)),
              ]),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
      );
    });
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Row(children: [
                BrandMark(),
                SizedBox(width: 8),
                Text('DaysWith', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 8),
              Text(ageLabel(DateTime.now()), style: const TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
            ]),
          ),
          IconButton(
            tooltip: _searchVisible ? '收起搜索' : '搜索记录',
            iconSize: 24,
            color: JinbaoColors.inkSecondary,
            onPressed: () {
              setState(() {
                _searchVisible = !_searchVisible;
                if (!_searchVisible) _search.clear();
              });
              if (_searchVisible) _searchFocus.requestFocus();
            },
            icon: Icon(_searchVisible ? Icons.close : Icons.search),
          ),
        ]),
      );

  Widget _searchField() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: TextField(
          controller: _search,
          focusNode: _searchFocus,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: '搜索标题和文字',
            prefixIcon: const Icon(Icons.search, color: JinbaoColors.inkSecondary),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清除搜索',
                    icon: const Icon(Icons.cancel, color: JinbaoColors.inkSecondary),
                    onPressed: () {
                      _search.clear();
                      _searchFocus.requestFocus();
                    },
                  ),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: JinbaoColors.outline)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: JinbaoColors.outline)),
          ),
        ),
      );

  Widget _emptyState(bool noQuery) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 64, 24, 0),
        child: Column(children: [
          const BrandMark(size: 88),
          const SizedBox(height: 24),
          Text(noQuery ? TimelineEmptyCopy.title : '没有找到相关记录',
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Text(noQuery ? TimelineEmptyCopy.detail : '换个词再找找吧',
              textAlign: TextAlign.center, style: const TextStyle(color: JinbaoColors.inkSecondary)),
          if (noQuery) ...[
            const SizedBox(height: 24),
            GoldButton(title: '记录一个小日常', onPressed: () => openComposer(context)),
          ],
        ]),
      );

  Widget _sectionHeader(String title, int count) => Container(
        color: JinbaoColors.background,
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.centerLeft,
        child: Row(children: [
          Expanded(child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
          Text('$count条', style: const TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
        ]),
      );

  Widget _grid(int columns, List<TimelineEntry> entries) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Waterfall(columns: columns, children: [
          for (final entry in entries)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => openMomentDetail(context, entry.id),
              child: MomentCard(entry: entry),
            ),
        ]),
      );
}

String cardDate(TimelineEntry entry) {
  if (entry.occurredAt <= 0) return '日期未知';
  final parts = JinbaoCalendar.parts(entry.occurredAt, const DeviceZone());
  return '${parts.month}月${parts.day}日 · ${clockText(entry.occurredAt)}';
}

class MomentCard extends StatelessWidget {
  final TimelineEntry entry;
  const MomentCard({super.key, required this.entry});

  bool get _hasMedia => entry.mediaCount > 0 || entry.photos.isNotEmpty || entry.previewPath != null;

  @override
  Widget build(BuildContext context) {
    final hasMedia = _hasMedia;
    final details = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(cardDate(entry), style: const TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
      const SizedBox(height: 8),
      Text(entry.displayTitle,
          maxLines: hasMedia ? 2 : 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 15, fontWeight: hasMedia ? FontWeight.w500 : FontWeight.w600)),
      if (!hasMedia && entry.note.isNotEmpty && entry.note != entry.displayTitle) ...[
        const SizedBox(height: 8),
        Text(entry.note,
            maxLines: 6, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, color: JinbaoColors.noteInk)),
      ],
      const SizedBox(height: 8),
      ParentBadge(entry.parent),
      if (entry.readOnly || entry.provenanceLabel != null) ...[
        const SizedBox(height: 8),
        Text([if (entry.readOnly) '只读', ?entry.provenanceLabel].join(' · '),
            style: const TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
      ],
    ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (hasMedia) ...[_media(context), const SizedBox(height: 8)],
      hasMedia
          ? details
          : Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: JinbaoColors.surface, borderRadius: BorderRadius.circular(16)),
              child: details,
            ),
    ]);
  }

  Widget _media(BuildContext context) {
    final count = entry.mediaCount > entry.photos.length ? entry.mediaCount : entry.photos.length;
    final photo = entry.photos.firstOrNull;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(children: [
        Container(
          color: JinbaoColors.photoPlaceholder,
          width: double.infinity,
          child: photo != null
              ? PhotoThumbnail(photo: photo, allowsRetry: false)
              : AspectRatio(
                  aspectRatio: 1,
                  child: Center(
                    child: Text(entry.readOnly ? '照片在云端' : '照片已在这台手机',
                        style: const TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
                  ),
                ),
        ),
        if (count > 1)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(999)),
              child: Text('$count张', style: const TextStyle(fontSize: 11, color: Colors.white)),
            ),
          ),
        if (photo != null && photo.kind != 'photo')
          Positioned(left: 8, bottom: 8, child: MediaKindLabel(kind: photo.kind)),
      ]),
    );
  }
}

class MediaKindLabel extends StatelessWidget {
  final String kind;
  const MediaKindLabel({super.key, required this.kind});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(kind == 'video' ? Icons.play_arrow : Icons.motion_photos_on, size: 14, color: Colors.white),
          const SizedBox(width: 2),
          Text(
            switch (kind) { 'video' => '视频', 'motionPhoto' => '动态照片', _ => '实况' },
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
          ),
        ]),
      );
}

/// Local preview, or a verified, cached family preview loaded on demand.
class PhotoThumbnail extends StatelessWidget {
  final TimelinePhoto photo;
  final bool allowsRetry;
  final BoxFit fit;
  const PhotoThumbnail({super.key, required this.photo, this.allowsRetry = true, this.fit = BoxFit.fitWidth});

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final relative = model.previewPath(photo);
    final path = relative == null ? null : model.filePath(relative);
    if (path != null && File(path).existsSync()) {
      return Image.file(File(path), fit: fit, width: double.infinity, semanticLabel: '照片',
          errorBuilder: (_, _, _) => const _Placeholder(text: '这张照片暂时无法读取'));
    }
    final reference = photo.remote;
    if (reference == null) return const _Placeholder(text: '这张照片暂时无法读取');
    final load = model.previewLoads[reference.id];
    if (load == null) WidgetsBinding.instance.addPostFrameCallback((_) => model.loadPreview(reference));
    if (load is PreviewFailed) {
      return SizedBox(
        height: 120,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(load.message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
            if (allowsRetry)
              TextButton(onPressed: () => model.loadPreview(reference, retry: true), child: const Text('重试读取照片'))
            else
              const Text('打开记录后可重试', style: TextStyle(fontSize: 12)),
          ]),
        ),
      );
    }
    return const SizedBox(
      height: 120,
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: JinbaoColors.ink)),
          SizedBox(height: 8),
          Text('正在读取照片', style: TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
        ]),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  final String text;
  const _Placeholder({required this.text});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 100,
        child: Center(child: Text(text, style: const TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary))),
      );
}

void openMomentDetail(BuildContext context, String id) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MomentDetailPage(id: id)));
}

/// Port of MomentDetail: media, title, date, note, read-only notice, edit and trash.
class MomentDetailPage extends StatelessWidget {
  final String id;
  const MomentDetailPage({super.key, required this.id});

  String _detailDate(TimelineEntry entry) {
    if (entry.occurredAt <= 0) return '日期与时间未知';
    final parts = JinbaoCalendar.parts(entry.occurredAt, const DeviceZone());
    return '${parts.year}年${JinbaoCalendar.dayTitle(parts)} · ${clockText(entry.occurredAt)}';
  }

  String _viewLabel(TimelinePhoto photo, int index) => switch (photo.kind) {
        'video' => '播放视频',
        'livePhoto' || 'motionPhoto' => '查看动态照片',
        _ => '查看第${index + 1}张大图',
      };

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final entry = model.session.timelineEntries().where((e) => e.id == id).firstOrNull;
    if (entry == null) {
      return Scaffold(appBar: AppBar(title: const Text('小日常')), body: const Center(child: Text('这条记录已经不在时光里。')));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('小日常'),
        leading: TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        leadingWidth: 72,
        actions: [
          if (!entry.readOnly)
            PopupMenuButton<String>(
              tooltip: '记录操作',
              icon: const Icon(Icons.more_horiz),
              onSelected: (value) async {
                if (value == 'edit') {
                  if (model.beginEditing(entry.id)) {
                    Navigator.pop(context);
                    openComposer(context);
                  }
                } else if (value == 'trash') {
                  final confirmed = await confirmAction(context,
                      title: '移到回收站？',
                      message: '可以在我的－设置－回收站恢复，云端原件不会被删除。',
                      confirm: '移到回收站',
                      destructive: true);
                  if (confirmed && context.mounted) {
                    model.trashMoment(entry.id);
                    Navigator.pop(context);
                  }
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit), title: Text('编辑记录'))),
                PopupMenuItem(
                    value: 'trash',
                    child: ListTile(
                        leading: Icon(Icons.delete_outline, color: JinbaoColors.problem),
                        title: Text('移到回收站', style: TextStyle(color: JinbaoColors.problem)))),
              ],
            ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        for (final (index, photo) in entry.photos.indexed) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              color: JinbaoColors.photoPlaceholder,
              constraints: const BoxConstraints(minHeight: 180, maxHeight: 360),
              child: Stack(alignment: Alignment.center, children: [
                PhotoThumbnail(photo: photo, fit: BoxFit.contain),
                if (photo.kind != 'photo') Positioned(left: 8, bottom: 8, child: MediaKindLabel(kind: photo.kind)),
              ]),
            ),
          ),
          TextButton(
            onPressed: () => openGallery(context, entry.photos, index),
            child: Text(_viewLabel(photo, index), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          ),
          const SizedBox(height: 8),
        ],
        ParentBadge(entry.parent),
        const SizedBox(height: 8),
        Text(entry.displayTitle, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(_detailDate(entry), style: const TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
        if (entry.mediaCount > 0) ...[
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.photo_library_outlined, size: 14, color: JinbaoColors.inkSecondary),
            const SizedBox(width: 4),
            Text('${entry.mediaCount}个媒体文件', style: const TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
          ]),
        ],
        if (swiftTrim(entry.note).isNotEmpty && entry.note != entry.displayTitle) ...[
          const SizedBox(height: 16),
          BrandCard(padding: 24, child: Text(entry.note, style: const TextStyle(fontSize: 16))),
        ],
        if (entry.mediaCount > entry.photos.length) ...[
          const SizedBox(height: 16),
          const Text('部分云端媒体没有可用预览，请重新连接后重试。', style: TextStyle(color: JinbaoColors.inkSecondary)),
        ],
        if (entry.readOnly) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: JinbaoColors.goldSoft, borderRadius: BorderRadius.circular(12)),
            child: const Text('这是另一台设备或另一位家长留下的，这里只读。', style: TextStyle(color: JinbaoColors.inkSecondary)),
          ),
        ],
      ]),
    );
  }
}
