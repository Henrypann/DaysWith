import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/app_model.dart';
import 'package:jinbao365/main.dart';
import 'package:jinbao365/screens/shell.dart';
import 'package:jinbao365/theme.dart';
import 'package:jinbao_core/jinbao_core.dart';

void main() {
  testWidgets(
    'capsule leaves the content visible and all tab actions reachable',
    (tester) async {
      tester.view.physicalSize = const Size(720, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final session =
          AppSession(
              deviceID: '12345678-1234-4234-8234-123456789abc',
              testBuild: true,
            )
            ..confirmIdentity(ParentIdentity.dad)
            ..connectPlaceholder(
              bucket: 'jinbao-test-1234567890',
              region: 'ap-shanghai',
            );
      final model = AppModel()..session = session;
      addTearDown(model.dispose);
      await tester.pumpWidget(
        AppScope(
          model: model,
          child: MaterialApp(theme: jinbaoTheme(), home: const MainShell()),
        ),
      );
      await tester.pumpAndSettle();

      Finder navigation() {
        final scaffold = tester.widget<Scaffold>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Scaffold && widget.bottomNavigationBar != null,
          ),
        );
        return find.byWidget(scaffold.bottomNavigationBar!);
      }

      final bar = tester.getRect(navigation());
      expect(bar.height, lessThan(120));
      expect(bar.top, greaterThan(650));
      expect(
        tester.getRect(find.text(TimelineEmptyCopy.title)).bottom,
        lessThan(bar.top),
      );

      for (final (label, tab) in [
        ('纪念', ShellTab.anniversaries),
        ('回顾', ShellTab.review),
        ('我的', ShellTab.my),
        ('时光', ShellTab.timeline),
      ]) {
        await tester.tap(
          find.descendant(of: navigation(), matching: find.text(label)),
        );
        await tester.pumpAndSettle();
        expect(model.tab, tab);
        expect(tester.getSize(navigation()).height, lessThan(120));
        expect(tester.takeException(), isNull);
      }

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(find.text('拍照').hitTestable(), findsOneWidget);
      expect(find.text('选照片或视频').hitTestable(), findsOneWidget);
      expect(find.text('写文字').hitTestable(), findsOneWidget);
    },
  );
}
