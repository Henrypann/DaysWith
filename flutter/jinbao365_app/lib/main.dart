import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:jinbao_core/jinbao_core.dart';

import 'app_model.dart';
import 'screens/cloud_connect.dart';
import 'screens/shell.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
  final model = AppModel();
  runApp(AppScope(model: model, child: const JinbaoApp()));
  model.start();
}

/// Makes the single [AppModel] available to every screen and rebuilds them on change.
class AppScope extends InheritedNotifier<AppModel> {
  const AppScope({super.key, required AppModel model, required super.child}) : super(notifier: model);

  static AppModel of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
  static AppModel read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

class JinbaoApp extends StatefulWidget {
  const JinbaoApp({super.key});

  @override
  State<JinbaoApp> createState() => _JinbaoAppState();
}

class _JinbaoAppState extends State<JinbaoApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning to the foreground refreshes family records and resumes interrupted backups.
    if (state == AppLifecycleState.resumed) AppScope.read(context).activate();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: CredentialStoreContract.displayName,
        debugShowCheckedModeBanner: false,
        theme: jinbaoTheme(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const RootView(),
      );
}

class RootView extends StatelessWidget {
  const RootView({super.key});

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    if (!model.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: JinbaoColors.ink)));
    }
    final recovery = model.archiveRecoveryMessage;
    if (recovery != null) return ArchiveRecoveryView(message: recovery);
    return switch (model.session.phase) {
      AppPhase.chooseIdentity => const IdentityView(),
      AppPhase.connectCloud => const Scaffold(body: SafeArea(child: CloudConnectView(mandatory: true))),
      AppPhase.timeline => const MainShell(),
    };
  }
}

class ArchiveRecoveryView extends StatelessWidget {
  final String message;
  const ArchiveRecoveryView({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Text('本地档案需要恢复', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            Text(message, textAlign: TextAlign.center),
            if (model.banner != null) ...[
              const SizedBox(height: 20),
              Text(model.banner!, style: const TextStyle(color: JinbaoColors.problem)),
            ],
            const SizedBox(height: 20),
            OutlinedButton(onPressed: model.retryArchive, child: const Text('重新读取档案')),
            const SizedBox(height: 12),
            GoldButton(title: '恢复有效副本', onPressed: model.recoverArchive),
          ]),
        ),
      ),
    );
  }
}

class IdentityView extends StatelessWidget {
  const IdentityView({super.key});

  Future<void> _choose(BuildContext context, ParentIdentity parent) async {
    final model = AppScope.read(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认这台手机的署名'),
        content: Text('这台手机记的内容会署名「${parent.label}」，之后不能修改。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('重新选')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定')),
        ],
      ),
    );
    if (confirmed == true) model.confirm(parent);
  }

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(24), children: [
          const Padding(padding: EdgeInsets.only(top: 24, bottom: 32), child: Center(child: BrandWordmark())),
          BrandCard(
            color: JinbaoColors.goldSoft,
            padding: 20,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
              BrandMark(),
              SizedBox(height: 12),
              Text('这台手机是谁', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              SizedBox(height: 12),
              Text('每一条生活记录，都会留下你的署名。确认之后不能修改。',
                  style: TextStyle(fontSize: 16, color: JinbaoColors.inkSecondary)),
            ]),
          ),
          const SizedBox(height: 20),
          for (final parent in ParentIdentity.values) ...[
            _ParentButton(parent: parent, onTap: () => _choose(context, parent)),
            const SizedBox(height: 20),
          ],
          if (model.banner != null)
            Text(model.banner!,
                style: TextStyle(color: model.bannerIsError ? JinbaoColors.problem : JinbaoColors.ink)),
        ]),
      ),
    );
  }
}

class _ParentButton extends StatelessWidget {
  final ParentIdentity parent;
  final VoidCallback onTap;
  const _ParentButton({required this.parent, required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: JinbaoColors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20), side: const BorderSide(color: JinbaoColors.separator)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 88),
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                    color: JinbaoColors.parentBackground(parent), borderRadius: BorderRadius.circular(16)),
                child: Icon(Icons.account_circle, size: 32, color: JinbaoColors.parentInk(parent)),
              ),
              const SizedBox(width: 16),
              Expanded(
                  child: Text(parent.label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
              const Icon(Icons.chevron_right, color: JinbaoColors.outline),
            ]),
          ),
        ),
      );
}
