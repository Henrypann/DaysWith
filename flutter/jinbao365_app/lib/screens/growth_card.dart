import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:jinbao_core/jinbao_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../main.dart';
import '../theme.dart';
import 'timeline.dart';

void openGrowthCard(BuildContext context, String id) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GrowthCardPage(id: id)));
}

/// DaysWith 4.0 成长卡片: one record redrawn as a picture to send to family.
/// The picture is rendered from the screen, so it carries no location or capture metadata.
class GrowthCard extends StatelessWidget {
  final TimelineEntry entry;
  const GrowthCard({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final child = model.child;
    final photo = entry.photos.firstOrNull;
    final date = entry.occurredAt <= 0 ? null : JinbaoCalendar.parts(entry.occurredAt, const DeviceZone());
    final age = date == null ? null : child?.ageOn(date);
    final dayNumber = date == null ? null : child?.dayNumberOn(date);
    final note = swiftTrim(entry.note);
    return Container(
      width: 320,
      decoration: BoxDecoration(color: JinbaoColors.surface, borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        if (photo != null)
          AspectRatio(
            aspectRatio: 4 / 5,
            child: Container(
                color: JinbaoColors.photoPlaceholder, child: PhotoThumbnail(photo: photo, allowsRetry: false, fit: BoxFit.cover)),
          )
        else
          Container(
            color: JinbaoColors.goldSoft,
            padding: const EdgeInsets.fromLTRB(24, 36, 24, 36),
            child: Text(note.isEmpty ? entry.displayTitle : note,
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 20, height: 1.5, fontWeight: FontWeight.w500)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (age != null) ...[
              Text('${child!.nickname} · $age', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
            ],
            Text(entry.displayTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: age == null ? 20 : 15, fontWeight: age == null ? FontWeight.bold : FontWeight.w500)),
            const SizedBox(height: 8),
            Text(
                [
                  if (date != null) '${date.year}年${date.month}月${date.day}日',
                  if (dayNumber != null) '来到世界的第 $dayNumber 天',
                ].join(' · '),
                style: const TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
            const SizedBox(height: 14),
            const Divider(),
            const SizedBox(height: 12),
            Row(children: [
              const BrandMark(size: 22),
              const SizedBox(width: 8),
              const Text('DaysWith', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              ParentBadge(entry.parent),
              const SizedBox(width: 6),
              const Text('记', style: TextStyle(fontSize: 11, color: JinbaoColors.inkSecondary)),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class GrowthCardPage extends StatefulWidget {
  final String id;
  const GrowthCardPage({super.key, required this.id});

  @override
  State<GrowthCardPage> createState() => _GrowthCardPageState();
}

class _GrowthCardPageState extends State<GrowthCardPage> {
  final _boundary = GlobalKey();
  bool _working = false;

  Future<void> _share() async {
    if (_working) return;
    final model = AppScope.read(context);
    setState(() => _working = true);
    try {
      final boundary = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) throw const ContractError('card', '卡片暂时无法生成。');
      final folder = Directory('${(await getTemporaryDirectory()).path}/growth-cards');
      await folder.create(recursive: true);
      // Only the newest card is kept; older copies are disposable.
      await for (final old in folder.list()) {
        if (old is File) await old.delete();
      }
      final file = File('${folder.path}/dayswith-${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: 'image/png')]));
    } catch (_) {
      model.show(const ContractError('card', '卡片暂时无法分享，请稍后再试。'));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final entry = model.session.timelineEntries().where((e) => e.id == widget.id).firstOrNull;
    if (entry == null) {
      return Scaffold(appBar: AppBar(title: const Text('成长卡片')), body: const Center(child: Text('这条记录已经不在时光里。')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('成长卡片')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Center(
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.10), blurRadius: 24, offset: const Offset(0, 8)),
            ]),
            child: RepaintBoundary(key: _boundary, child: GrowthCard(entry: entry)),
          ),
        ),
        const SizedBox(height: 20),
        GoldButton(title: _working ? '正在生成…' : '分享给家人', enabled: !_working, onPressed: _share),
        const SizedBox(height: 12),
        Text(
            model.child == null
                ? '卡片是重新绘制的图片，不带原照片的位置和拍摄信息。在「我的－宝宝档案」填写生日后，卡片会显示年龄。'
                : '卡片是重新绘制的图片，不带原照片的位置和拍摄信息。发给谁由你决定。',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
        if (model.bannerIsError && model.banner != null) ...[
          const SizedBox(height: 12),
          Text(model.banner!, textAlign: TextAlign.center, style: const TextStyle(color: JinbaoColors.problem)),
        ],
      ]),
    );
  }
}
