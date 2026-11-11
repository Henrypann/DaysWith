import 'package:flutter/material.dart';

import '../main.dart';
import '../theme.dart';

/// DaysWith 4.0 first run: say what the app is for before asking who holds this phone.
class WelcomeFlow extends StatefulWidget {
  const WelcomeFlow({super.key});

  @override
  State<WelcomeFlow> createState() => _WelcomeFlowState();
}

class _WelcomeFlowState extends State<WelcomeFlow> {
  bool _started = false;

  @override
  Widget build(BuildContext context) {
    if (_started) return const IdentityView();
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(24), children: [
          const SizedBox(height: 24),
          const Center(child: BrandMark(size: 72)),
          const SizedBox(height: 20),
          const Center(child: BrandWordmark()),
          const SizedBox(height: 8),
          const Center(
            child: Text('留住一起度过的日子', style: TextStyle(fontSize: 16, color: JinbaoColors.inkSecondary)),
          ),
          const SizedBox(height: 32),
          const _Promise(
            icon: Icons.photo_library_outlined,
            title: '一条属于孩子的时间线',
            detail: '照片、视频和文字按年月排好，爸爸妈妈各自署名，一起回看。',
          ),
          const _Promise(
            icon: Icons.cake_outlined,
            title: '每一天都知道她多大',
            detail: '填一次生日，每条记录都会标上当时的年龄，还有「那年今天」。',
          ),
          const _Promise(
            icon: Icons.smartphone_outlined,
            title: '先记在这台手机，也可以连自己的云',
            detail: '没有会员订阅。想备份时，连接你自己的腾讯云对象存储。',
          ),
          const SizedBox(height: 24),
          GoldButton(title: '开始记录', onPressed: () => setState(() => _started = true)),
          const SizedBox(height: 12),
          const Center(
            child: Text('开源 · MIT 许可 · 记录保存在你选择的地方',
                style: TextStyle(fontSize: 12, color: JinbaoColors.inkSecondary)),
          ),
        ]),
      ),
    );
  }
}

class _Promise extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  const _Promise({required this.icon, required this.title, required this.detail});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: BrandCard(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: JinbaoColors.goldSoft, borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: JinbaoColors.ink),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(detail, style: const TextStyle(fontSize: 13, color: JinbaoColors.inkSecondary)),
              ]),
            ),
          ]),
        ),
      );
}
