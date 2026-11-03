import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:jinbao365/family_data_controller.dart';
import 'package:jinbao365/screens/family_media_import.dart';
import 'package:jinbao_core/jinbao_core.dart';

import 'support/family_data_fixture.dart';

class _ImportController extends FamilyDataController {
  final List<LocalAsset> retained = [];
  final List<String> operations = [];
  bool allowed = true;
  bool draft = false;
  bool otherDraft = false;
  bool failRetention = false;
  int begins = 0;
  int prepares = 0;
  _ImportController(FamilyDataFixture fixture) : super(client: fixture.client,
    selectedFamily: fixture.family, currentLocalSession: () => fixture.session,
    localDirectory: fixture.root.path);
  @override
  bool get canContribute => allowed;
  @override
  int get retainedMediaCount => retained.length;
  @override
  bool get hasRetainedMediaDraft => draft;
  @override
  bool get hasPendingUpload => draft || otherDraft;
  @override
  void beginMediaImport() { begins++; draft = true; operations.add('begin'); notifyListeners(); }
  @override
  void retainImportedAsset(LocalAsset asset) {
    if (failRetention) throw const FileSystemException('synthetic-private-retention-error');
    retained.add(asset.copy());
    operations.add('retain:${asset.id}');
    notifyListeners();
  }
  @override
  Future<void> prepareRetainedMedia() async { prepares++; }
}

LocalAsset _asset(int number, {ImportProvenance provenance = ImportProvenance.systemProvided}) => LocalAsset(
  id: familyTestID(50 + number), kind: 'photo', capturedAt: 1700000000000,
  provenance: provenance.rawValue,
  resources: [for (var variant = 0; variant < 2; variant++) LocalResource(
    id: familyTestID(100 + 2 * number + variant), role: variant == 0 ? 'photo' : 'preview',
    contentType: 'image/jpeg', originalFilename: variant == 0 ? 'synthetic.jpg' : 'preview.jpg',
    byteCount: 3, sha256: Digest.sha256Hex([1, 2, 3]),
    relativePath: 'media/synthetic-$number/${variant == 0 ? 'original.jpg' : 'preview.jpg'}',
  )],
);

