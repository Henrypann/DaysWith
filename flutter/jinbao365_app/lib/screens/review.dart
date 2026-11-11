import 'package:flutter/material.dart';
import 'package:jinbao_core/jinbao_core.dart';

import '../app_model.dart';
import '../main.dart';
import '../theme.dart';
import 'shell.dart';
import 'timeline.dart';

/// Port of ReviewView.swift: one card per month with record, photo and video counts.
class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final entries = model.session.timelineEntries();
    final months = JinbaoCalendar.months(entries.where((e) => e.occurredAt > 0).toList(), const DeviceZone());
    final unknown = entries.where((e) => e.occurredAt <= 0).length;
    return Scaffold(
      appBar: AppBar(title: const Text('回顾')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (months.isEmpty) ...[
          const FeatureEmptyState(title: '成长值得慢慢回看', detail: '留下第一条记录，就会有属于这个月的回顾。', icon: Icons.calendar_today_outlined),
          GoldButton(title: '记录一个小日常', onPressed: () => openComposer(context)),
        ],
        if (months.isNotEmpty) ...[_summary(model, entries), const SizedBox(height: 14)],
        if (unknown > 0) ...[
          Material(
            color: JinbaoColors.surface,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: FeatureRow(
              title: '$unknown条记录的日期未知',
              subtitle: '可在时光中查看',
              icon: Icons.event_busy_outlined,
              onTap: () => model.selectTab(ShellTab.timeline),
            ),
          ),
          const SizedBox(height: 14),
        ],
        for (final month in months) ...[
          GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MonthReviewPage(month: month))),
            child: _monthCard(month),
          ),
          const SizedBox(height: 14),
        ],
      ]),
    );
  }

  Widget _monthCard(TimelineMonth month) {
    final entries = [for (final day in month.days) ...day.moments];
    final videos = entries.expand((e) => e.photos).where((p) => p.kind == 'video').length;
    final total = entries.fold(0, (n, e) => n + e.mediaCount);
    final photos = total - videos < 0 ? 0 : total - videos;
    final cover = entries.expand((e) => e.photos).take(3).toList();
    final dad = entries.where((e) => e.parent == ParentIdentity.dad).length;
    final mom = entries.length - dad;
    return BrandCard(
      padding: 20,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(month.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
          const Icon(Icons.chevron_right, size: 18, color: JinbaoColors.inkSecondary),
        ]),
        if (cover.isNotEmpty) ...[
          const SizedBox(height: 14),
          SizedBox(
            height: 132,
            child: Row(children: [
              for (final (index, photo) in cover.indexed) ...[
                if (index > 0) const SizedBox(width: 6),
                Expanded(
                  flex: index == 0 ? 2 : 1,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                        color: JinbaoColors.photoPlaceholder,
                        child: PhotoThumbnail(photo: photo, allowsRetry: false, fit: BoxFit.cover)),
                  ),
                ),
              ],
            ]),
          ),
        ],
        const SizedBox(height: 16),
        Row(children: [
          _stat('记录', entries.length),
          const SizedBox(width: 24),
          _stat('照片', photos),
          const SizedBox(width: 24),
          _stat('视频', videos),
        ]),
        const SizedBox(height: 16),
        Text('在${month.days.length}个日子里，留下了${entries.length}份成长记忆。',
            style: const TextStyle(color: JinbaoColors.inkSecondary)),
        if (dad > 0 && mom > 0) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const ParentBadge(ParentIdentity.dad),
            Text('$dad条', style: const TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
            const SizedBox(width: 4),
            const ParentBadge(ParentIdentity.mom),
            Text('$mom条', style: const TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
          ]),
        ],
        if (entries.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(entries.first.displayTitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ]),
    );
  }

  /// Everything so far: days with a record, records and media.
  Widget _summary(AppModel model, List<TimelineEntry> entries) {
    final dated = entries.where((e) => e.occurredAt > 0).toList();
    final days = dated.map((e) => JinbaoCalendar.parts(e.occurredAt, const DeviceZone())).toSet().length;
    final child = model.child;
    return BrandCard(
      padding: 20,
      color: JinbaoColors.goldSoft,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(child == null ? '一起留下的日子' : '陪${child.nickname}留下的日子',
            style: const TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
        const SizedBox(height: 12),
        Row(children: [
          _stat('有记录的日子', days),
          const SizedBox(width: 24),
          _stat('记录', entries.length),
          const SizedBox(width: 24),
          _stat('照片和视频', entries.fold(0, (n, e) => n + e.mediaCount)),
        ]),
      ]),
    );
  }

  Widget _stat(String title, int value) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$value', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(title, style: const TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
      ]);
}

class MonthReviewPage extends StatelessWidget {
  final TimelineMonth month;
  const MonthReviewPage({super.key, required this.month});

  @override
  Widget build(BuildContext context) {
    AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(month.title)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        for (final day in month.days) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 16),
            child: Text(day.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          ),
          for (final entry in day.moments) ...[
            GestureDetector(
              onTap: () => openMomentDetail(context, entry.id),
              child: BrandCard(child: MomentCard(entry: entry)),
            ),
            const SizedBox(height: 16),
          ],
        ],
      ]),
    );
  }
}
