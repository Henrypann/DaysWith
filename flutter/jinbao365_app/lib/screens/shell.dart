import 'package:flutter/material.dart';

import '../app_model.dart';
import '../main.dart';
import '../theme.dart';
import 'anniversaries.dart';
import 'composer.dart';
import 'my.dart';
import 'review.dart';
import 'timeline.dart';

enum ComposerStart { resume, pickMedia, camera }

/// Opens the composer as a full-screen page, starting or resuming the durable draft.
Future<void> openComposer(BuildContext context, {ComposerStart start = ComposerStart.resume}) async {
  final model = AppScope.read(context);
  if (!model.beginDraft()) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => ComposerPage(start: start),
  ));
}

/// Port of MainShell.swift: banner, tab content, capsule bar with the gold ＋ in the middle.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  bool _addMenuOpen = false;

  void _select(AppModel model, ShellTab tab) {
    setState(() => _addMenuOpen = false);
    model.selectTab(tab);
  }

  void _add(ComposerStart start) {
    setState(() => _addMenuOpen = false);
    openComposer(context, start: start);
  }

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final keyboard = MediaQuery.of(context).viewInsets.bottom > 0;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(children: [
          Column(children: [
            if (model.banner != null)
              GestureDetector(
                onTap: model.clearBanner,
                child: StatusBanner(text: model.banner!, isError: model.bannerIsError),
              ),
            Expanded(
              child: switch (model.tab) {
                ShellTab.timeline => const TimelineScreen(),
                ShellTab.anniversaries => const AnniversariesScreen(),
                ShellTab.review => const ReviewScreen(),
                ShellTab.my => const MyScreen(),
              },
            ),
          ]),
          if (_addMenuOpen) _addMenu(),
        ]),
      ),
      bottomNavigationBar: keyboard ? null : SafeArea(top: false, child: _capsuleBar(model)),
    );
  }

  Widget _capsuleBar(AppModel model) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
          Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: JinbaoColors.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.black.withValues(alpha: 15 / 255), width: 0.5),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.10), blurRadius: 12, offset: const Offset(0, 4))],
            ),
            child: Row(children: [
              _barButton(model, '时光', Icons.photo_library_outlined, ShellTab.timeline),
              _barButton(model, '纪念', Icons.favorite_border, ShellTab.anniversaries),
              const SizedBox(width: 60, height: 48),
              _barButton(model, '回顾', Icons.calendar_today_outlined, ShellTab.review),
              _barButton(model, '我的', Icons.account_circle_outlined, ShellTab.my),
            ]),
          ),
          Positioned(
            top: -8,
            child: Semantics(
              label: '添加记录',
              button: true,
              child: GestureDetector(
                onTap: () => setState(() => _addMenuOpen = !_addMenuOpen),
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: JinbaoColors.gold,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.10), blurRadius: 8, offset: const Offset(0, 3))],
                  ),
                  child: const Icon(Icons.add, size: 32, color: JinbaoColors.ink),
                ),
              ),
            ),
          ),
        ]),
      );

  Widget _barButton(AppModel model, String title, IconData icon, ShellTab tab) {
    final selected = model.tab == tab;
    return Expanded(
      child: Semantics(
        selected: selected,
        button: true,
        label: title,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => _select(model, tab),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            decoration: BoxDecoration(
              color: selected ? JinbaoColors.goldSoft : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 24, color: selected ? JinbaoColors.ink : JinbaoColors.outline),
              const SizedBox(height: 2),
              Text(title,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: selected ? JinbaoColors.ink : JinbaoColors.inkSecondary)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _addMenu() => Positioned.fill(
        child: GestureDetector(
          onTap: () => setState(() => _addMenuOpen = false),
          child: Container(
            color: Colors.black.withValues(alpha: 0.04),
            alignment: Alignment.bottomCenter,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Material(
              color: JinbaoColors.surface,
              borderRadius: BorderRadius.circular(20),
              elevation: 6,
              shadowColor: JinbaoColors.ink.withValues(alpha: 0.3),
              clipBehavior: Clip.antiAlias,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                _menuRow('拍照', Icons.photo_camera_outlined, () => _add(ComposerStart.camera)),
                _menuRow('选照片或视频', Icons.photo_outlined, () => _add(ComposerStart.pickMedia)),
                _menuRow('写文字', Icons.edit_note, () => _add(ComposerStart.resume)),
              ]),
            ),
          ),
        ),
      );

  Widget _menuRow(String title, IconData icon, VoidCallback onTap) => InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(children: [
            SizedBox(width: 24, child: Icon(icon, color: JinbaoColors.ink)),
            const SizedBox(width: 16),
            Text(title, style: const TextStyle(fontSize: 16)),
          ]),
        ),
      );
}