void main() {
  late Directory workspace;
  late FamilyDataFixture fixture;
  late _ImportController controller;
  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('dayswith-family-import-ui-');
    fixture = FamilyDataFixture(workspace);
    fixture.session.identity = null;
    controller = _ImportController(fixture);
  });
  tearDown(() { controller.dispose(); workspace.deleteSync(recursive: true); });

  testWidgets('a family member without legacy Dad/Mom identity can select media with no upload', (tester) async {
    final file = File('${workspace.path}/selected.jpg')..writeAsBytesSync([1, 2, 3]);
    await tester.pumpWidget(MaterialApp(home: FamilyMediaImportScreen(
      controller: controller,
      pickGallery: () async {
        expect(controller.begins, 1, reason: 'The target-bound local draft must exist before picker await.');
        return [XFile(file.path)];
      },
      importAsset: (_, provenance) async => _asset(1, provenance: provenance),
    )));
    await tester.tap(find.text('从相册选择照片或视频'));
    await tester.pumpAndSettle();
    expect(fixture.session.identity, isNull);
    expect(controller.retained.single.provenance, ImportProvenance.systemProvided.rawValue);
    expect(controller.prepares, 0);
    expect(find.text('已保留 1 / 30 项媒体'), findsOneWidget);
    expect(file.readAsBytesSync(), [1, 2, 3]);
  });

  testWidgets('each completed asset is retained before the next asynchronous import starts', (tester) async {
    var imports = 0;
    await tester.pumpWidget(MaterialApp(home: FamilyMediaImportScreen(
      controller: controller,
      pickGallery: () async => [XFile('/synthetic/a.jpg'), XFile('/synthetic/b.jpg')],
      importAsset: (_, _) async {
        expect(controller.retained.length, imports);
        imports++;
        controller.operations.add('import:$imports');
        return _asset(imports);
      },
    )));
    await tester.tap(find.text('从相册选择照片或视频'));
    await tester.pumpAndSettle();
    expect(controller.operations, ['begin', 'import:1', 'retain:${familyTestID(51)}', 'import:2', 'retain:${familyTestID(52)}']);
    expect(controller.prepares, 0);
  });

  testWidgets('stop waits for the active copy, retains it, and never starts the next item', (tester) async {
    final completedCopy = Completer<LocalAsset>();
    var imports = 0;
    await tester.pumpWidget(MaterialApp(home: FamilyMediaImportScreen(
      controller: controller,
      pickGallery: () async => [XFile('/synthetic/a.jpg'), XFile('/synthetic/b.jpg')],
      importAsset: (_, _) { imports++; return completedCopy.future; },
    )));
    await tester.tap(find.text('从相册选择照片或视频'));
    await tester.pump();
    expect(imports, 1);
    await tester.ensureVisible(find.text('停止后续导入'));
    await tester.pump();
    await tester.tap(find.text('停止后续导入'));
    await tester.pump();
    completedCopy.complete(_asset(1));
    await tester.pumpAndSettle();
    expect(imports, 1);
    expect(controller.retained, hasLength(1));
    expect(find.textContaining('完成的副本与草稿仍保留'), findsOneWidget);
  });

  testWidgets('disposing the route during a copy still retains the completed asset', (tester) async {
    final completedCopy = Completer<LocalAsset>();
    await tester.pumpWidget(MaterialApp(home: FamilyMediaImportScreen(
      controller: controller,
      pickGallery: () async => [XFile('/synthetic/a.jpg'), XFile('/synthetic/b.jpg')],
      importAsset: (_, _) => completedCopy.future,
    )));
    await tester.tap(find.text('从相册选择照片或视频'));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    completedCopy.complete(_asset(1));
    await tester.pumpAndSettle();
    expect(controller.retained, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a cancelled picker preserves the empty bound draft without imports or consent', (tester) async {
    var imports = 0;
    await tester.pumpWidget(MaterialApp(home: FamilyMediaImportScreen(
      controller: controller,
      pickGallery: () async => [],
      importAsset: (_, _) async { imports++; return _asset(1); },
    )));
    await tester.tap(find.text('从相册选择照片或视频'));
    await tester.pumpAndSettle();
    expect(imports, 0);
    expect(controller.draft, isTrue);
    expect(controller.prepares, 0);
    expect(find.textContaining('已有草稿保持原样'), findsOneWidget);
  });

  testWidgets('a failed import stops the batch and keeps already retained copies', (tester) async {
    var imports = 0;
    await tester.pumpWidget(MaterialApp(home: FamilyMediaImportScreen(
      controller: controller,
      pickGallery: () async => [XFile('/synthetic/a.jpg'), XFile('/synthetic/b.jpg'), XFile('/synthetic/c.jpg')],
      importAsset: (_, _) async {
        imports++;
        if (imports == 2) throw StateError('synthetic-private-import-error');
        return _asset(imports);
      },
    )));
    await tester.tap(find.text('从相册选择照片或视频'));
    await tester.pumpAndSettle();
    expect(imports, 2);
    expect(controller.retained, hasLength(1));
    expect(find.textContaining('synthetic-private-import-error'), findsNothing);
    expect(find.textContaining('已完成的副本和草稿继续保留'), findsOneWidget);
  });

  testWidgets('camera photo and video use camera provenance without a legacy identity', (tester) async {
    final provenances = <ImportProvenance>[];
    await tester.pumpWidget(MaterialApp(home: FamilyMediaImportScreen(
      controller: controller,
      takePhoto: () async => XFile('/synthetic/camera.jpg'),
      takeVideo: () async => XFile('/synthetic/camera.mp4'),
      importAsset: (_, provenance) async {
        provenances.add(provenance);
        return _asset(provenances.length, provenance: provenance);
      },
    )));
    await tester.tap(find.text('拍一张照片'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('拍摄视频'));
    await tester.tap(find.text('拍摄视频'));
    await tester.pumpAndSettle();
    expect(provenances, [ImportProvenance.camera, ImportProvenance.camera]);
    expect(fixture.session.identity, isNull);
    expect(controller.retained, hasLength(2));
  });

  testWidgets('continuing returns an explicit choice but does not prepare or upload', (tester) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(body: FilledButton(
      onPressed: () async {
        result = await showFamilyMediaImport(context, controller: controller,
          pickGallery: () async => [XFile('/synthetic/a.jpg')],
          importAsset: (_, _) async => _asset(1));
      },
      child: const Text('打开家庭导入'),
    )))));
    await tester.tap(find.text('打开家庭导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从相册选择照片或视频'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    await tester.scrollUntilVisible(find.text('保留并继续确认'), 200);
    await tester.tap(find.text('保留并继续确认'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(controller.prepares, 0);
  });

  testWidgets('failed metadata persistence stops before the next imported file', (tester) async {
    controller.failRetention = true;
    var imports = 0;
    final original = File('${workspace.path}/selected.jpg')..writeAsBytesSync([1, 2, 3]);
    await tester.pumpWidget(MaterialApp(home: FamilyMediaImportScreen(
      controller: controller,
      pickGallery: () async => [XFile(original.path), XFile('/synthetic/next.jpg')],
      importAsset: (_, _) async { imports++; return _asset(imports); },
    )));
    await tester.tap(find.text('从相册选择照片或视频'));
    await tester.pumpAndSettle();
    expect(imports, 1);
    expect(controller.prepares, 0);
    expect(original.readAsBytesSync(), [1, 2, 3]);
    expect(find.textContaining('synthetic-private-retention-error'), findsNothing);
    expect(find.textContaining('这项媒体未完成保留'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
