import 'dart:async';
import 'dart:convert';

import 'package:jinbao_core/src/family.dart';
import 'package:jinbao_core/src/family_gateway_client.dart';
import 'package:jinbao_core/src/family_invitations.dart' show FamilyJoinStatus;
import 'package:test/test.dart';

const familyID = '10000000-0000-4000-8000-000000000001';
const memberID = '20000000-0000-4000-8000-000000000002';
const invitationID = '30000000-0000-4000-8000-000000000003';
const requestID = '40000000-0000-4000-8000-000000000004';
const deviceID = '50000000-0000-4000-8000-000000000005';
const opaqueToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const sessionToken = 'synthetic.session-token';
final gateway = Uri.parse('https://gateway.example.invalid');
final inviteUrl = gateway.replace(path: '/family-invitations/$opaqueToken');

Matcher failure(FamilyGatewayFailure expected) => throwsA(
  isA<FamilyGatewayException>().having((e) => e.failure, 'failure', expected),
);

Map<String, Object?> memberJson({String role = 'admin', String status = 'active'}) => {
  'id': memberID, 'familyID': familyID, 'subjectID': 'synthetic-admin',
  'displayName': '管理员', 'relationshipLabel': '家人',
  'role': role, 'status': status, 'deviceIDs': [deviceID],
};

Map<String, Object?> requestJson({String status = 'pending'}) => {
  'id': requestID, 'familyID': familyID, 'invitationID': invitationID,
  'subjectID': 'synthetic-applicant', 'displayName': '外婆',
  'relationshipLabel': '外婆', 'requestedRole': 'viewer', 'status': status,
  'approvedMemberID': status == 'approved' ? memberID : null,
  'deviceID': deviceID,
};

class FakeTransport implements FamilyGatewayTransport {
  final requests = <FamilyGatewayRequest>[];
  Future<FamilyGatewayResponse> Function(FamilyGatewayRequest)? handler;

  void respond(Object body, {int status = 200}) {
    handler = (_) async => FamilyGatewayResponse(
      statusCode: status, body: utf8.encode(jsonEncode(body)),
    );
  }

  @override
  Future<FamilyGatewayResponse> send(FamilyGatewayRequest request) {
    requests.add(request);
    return handler!(request);
  }
}

