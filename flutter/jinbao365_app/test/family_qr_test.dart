import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/screens/family_qr.dart';
import 'package:qr_flutter/qr_flutter.dart';

const _token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _url = 'https://gateway.example/family-invitations/$_token';

Future<void> _open(
  WidgetTester tester, {
  required FamilyQrCameraBuilder cameraBuilder,
  required void Function(Uri?) onReturned,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              onReturned(await Navigator.of(context).push<Uri>(
                MaterialPageRoute(
                  builder: (_) => FamilyQrScannerScreen(cameraBuilder: cameraBuilder),
                ),
              ));
            },
            child: const Text('打开邀请扫描页'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开邀请扫描页'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('invitation code encodes only the validated opaque HTTPS URL', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FamilyInvitationCode(invitationUrl: Uri.parse(_url)),
        ),
      ),
    );
    await _expectEncodedInvitation(tester, _url);
    expect(find.text(_url), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FamilyInvitationCode(invitationUrl: Uri.parse('$_url?password=synthetic')),
        ),
      ),
    );
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('邀请链接无效，无法生成二维码。'), findsOneWidget);
  });

  testWidgets('camera starts only after a tap and pauses without automatic restart', (tester) async {
    var cameraBuilds = 0;
    await _open(
      tester,
      cameraBuilder: (_, _) {
        cameraBuilds++;
        return const Text('合成相机预览');
      },
      onReturned: (_) {},
    );
    expect(cameraBuilds, 0);
    expect(find.text('合成相机预览'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('family-scan-camera')));
    await tester.pump();
    expect(cameraBuilds, greaterThan(0));
    expect(find.text('合成相机预览'), findsOneWidget);

    // Flutter only accepts resumed → inactive → hidden → paused, then the
    // reverse. Leaving still stops the camera; coming back does not start it.
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    expect(find.text('合成相机预览'), findsNothing);
    final buildsBeforeResume = cameraBuilds;
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    expect(cameraBuilds, buildsBeforeResume);
    expect(find.byKey(const ValueKey('family-scan-camera')), findsOneWidget);
  });

  testWidgets('camera capture returns one URI without opening an external page', (tester) async {
    late void Function(String) capture;
    Uri? returned;
    var returns = 0;
    await _open(
      tester,
      cameraBuilder: (_, detected) {
        capture = detected;
        return const Text('合成相机预览');
      },
      onReturned: (value) {
        returned = value;
        returns++;
      },
    );
    await tester.tap(find.byKey(const ValueKey('family-scan-camera')));
    await tester.pump();
    capture(_url);
    capture(_url);
    await tester.pumpAndSettle();
    expect(returned, Uri.parse(_url));
    expect(returns, 1);
    expect(find.byType(FamilyQrScannerScreen), findsNothing);
  });

  testWidgets('manual link fallback works without starting a platform camera', (tester) async {
    var cameraBuilds = 0;
    Uri? returned;
    await _open(
      tester,
      cameraBuilder: (_, _) {
        cameraBuilds++;
        return const SizedBox();
      },
      onReturned: (value) => returned = value,
    );
    await tester.enterText(find.byKey(const ValueKey('family-invitation-input')), _url);
    await tester.ensureVisible(find.byKey(const ValueKey('family-invitation-submit')));
    await tester.tap(find.byKey(const ValueKey('family-invitation-submit')));
    await tester.pumpAndSettle();
    expect(cameraBuilds, 0);
    expect(returned, Uri.parse(_url));
  });

  testWidgets('invalid QR payloads stay local and are never reflected in errors', (tester) async {
    late void Function(String) capture;
    var returns = 0;
    await _open(
      tester,
      cameraBuilder: (_, detected) {
        capture = detected;
        return const SizedBox();
      },
      onReturned: (_) => returns++,
    );
    await tester.tap(find.byKey(const ValueKey('family-scan-camera')));
    await tester.pump();
    for (final invalid in [
      'http://gateway.example/family-invitations/$_token',
      'https://user:synthetic@gateway.example/family-invitations/$_token',
      '$_url?password=synthetic',
      '$_url#synthetic',
      'https://gateway.example/family-invitations/short',
      'https://gateway.example/other/$_token',
      'https://gateway.example/family-invitations/%41$_token',
      'https://gate way.example/family-invitations/$_token',
    ]) {
      capture(invalid);
      await tester.pump();
      expect(find.text(invalid), findsNothing);
      expect(find.text('这不是有效的家庭邀请，请检查二维码或邀请链接。'), findsOneWidget);
    }
    expect(returns, 0);
    expect(find.byType(FamilyQrScannerScreen), findsOneWidget);
  });

  testWidgets('closing the scanner ignores late camera captures', (tester) async {
    late void Function(String) capture;
    Uri? returned;
    var returns = 0;
    await _open(
      tester,
      cameraBuilder: (_, detected) {
        capture = detected;
        return const SizedBox();
      },
      onReturned: (value) {
        returned = value;
        returns++;
      },
    );
    await tester.tap(find.byKey(const ValueKey('family-scan-camera')));
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    capture(_url);
    await tester.pump();
    expect(returned, isNull);
    expect(returns, 1);
    expect(tester.takeException(), isNull);
  });
}

/// qr_flutter 4.1.0 keeps the payload in a private field. Compare the painted
/// code with one built from the validated URL through the public painter API.
Future<void> _expectEncodedInvitation(WidgetTester tester, String data) async {
  final paint = tester.widget<CustomPaint>(
    find.descendant(of: find.byType(QrImageView), matching: find.byType(CustomPaint)),
  );
  final painter = paint.painter! as QrPainter;
  const size = 180.0;
  final compared = await tester.runAsync(() async {
    Future<List<int>> bytes(QrPainter value) async {
      final image = await value.toImageData(size);
      return image!.buffer.asUint8List();
    }
    final actual = await bytes(painter);
    final expected = await bytes(QrPainter(
      data: data,
      version: painter.version,
      errorCorrectionLevel: painter.errorCorrectionLevel,
      gapless: painter.gapless,
      eyeStyle: painter.eyeStyle,
      dataModuleStyle: painter.dataModuleStyle,
    ));
    final mutated = data.replaceRange(data.length - 1, data.length, data.endsWith('A') ? 'B' : 'A');
    final different = await bytes(QrPainter(
      data: mutated,
      version: painter.version,
      errorCorrectionLevel: painter.errorCorrectionLevel,
      gapless: painter.gapless,
      eyeStyle: painter.eyeStyle,
      dataModuleStyle: painter.dataModuleStyle,
    ));
    return (actual, expected, different);
  });
  expect(compared, isNotNull);
  expect(compared!.$1, compared.$2);
  expect(compared.$1, isNot(equals(compared.$3)));
}
