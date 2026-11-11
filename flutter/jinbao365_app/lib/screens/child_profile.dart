import 'package:flutter/material.dart';
import 'package:jinbao_core/jinbao_core.dart';

import '../child_profile.dart';
import '../main.dart';
import '../theme.dart';

void openChildProfile(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => const ChildProfilePage()));
}

/// DaysWith 4.0: nickname and birthday, so every record can show the age at that moment.
class ChildProfilePage extends StatefulWidget {
  const ChildProfilePage({super.key});

  @override
  State<ChildProfilePage> createState() => _ChildProfilePageState();
}

class _ChildProfilePageState extends State<ChildProfilePage> {
  final _nickname = TextEditingController();
  DateParts? _birthday;
  bool _addAnniversary = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final child = AppScope.read(context).child;
    _nickname.text = child?.nickname ?? '';
    _birthday = child?.birthday;
    _addAnniversary = child == null;
    _nickname.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nickname.dispose();
    super.dispose();
  }

  /// Birthdays with a year that either parent already keeps as an anniversary.
  List<({String title, DateParts date})> _suggestions(List<AnniversaryEntry> entries) => [
        for (final entry in entries)
          if (entry.title.contains('生日') && entry.yearKnown)
            if (ChildProfile.parseDate(entry.date) case final date?) (title: entry.title, date: date),
      ];

  Future<void> _pick() async {
    final now = DateTime.now();
    final current = _birthday;
    final picked = await showDatePicker(
      context: context,
      initialDate: current == null ? now : DateTime(current.year, current.month, current.day),
      firstDate: DateTime(1990),
      lastDate: now,
      helpText: '选择生日',
    );
    if (picked != null) setState(() => _birthday = DateParts(picked.year, picked.month, picked.day));
  }

  Future<void> _save() async {
    final model = AppScope.read(context);
    final birthday = _birthday;
    if (birthday == null || _saving) return;
    setState(() => _saving = true);
    final saved = await model.saveChild(nickname: _nickname.text, birthday: birthday);
    if (!mounted) return;
    setState(() => _saving = false);
    if (!saved) return;
    final profile = model.child!;
    if (_addAnniversary &&
        !model.session.anniversaryEntries().any((e) => e.date == profile.storedBirthday && e.title.contains('生日'))) {
      model.saveAnniversary(title: '${profile.nickname}的生日', date: profile.storedBirthday);
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final birthday = _birthday;
    final suggestions = model.child == null ? _suggestions(model.session.anniversaryEntries()) : const [];
    final preview = birthday == null
        ? null
        : ChildProfile(nickname: swiftTrim(_nickname.text), birthday: birthday)
            .ageOn(JinbaoCalendar.parts(DateTime.now().millisecondsSinceEpoch, const DeviceZone()));
    final canSave = swiftTrim(_nickname.text).isNotEmpty && birthday != null && !_saving;
    return Scaffold(
      appBar: AppBar(
        title: const Text('宝宝档案'),
        leading: TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        leadingWidth: 72,
        actions: [
          TextButton(
            onPressed: canSave ? _save : null,
            child: const Text('保存', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('填一次生日，每条记录都会标上当时的年龄。', style: TextStyle(color: JinbaoColors.inkSecondary)),
        const SizedBox(height: 12),
        BrandCard(
          child: Column(children: [
            TextField(
              controller: _nickname,
              maxLength: ChildProfile.maxNicknameLength,
              decoration: const InputDecoration(hintText: '小名'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('生日'),
              trailing: Text(birthday == null ? '选择日期' : '${birthday.year}年${birthday.month}月${birthday.day}日',
                  style: const TextStyle(fontSize: 15)),
              onTap: _pick,
            ),
            if (model.child == null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('同时加入纪念日'),
                value: _addAnniversary,
                onChanged: (value) => setState(() => _addAnniversary = value),
              ),
          ]),
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('从纪念日里选', style: TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final item in suggestions)
              ActionChip(
                label: Text('${item.title} · ${item.date.year}年${item.date.month}月${item.date.day}日'),
                backgroundColor: JinbaoColors.surface,
                onPressed: () => setState(() {
                  _birthday = item.date;
                  _addAnniversary = false;
                  if (swiftTrim(_nickname.text).isEmpty) {
                    final name = swiftTrim(item.title.replaceAll('的生日', '').replaceAll('生日', ''));
                    if (name.isNotEmpty && name.length <= ChildProfile.maxNicknameLength) _nickname.text = name;
                  }
                }),
              ),
          ]),
        ],
        if (preview != null) ...[
          const SizedBox(height: 16),
          BrandCard(
            color: JinbaoColors.goldSoft,
            padding: 20,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('今天', style: TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
              const SizedBox(height: 6),
              Text(preview, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            ]),
          )
        ] else if (birthday != null) ...[
          const SizedBox(height: 16),
          const Text('生日不能晚于今天。', style: TextStyle(color: JinbaoColors.problem)),
        ],
        if (model.bannerIsError && model.banner != null) ...[
          const SizedBox(height: 12),
          Text(model.banner!, style: const TextStyle(color: JinbaoColors.problem)),
        ],
        const SizedBox(height: 16),
        const Text('小名和生日只保存在这台手机，用来计算年龄；不会写入档案，也不会上传。另一台手机需要各自填写。',
            style: TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
        if (model.child != null) ...[
          const SizedBox(height: 16),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: JinbaoColors.problem),
            onPressed: () async {
              if (await confirmAction(context,
                  title: '移除宝宝档案？', message: '记录不受影响，只是不再显示年龄。', confirm: '移除', destructive: true)) {
                await model.clearChild();
                if (context.mounted) Navigator.pop(context);
              }
            },
            child: const Text('移除宝宝档案'),
          ),
        ],
      ]),
    );
  }
}