void main() {
  late FakeTransport transport;
  late FamilyGatewayClient client;
  late DateTime now;
  late String? token;

  setUp(() {
    transport = FakeTransport();
    now = DateTime.utc(2030, 1, 1);
    token = sessionToken;
    client = FamilyGatewayClient(
      origin: gateway, accessToken: () async => token,
      transport: transport, clock: () => now,
    );
  });

  Map<String, Object?> previewJson({String role = 'viewer'}) => {
    'familyID': familyID, 'familyName': '合成家庭', 'requestedRole': role,
    'expiresAt': now.add(const Duration(minutes: 10)).toIso8601String(),
  };

  test('configured gateway requires an HTTPS origin without credentials or path', () {
    for (final value in [
      'http://gateway.example.invalid', 'https://user:pass@gateway.example.invalid',
      'https://gateway.example.invalid/v1', 'https://gateway.example.invalid/?x=1',
      'https://gateway.example.invalid/#secret',
    ]) {
      expect(() => FamilyGatewayClient(origin: Uri.parse(value), accessToken: () async => token),
          failure(FamilyGatewayFailure.invalidGateway));
    }
  });

  test('no authenticated session means no request and no offline grant', () async {
    token = null;
    await expectLater(client.listFamilies(), failure(FamilyGatewayFailure.unauthenticated));
    token = 'unsafe\r\nInjected: token';
    await expectLater(client.listFamilies(), failure(FamilyGatewayFailure.unauthenticated));
    expect(transport.requests, isEmpty);
  });

  test('local metadata cache binding is stable, opaque, origin-scoped and refresh-sensitive', () async {
    final first = await client.localCacheSessionBinding();
    expect(first, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(await client.localCacheSessionBinding(), first);
    expect(first, isNot(contains(sessionToken)));
    final other = FamilyGatewayClient(origin: Uri.parse('https://other.example.invalid'),
      accessToken: () async => token, transport: transport);
    expect(await other.localCacheSessionBinding(), isNot(first));
    token = 'synthetic.refreshed-session';
    expect(await client.localCacheSessionBinding(), isNot(first));
    expect(transport.requests, isEmpty, reason: 'A local hash grants no remote access.');
  });

  test('missing invalid throwing and timed-out session brokers yield no cache binding', () async {
    for (final value in <String?>[null, '', 'unsafe\r\nsecret', 'token with spaces']) {
      token = value;
      expect(await client.localCacheSessionBinding(), isNull);
    }
    final throwing = FamilyGatewayClient(origin: gateway, transport: transport,
      accessToken: () async => throw Exception('Do not expose $sessionToken'));
    expect(await throwing.localCacheSessionBinding(), isNull);
    final delayed = Completer<String?>();
    final impatient = FamilyGatewayClient(origin: gateway, accessToken: () => delayed.future,
      transport: transport, timeout: const Duration(milliseconds: 1));
    expect(await impatient.localCacheSessionBinding(), isNull);
    delayed.complete(sessionToken);
    expect(transport.requests, isEmpty);
  });

  test('default transport rejects plaintext before opening a socket', () async {
    await expectLater(const IoFamilyGatewayTransport().send(FamilyGatewayRequest(
      method: 'GET', uri: Uri.parse('http://gateway.example.invalid/v1/families'),
      headers: {'Authorization': 'Bearer $sessionToken'}, body: const [],
    )), failure(FamilyGatewayFailure.invalidGateway));
  });

  test('scanned invitations cannot select a host, alter a path or add URL secrets', () async {
    for (final value in [
      'https:opaque',
      'http://gateway.example.invalid/family-invitations/$opaqueToken',
      'https://other.example.invalid/family-invitations/$opaqueToken',
      '$inviteUrl?tracking=1', '$inviteUrl#token', '$inviteUrl/',
      'https://gateway.example.invalid/family-invitations/%41${opaqueToken.substring(1)}',
      'https://user:secret@gateway.example.invalid/family-invitations/$opaqueToken',
      'https://gateway.example.invalid/v1/family-invitations/$opaqueToken',
    ]) {
      await expectLater(client.inspectInvitation(Uri.parse(value)),
          failure(FamilyGatewayFailure.invalidInvitation));
    }
    expect(transport.requests, isEmpty);
  });

  test('preview and explicit confirmation submit no actor or locally minted role', () async {
    transport.respond(previewJson());
    final preview = await client.inspectInvitation(inviteUrl);
    expect(preview.familyName, '合成家庭');
    expect(preview.requestedRole, FamilyRole.viewer);
    expect(transport.requests.single.headers['Authorization'], 'Bearer $sessionToken');
    expect(transport.requests.single.headers['Content-Length'], '0');
    expect(transport.requests.single.uri.path, '/v1/invitations/$opaqueToken');
    await expectLater(client.exchangeInvitation(preview, confirmed: false,
      displayName: '外婆', relationshipLabel: '外婆', deviceID: deviceID),
      failure(FamilyGatewayFailure.confirmationRequired));
    expect(transport.requests.length, 1);
    transport.respond(requestJson());
    final pending = await client.exchangeInvitation(preview, confirmed: true,
      displayName: '外婆', relationshipLabel: '外婆', deviceID: deviceID);
    expect(pending.status, FamilyJoinStatus.pending);
    expect(pending.approvedMemberID, isNull);
    final body = jsonDecode(utf8.decode(transport.requests.last.body)) as Map<String, dynamic>;
    expect(transport.requests.last.headers['Content-Length'], '${transport.requests.last.body.length}');
    expect(body['familyID'], familyID);
    expect(body['confirmed'], isTrue);
    expect(body['deviceID'], deviceID);
    expect(body, isNot(contains('subjectID')));
    expect(body, isNot(contains('actor')));
    expect(preview.toString(), isNot(contains(opaqueToken)));
    expect(transport.requests.last.toString(), isNot(contains(opaqueToken)));
    expect(transport.requests.last.toString(), isNot(contains(sessionToken)));
  });

  test('a valid preview expires before exchange including the exact boundary', () async {
    transport.respond(previewJson());
    final preview = await client.inspectInvitation(inviteUrl);
    now = preview.expiresAt;
    await expectLater(client.exchangeInvitation(preview, confirmed: true,
      displayName: '外婆', relationshipLabel: '外婆', deviceID: deviceID),
      failure(FamilyGatewayFailure.expired));
    expect(transport.requests.length, 1);
  });

  test('a preview cannot be exchanged through a different configured gateway', () async {
    transport.respond(previewJson());
    final preview = await client.inspectInvitation(inviteUrl);
    final other = FamilyGatewayClient(origin: Uri.parse('https://other.example.invalid'),
      accessToken: () async => sessionToken, transport: transport);
    await expectLater(other.exchangeInvitation(preview, confirmed: true,
      displayName: '外婆', relationshipLabel: '外婆', deviceID: deviceID),
      failure(FamilyGatewayFailure.invalidInvitation));
    expect(transport.requests.length, 1);
  });

  test('single-use, revoked and denied server outcomes remain failures', () async {
    transport.respond(previewJson());
    final preview = await client.inspectInvitation(inviteUrl);
    for (final code in [FamilyGatewayFailure.alreadyUsed, FamilyGatewayFailure.revoked,
      FamilyGatewayFailure.denied]) {
      transport.respond({'error': code.name}, status: 409);
      await expectLater(client.exchangeInvitation(preview, confirmed: true,
        displayName: '外婆', relationshipLabel: '外婆', deviceID: deviceID), failure(code));
    }
  });

  test('redirect and TLS/socket errors do not forward a session or expose invitation', () async {
    transport.respond({'url': 'https://attacker.example.invalid'}, status: 307);
    await expectLater(client.inspectInvitation(inviteUrl), failure(FamilyGatewayFailure.invalidResponse));
    expect(transport.requests.length, 1);
    transport.handler = (_) async => throw Exception('TLS failed at $inviteUrl $sessionToken');
    try {
      await client.inspectInvitation(inviteUrl);
      fail('Expected a redacted gateway failure');
    } on FamilyGatewayException catch (error) {
      expect(error.failure, FamilyGatewayFailure.unavailable);
      expect(error.toString(), isNot(contains(opaqueToken)));
      expect(error.toString(), isNot(contains(sessionToken)));
    }
  });

  test('timeout has an explicit failure and never grants cached membership', () async {
    final pending = Completer<FamilyGatewayResponse>();
    transport.handler = (_) => pending.future;
    final impatient = FamilyGatewayClient(origin: gateway, accessToken: () async => token,
      transport: transport, timeout: const Duration(milliseconds: 1));
    await expectLater(impatient.listFamilies(), failure(FamilyGatewayFailure.timeout));
    pending.complete(FamilyGatewayResponse(statusCode: 200, body: utf8.encode('{"families":[]}')));
  });

  test('malformed, oversized and admin-invitation responses fail closed', () async {
    transport.handler = (_) async => FamilyGatewayResponse(statusCode: 200, body: [0xff]);
    await expectLater(client.listFamilies(), failure(FamilyGatewayFailure.invalidResponse));
    transport.handler = (_) async => FamilyGatewayResponse(statusCode: 200,
      body: List.filled(1024 * 1024 + 1, 32));
    await expectLater(client.listFamilies(), failure(FamilyGatewayFailure.invalidResponse));
    transport.respond(previewJson(role: 'admin'));
    await expectLater(client.inspectInvitation(inviteUrl), failure(FamilyGatewayFailure.invalidResponse));
    final before = transport.requests.length;
    await expectLater(client.issueInvitation(familyID, FamilyRole.admin),
      failure(FamilyGatewayFailure.unsupportedRole));
    expect(transport.requests.length, before);
  });

  test('family membership comes from a consistent server snapshot, with device linkage', () async {
    transport.respond({'family': {'id': familyID, 'name': '合成家庭', 'primaryStorageID': null},
      'members': [memberJson()], 'currentMember': memberJson()});
    final snapshot = await client.getFamily(familyID);
    expect(snapshot.currentMember.role, FamilyRole.admin);
    expect(snapshot.currentMember.deviceIDs, [deviceID]);
    expect(snapshot.primaryStorageID, isNull);
    const otherFamily = '60000000-0000-4000-8000-000000000006';
    final misrouted = {...memberJson(), 'familyID': otherFamily};
    transport.respond({'family': {'id': otherFamily, 'name': '另一家庭'},
      'members': [misrouted], 'currentMember': misrouted});
    await expectLater(client.getFamily(familyID), failure(FamilyGatewayFailure.invalidResponse));
    transport.respond({'family': {'id': familyID, 'name': '合成家庭'},
      'members': [memberJson(role: 'viewer')], 'currentMember': memberJson()});
    await expectLater(client.getFamily(familyID), failure(FamilyGatewayFailure.invalidResponse));
    transport.respond({'error': 'revoked'}, status: 403);
    await expectLater(client.getFamily(familyID), failure(FamilyGatewayFailure.revoked));
  });

  test('approval, denial, polling and revocation use authenticated action endpoints', () async {
    transport.respond({'requests': [requestJson()]});
    expect((await client.pendingRequests(familyID)).single.status, FamilyJoinStatus.pending);
    expect((await client.ownRequests()).single.id, requestID);
    expect(transport.requests.last.uri.path, '/v1/requests');
    transport.respond(memberJson(role: 'viewer'));
    expect((await client.approve(requestID)).role, FamilyRole.viewer);
    expect(transport.requests.last.uri.path, '/v1/requests/$requestID/approve');
    expect(jsonDecode(utf8.decode(transport.requests.last.body)), <String, Object?>{});
    transport.respond(requestJson(status: 'denied'));
    expect((await client.deny(requestID)).status, FamilyJoinStatus.denied);
    expect((await client.requestStatus(requestID)).status, FamilyJoinStatus.denied);
    transport.respond({'ok': true});
    await client.revokeMember(familyID, memberID);
    await client.revokeInvitation(familyID, invitationID);
    expect(transport.requests.every((r) => r.headers['Authorization'] == 'Bearer $sessionToken'), isTrue);
  });
}
