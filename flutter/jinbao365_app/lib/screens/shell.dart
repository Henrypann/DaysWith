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
Future<void> openComposer(
  BuildContext context, {
  ComposerStart start = ComposerStart.resume,
}) async {
  final model = AppScope.read(context);
  if (!model.beginDraft()) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => ComposerPage(start: start),
    ),
  );
}

class MainShell extends StatelessWidget {
  const MainShell({super.key});

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final keyboard = MediaQuery.of(context).viewInsets.bottom > 0;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (model.banner != null)
              GestureDetector(
                onTap: model.clearBanner,
                child: StatusBanner(
                  text: model.banner!,
                  isError: model.bannerIsError,
                ),
              ),
            if (!model.session.link.isVerified)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.phone_android_outlined,
                      size: 18,
                      color: JinbaoColors.inkSecondary,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '仅保存在本机 · 可稍后连接存储',
                        style: TextStyle(
                          fontSize: 14,
                          color: JinbaoColors.inkSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: switch (model.tab) {
                ShellTab.timeline => const TimelineScreen(),
                // Keep the old navigation value so this UI change does not rewrite
                // any model or archive identifiers.
                ShellTab.anniversaries => const RecordHomeScreen(),
                ShellTab.review => const ReviewScreen(),
                ShellTab.my => const MyScreen(),
              },
            ),
          ],
        ),
      ),
      bottomNavigationBar: keyboard
          ? null
          : SafeArea(top: false, child: _navigation(model)),
    );
  }

  Widget _navigation(AppModel model) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    child: Material(
      color: JinbaoColors.surface,
      borderRadius: BorderRadius.circular(24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _barButton(
            model,
            '时光',
            Icons.photo_library_outlined,
            ShellTab.timeline,
          ),
          _barButton(
            model,
            '记录',
            Icons.add_circle_outline,
            ShellTab.anniversaries,
          ),
          _barButton(
            model,
            '回忆',
            Icons.calendar_today_outlined,
            ShellTab.review,
          ),
          _barButton(model, '我的', Icons.account_circle_outlined, ShellTab.my),
        ],
      ),
    ),
  );

  Widget _barButton(AppModel model, String title, IconData icon, ShellTab tab) {
    final selected = model.tab == tab;
    return Expanded(
      child: Semantics(
        selected: selected,
        button: true,
        label: title,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () => model.selectTab(tab),
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? JinbaoColors.goldSoft : Colors.transparent,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 24,
                  color: selected ? JinbaoColors.ink : JinbaoColors.outline,
                ),
                const SizedBox(height: 4),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? JinbaoColors.ink
                        : JinbaoColors.inkSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A stable destination for common recording actions, including large text users.
class RecordHomeScreen extends StatelessWidget {
  const RecordHomeScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('记录')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '留下一点今天',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          '主动选择照片或视频，或写下想记住的事。',
          style: TextStyle(fontSize: 16, color: JinbaoColors.inkSecondary),
        ),
        const SizedBox(height: 20),
        BrandCard(
          child: Column(
            children: [
              FeatureRow(
                title: '添加照片或视频',
                icon: Icons.photo_library_outlined,
                onTap: () =>
                    openComposer(context, start: ComposerStart.pickMedia),
              ),
              const Divider(),
              FeatureRow(
                title: '拍照',
                icon: Icons.photo_camera_outlined,
                onTap: () => openComposer(context, start: ComposerStart.camera),
              ),
              const Divider(),
              FeatureRow(
                title: '写文字',
                icon: Icons.edit_note,
                onTap: () => openComposer(context),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        BrandCard(
          child: FeatureRow(
            title: '纪念日',
            subtitle: '记录、编辑和回看重要的日子',
            icon: Icons.favorite_border,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AnniversariesScreen(),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
