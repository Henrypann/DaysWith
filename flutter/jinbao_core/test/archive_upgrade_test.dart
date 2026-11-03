import 'dart:convert';
import 'dart:io';

import 'package:jinbao_core/jinbao_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory folder;
  late ArchiveStore store;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('dayswith-schema-copy-');
    store = ArchiveStore('${folder.path}/archive.json');
  });
  tearDown(() => folder.delete(recursive: true));

  List<int> legacy() {
    final session = AppSession(deviceID: '11111111-1111-4111-8111-111111111111', testBuild: true)
      ..confirmIdentity(ParentIdentity.dad)
      ..beginDraft(now: 1700000000000)
      ..updateDraft(title: 'Synthetic legacy', note: 'Retain original bytes')
      ..commitDraft(now: 1700000000001);
    final data = PersistedArchive.fromSession(session).toJson()..['schemaVersion'] = 2;
    // Deliberately non-canonical whitespace: rollback preserves exact bytes.
    return utf8.encode(const JsonEncoder.withIndent('  ').convert(data));
  }

  test('pre-upgrade schema copy is byte-exact and survives ordinary recovery rotation', () {
    final bytes = legacy();
    File(store.path).writeAsBytesSync(bytes);
    final session = store.load()!.session();
    final recordID = session.moments.single.id;
    store.save(PersistedArchive.fromSession(session));
    final copy = File('${store.path}.schema-2-${Digest.sha256Hex(bytes)}');
    expect(copy.readAsBytesSync(), bytes);
    for (var i = 0; i < 3; i++) {
      session.beginEdit(id: recordID, now: 1700000000010 + i);
      session.updateDraft(title: 'Edit $i', note: 'Synthetic edit');
      session.commitDraft(now: 1700000000020 + i);
      store.save(PersistedArchive.fromSession(session));
    }
    expect(copy.readAsBytesSync(), bytes);
    expect(store.load()!.moments.single.title, 'Edit 2');
    expect(store.loadRecovery().schemaVersion, PersistedArchive.currentVersion);
    expect(PersistedArchive.fromJson(jsonDecode(utf8.decode(copy.readAsBytesSync()))).schemaVersion, 2);
  });

  test('an unexpected existing schema copy aborts upgrade without overwriting original', () {
    final bytes = legacy();
    File(store.path).writeAsBytesSync(bytes);
    final session = store.load()!.session();
    final copy = File('${store.path}.schema-2-${Digest.sha256Hex(bytes)}')..writeAsStringSync('unexpected synthetic bytes');
    expect(() => store.save(PersistedArchive.fromSession(session)), throwsA(isA<ContractError>()));
    expect(File(store.path).readAsBytesSync(), bytes);
    expect(copy.readAsStringSync(), 'unexpected synthetic bytes');
    expect(File(store.recoveryPath).existsSync(), isFalse);
  });

  test('a symlink cannot substitute for the retained schema copy', () {
    final bytes = legacy();
    File(store.path).writeAsBytesSync(bytes);
    final session = store.load()!.session();
    final original = File('${folder.path}/isolated-original')..writeAsBytesSync(bytes);
    Link('${store.path}.schema-2-${Digest.sha256Hex(bytes)}').createSync(original.path);
    expect(() => store.save(PersistedArchive.fromSession(session)), throwsA(isA<ContractError>()));
    expect(File(store.path).readAsBytesSync(), bytes);
    expect(original.readAsBytesSync(), bytes);
  });
}
