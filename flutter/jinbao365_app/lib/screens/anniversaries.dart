import 'package:flutter/material.dart';
import 'package:jinbao_core/jinbao_core.dart';

import '../app_model.dart';
import '../main.dart';
import '../theme.dart';

/// UI formatting only (AnniversaryPresentation in AnniversariesView.swift).
class AnniversaryPresentation {
  final int daysUntil;
  final String subtitle;

  factory AnniversaryPresentation(AnniversaryEntry entry) {
    final raw = entry.date.split('-').where((s) => s.isNotEmpty).map(int.tryParse).whereType<int>().toList();
    final known = raw.length == 3 && raw[0] != 4;
    final month = raw.length >= 2 ? raw[raw.length - 2] : 1;
    final day = raw.isEmpty ? 1 : raw.last;
    final upcoming =
        AnniversaryCalendar.upcoming([entry], now: AppModel.now, zone: const DeviceZone()).firstOrNull;
    final years = upcoming?.years;
    final String subtitle;
    if (known && years != null) {
      subtitle = '${raw[0]}年$month月$day日 · ${entry.title.contains('生日') ? '$years岁' : '$years周年'}';
    } else {
      subtitle = '每年$month月$day日 · 年份未填写';
    }
    return AnniversaryPresentation._(upcoming?.daysUntil ?? 0, subtitle);
  }

  const AnniversaryPresentation._(this.daysUntil, this.subtitle);
}

class AnniversariesScreen extends StatelessWidget {
  const AnniversariesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final entries = model.session.anniversaryEntries()
      ..sort((a, b) {
        final left = AnniversaryPresentation(a).daysUntil, right = AnniversaryPresentation(b).daysUntil;
        return left == right ? a.title.compareTo(b.title) : left.compareTo(right);
      });
    return Scaffold(
      appBar: AppBar(
        title: const Text('纪念'),
        actions: [
          IconButton(tooltip: '添加纪念日', icon: const Icon(Icons.add), onPressed: () => _openEditor(context, null)),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (entries.isEmpty)
          const FeatureEmptyState(title: '把重要的日子记下来', detail: '生日、纪念日，还有你们的小约定。', icon: Icons.favorite_border),
        for (final (index, entry) in entries.indexed) ...[
          GestureDetector(onTap: () => _openEditor(context, entry), child: AnniversaryCard(entry: entry, featured: index == 0)),
          const SizedBox(height: 12),
        ],
      ]),
    );
  }

  void _openEditor(BuildContext context, AnniversaryEntry? entry) {
    Navigator.of(context).push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => AnniversaryEditor(entry: entry)));
  }
}

class AnniversaryCard extends StatelessWidget {
  final AnniversaryEntry entry;
  final bool featured;
  const AnniversaryCard({super.key, required this.entry, this.featured = false});

  @override
  Widget build(BuildContext context) {
    final presentation = AnniversaryPresentation(entry);
    final days = presentation.daysUntil;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: featured ? JinbaoColors.goldSoft : JinbaoColors.surface, borderRadius: BorderRadius.circular(20)),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(entry.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(presentation.subtitle, style: const TextStyle(color: JinbaoColors.inkSecondary)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              ParentBadge(entry.owner),
              if (entry.readOnly) const Text('只读', style: TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
              if (days <= 7) const Text('就在这周', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
            ]),
          ]),
        ),
        const SizedBox(width: 8),
        if (days == 0)
          const Text('就是今天', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold))
        else
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            const Text('还有', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 4),
            Text('$days',
                style: TextStyle(
                    fontSize: featured ? 42 : 34,
                    fontWeight: FontWeight.bold,
                    fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(width: 4),
            const Text('天', style: TextStyle(fontSize: 15)),
          ]),
      ]),
    );
  }
}

/// In-app reminder on the timeline for anniversaries 0, 1, 2, 3 or 7 days away.
class AnniversaryReminder extends StatelessWidget {
  const AnniversaryReminder({super.key});

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final upcoming = model.session
        .anniversaryEntries()
        .map((e) => (entry: e, days: AnniversaryPresentation(e).daysUntil))
        .where((e) => const [0, 1, 2, 3, 7].contains(e.days))
        .toList()
      ..sort((a, b) => a.days.compareTo(b.days));
    final first = upcoming.firstOrNull;
    if (first == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: JinbaoColors.goldSoft,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => model.selectTab(ShellTab.anniversaries),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              const Icon(Icons.favorite, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(first.days == 0 ? '今天是${first.entry.title}' : '还有${first.days}天，${first.entry.title}',
                    style: const TextStyle(fontWeight: FontWeight.w500)),
              ),
              const Icon(Icons.chevron_right, size: 16),
            ]),
          ),
        ),
      ),
    );
  }
}

class AnniversaryEditor extends StatefulWidget {
  final AnniversaryEntry? entry;
  const AnniversaryEditor({super.key, required this.entry});

  @override
  State<AnniversaryEditor> createState() => _AnniversaryEditorState();
}

class _AnniversaryEditorState extends State<AnniversaryEditor> {
  final _title = TextEditingController();
  DateTime _date = DateTime.now();
  bool _yearKnown = true;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    _title.addListener(() => setState(() {}));
    if (entry == null) return;
    _title.text = entry.title;
    final values = entry.date.split('-').where((s) => s.isNotEmpty).map(int.tryParse).whereType<int>().toList();
    _yearKnown = values.length == 3 && values[0] != 4;
    if (values.length >= 2) _date = DateTime(_yearKnown ? values[0] : 2000, values[values.length - 2], values.last);
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  String get _storedDate {
    final mm = twoDigits(_date.month), dd = twoDigits(_date.day);
    return _yearKnown ? '${_date.year.toString().padLeft(4, '0')}-$mm-$dd' : '--$mm-$dd';
  }

  int _daysIn(int month) => JinbaoCalendar.daysInMonth(2000, month);

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final entry = widget.entry;
    final readOnly = entry?.readOnly ?? false;
    return Scaffold(
      appBar: AppBar(
        title: Text(entry == null ? '添加纪念日' : '纪念日'),
        leading: TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        leadingWidth: 72,
        actions: [
          if (!readOnly)
            TextButton(
              onPressed: swiftTrim(_title.text).isEmpty
                  ? null
                  : () {
                      if (model.saveAnniversary(id: entry?.id, title: _title.text, date: _storedDate)) Navigator.pop(context);
                    },
              child: const Text('保存', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('重要的日子', style: TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
        const SizedBox(height: 8),
        BrandCard(
          child: Column(children: [
            TextField(controller: _title, enabled: !readOnly, maxLength: 100, decoration: const InputDecoration(hintText: '名称')),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('填写年份'),
              value: _yearKnown,
              onChanged: readOnly ? null : (value) => setState(() => _yearKnown = value),
            ),
            if (_yearKnown)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('日期'),
                trailing: Text('${_date.year}年${_date.month}月${_date.day}日'),
                onTap: readOnly
                    ? null
                    : () async {
                        final picked = await showDatePicker(
                            context: context, initialDate: _date, firstDate: DateTime(1900), lastDate: DateTime(2200));
                        if (picked != null) setState(() => _date = picked);
                      },
              )
            else
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _date.month,
                    decoration: const InputDecoration(labelText: '月'),
                    items: [for (var m = 1; m <= 12; m++) DropdownMenuItem(value: m, child: Text('$m月'))],
                    onChanged: readOnly
                        ? null
                        : (m) => setState(() {
                              final day = _date.day > _daysIn(m!) ? _daysIn(m) : _date.day;
                              _date = DateTime(2000, m, day);
                            }),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: ValueKey(_date.month),
                    initialValue: _date.day,
                    decoration: const InputDecoration(labelText: '日'),
                    items: [for (var d = 1; d <= _daysIn(_date.month); d++) DropdownMenuItem(value: d, child: Text('$d日'))],
                    onChanged: readOnly ? null : (d) => setState(() => _date = DateTime(2000, _date.month, d!)),
                  ),
                ),
              ]),
          ]),
        ),
        const SizedBox(height: 16),
        BrandCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (entry != null) ...[
              Row(children: [const Expanded(child: Text('署名')), ParentBadge(entry.owner)]),
              if (entry.readOnly) ...[
                const SizedBox(height: 8),
                const Text('来自另一台设备或另一位家长，仅可查看。', style: TextStyle(color: JinbaoColors.inkSecondary)),
              ],
              const SizedBox(height: 8),
            ],
            const Text('提醒会显示在应用内，不发送系统通知。', style: TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
          ]),
        ),
        if (entry != null && !readOnly) ...[
          const SizedBox(height: 16),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: JinbaoColors.problem),
            onPressed: () async {
              if (await confirmAction(context,
                  title: '删除纪念日？', message: '从列表移除这条纪念日，云端文件不会被删除。', confirm: '删除', destructive: true)) {
                model.deleteAnniversary(entry.id);
                if (context.mounted) Navigator.pop(context);
              }
            },
            child: const Text('删除纪念日'),
          ),
        ],
      ]),
    );
  }
}
