import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinbao365/screens/family_space.dart';
import 'package:jinbao_core/jinbao_core.dart';

const _familyID = '00000000-0000-4000-8000-000000000001';
const _adminID = '00000000-0000-4000-8000-000000000002';
const _memberID = '00000000-0000-4000-8000-000000000003';
const _deviceID = '00000000-0000-4000-8000-000000000004';
const _requestID = '00000000-0000-4000-8000-000000000005';
const _invitationID = '00000000-0000-4000-8000-000000000006';
const _token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

Map<String, Object?> _member({bool admin = true, bool revoked = false}) => {
  'id': admin ? _adminID : _memberID,
  'familyID': _familyID,
  'subjectID': admin ? 'synthetic-admin' : 'synthetic-grandparent',
  'displayName': admin ? '家人管理员' : '乐乐外婆',
  'relationshipLabel': admin ? '爸爸' : '外婆',
  'role': admin ? 'admin' : 'viewer',
  'status': revoked ? 'revoked' : 'active',
  'deviceIDs': [_deviceID],
};

Map<String, Object?> _request({String status = 'pending'}) => {
  'id': _requestID,
  'familyID': _familyID,
  'invitationID': _invitationID,
  'subjectID': 'synthetic-grandparent',
  'displayName': '乐乐外婆',
  'relationshipLabel': '外婆',
  'requestedRole': 'viewer',
  'status': status,
  'approvedMemberID': status == 'approved' ? _memberID : null,
  'deviceID': _deviceID,
};

class _FamilyTransport implements FamilyGatewayTransport {
  bool hasFamily = false;
  bool admin = true;
  bool pending = false;
  bool ownPending = false;
  bool approved = false;
  bool revoked = false;
  bool fail = false;
  int createCalls = 0;
  int exchangeCalls = 0;
  int approveCalls = 0;
  int revokeCalls = 0;
  int invitationRevokeCalls = 0;
  String? issuedRole;
  Map<String, Object?>? exchangedBody;

  Map<String, Object?> snapshot() {
    final members = [_member(), if (approved || !admin) _member(admin: false, revoked: revoked)];
    return {
      'family': {'id': _familyID, 'name': '合成家庭'},
      'members': members,
      'currentMember': _member(admin: admin),
    };
  }

  @override
  Future<FamilyGatewayResponse> send(FamilyGatewayRequest request) async {
    if (fail) return _response({'error': 'unavailable'}, status: 503);
    final path = request.uri.path;
    final body = request.body.isEmpty
        ? <String, Object?>{}
        : Map<String, Object?>.from(jsonDecode(utf8.decode(request.body)) as Map);
    if (request.method == 'GET' && path == '/v1/families') {
      return _response({'families': [if (hasFamily) {'id': _familyID, 'name': '合成家庭'}]});
    }
    if (request.method == 'GET' && path == '/v1/requests') {
      return _response({'requests': [if (ownPending) _request()]});
    }
    if (request.method == 'POST' && path == '/v1/families') {
      createCalls++;
      hasFamily = true;
      return _response(snapshot());
    }
    if (request.method == 'GET' && path == '/v1/families/$_familyID') {
      return _response(snapshot());
    }
    if (request.method == 'GET' && path == '/v1/families/$_familyID/requests') {
      return _response({'requests': [if (pending) _request()]});
    }
    if (request.method == 'GET' && path == '/v1/invitations/$_token') {
      return _response({
        'familyID': _familyID,
        'familyName': '合成家庭',
        'requestedRole': 'viewer',
        'expiresAt': '2026-11-03T12:10:00.000Z',
      });
    }
    if (request.method == 'POST' && path == '/v1/invitations/$_token/requests') {
      exchangeCalls++;
      exchangedBody = body;
      ownPending = true;
      return _response(_request());
    }
    if (request.method == 'POST' && path == '/v1/families/$_familyID/invitations') {
      issuedRole = body['requestedRole'] as String;
      return _response({
        'id': _invitationID,
        'url': 'https://family.example/family-invitations/$_token',
        'requestedRole': issuedRole,
        'expiresAt': '2026-11-03T12:10:00.000Z',
      });
    }
    if (request.method == 'POST' && path == '/v1/requests/$_requestID/approve') {
      approveCalls++;
      approved = true;
      pending = false;
      return _response(_member(admin: false));
    }
    if (request.method == 'POST' && path == '/v1/families/$_familyID/members/$_memberID/revoke') {
      revokeCalls++;
      revoked = true;
      return _response({'ok': true});
    }
    if (request.method == 'POST' && path == '/v1/families/$_familyID/invitations/$_invitationID/revoke') {
      invitationRevokeCalls++;
      return _response({'ok': true});
    }
    return _response({'error': 'notFound'}, status: 404);
  }
}

FamilyGatewayResponse _response(Map<String, Object?> body, {int status = 200}) =>
    FamilyGatewayResponse(statusCode: status, body: utf8.encode(jsonEncode(body)));

FamilyGatewayClient _client(FamilyGatewayTransport transport) => FamilyGatewayClient(
  origin: Uri.parse('https://family.example'),
  accessToken: () async => 'synthetic-session',
  transport: transport,
  clock: () => DateTime.utc(2026, 11, 3, 12),
);

Widget _app({FamilyGatewayClient? client, VoidCallback? onTimeline}) => MaterialApp(
  home: FamilySpaceScreen(client: client, deviceID: _deviceID, onViewTimeline: onTimeline),
);

void main() {
  testWidgets('unconfigured service keeps local viewing available and grants no family', (tester) async {
    var viewed = false;
    await tester.pumpWidget(_app(onTimeline: () => viewed = true));
    expect(find.text('家庭授权服务尚未配置'), findsOneWidget);
    expect(find.text('邀请家人'), findsNothing);
    expect(find.text('创建家庭'), findsNothing);
    expect(find.text('扫码加入'), findsNothing);
    await tester.tap(find.text('查看时光'));
    expect(viewed, isTrue);
  });

  testWidgets('creating a family requires a valid explicit profile submission', (tester) async {
    final transport = _FamilyTransport();
    await tester.pumpWidget(_app(client: _client(transport)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建家庭'));
    await tester.pumpAndSettle();
    expect(transport.createCalls, 0);
    await tester.tap(find.text('创建').last);
    await tester.pumpAndSettle();
    expect(transport.createCalls, 0);
    await tester.enterText(find.widgetWithText(TextFormField, '家庭名称'), '合成家庭');
    await tester.enterText(find.widgetWithText(TextFormField, '我的昵称'), '家人管理员');
    await tester.enterText(find.widgetWithText(TextFormField, '关系称呼'), '爸爸');
    await tester.tap(find.text('创建').last);
    await tester.pumpAndSettle();
    expect(transport.createCalls, 1);
    expect(find.text('我的权限：管理员'), findsOneWidget);
    expect(find.text('家庭编号：$_familyID'), findsOneWidget);
  });

  testWidgets('invitation preview can be cancelled and explicit confirm produces pending only', (tester) async {
    final transport = _FamilyTransport();
    await tester.pumpWidget(_app(client: _client(transport)));
    await tester.pumpAndSettle();
    Future<void> openPreview() async {
      await tester.tap(find.text('使用邀请链接'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'https://family.example/family-invitations/$_token');
      await tester.tap(find.text('查看邀请'));
      await tester.pumpAndSettle();
    }
    await openPreview();
    expect(find.text('家庭：合成家庭'), findsOneWidget);
    expect(find.text('申请权限：查看者'), findsOneWidget);
    expect(transport.exchangeCalls, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(transport.exchangeCalls, 0);
    await openPreview();
    await tester.enterText(find.widgetWithText(TextFormField, '我的昵称'), '乐乐外婆');
    await tester.enterText(find.widgetWithText(TextFormField, '关系称呼'), '外婆');
    await tester.tap(find.text('确认并申请加入'));
    await tester.pumpAndSettle();
    expect(transport.exchangeCalls, 1);
    expect(transport.exchangedBody!['confirmed'], isTrue);
    expect(transport.exchangedBody!['requestedRole'], 'viewer');
    expect(find.text('等待管理员审批'), findsOneWidget);
    expect(find.text('我的权限：查看者'), findsNothing);
    expect(find.text('邀请家人'), findsNothing);
  });

  testWidgets('own pending request is restored from the authenticated server after reopening', (tester) async {
    final transport = _FamilyTransport()..ownPending = true;
    await tester.pumpWidget(_app(client: _client(transport)));
    await tester.pumpAndSettle();
    expect(find.text('等待管理员审批'), findsOneWidget);
    expect(find.text('查看申请状态'), findsOneWidget);
    expect(find.text('邀请家人'), findsNothing);
  });

  testWidgets('invitation shows the selected limited role and revokes only after confirmation', (tester) async {
    final transport = _FamilyTransport()..hasFamily = true;
    Uri? encoded;
    await tester.pumpWidget(MaterialApp(home: FamilySpaceScreen(
      client: _client(transport),
      deviceID: _deviceID,
      invitationCodeBuilder: (context, invitation) {
        encoded = invitation;
        return const SizedBox(width: 100, height: 100, child: Text('合成二维码'));
      },
    )));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('邀请家人'), 200);
    await tester.tap(find.text('邀请家人'));
    await tester.pumpAndSettle();
    expect(find.textContaining('管理员：'), findsNothing);
    await tester.tap(find.text('查看者：只看家庭记录'));
    await tester.pumpAndSettle();
    expect(transport.issuedRole, 'viewer');
    expect(encoded, Uri.parse('https://family.example/family-invitations/$_token'));
    expect(find.text('申请权限：查看者'), findsOneWidget);
    expect(find.text('合成二维码'), findsOneWidget);
    await tester.tap(find.text('撤销此邀请'));
    await tester.pumpAndSettle();
    expect(transport.invitationRevokeCalls, 0);
    await tester.tap(find.text('确认撤销'));
    await tester.pumpAndSettle();
    expect(transport.invitationRevokeCalls, 1);
    expect(find.text('合成二维码'), findsNothing);
  });

  testWidgets('admin approval and revocation both require confirmation', (tester) async {
    final transport = _FamilyTransport()..hasFamily = true..pending = true;
    await tester.pumpWidget(_app(client: _client(transport)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('批准'), 250);
    await tester.tap(find.text('批准'));
    await tester.pumpAndSettle();
    expect(transport.approveCalls, 0);
    await tester.tap(find.text('批准加入'));
    await tester.pumpAndSettle();
    expect(transport.approveCalls, 1);
    await tester.scrollUntilVisible(find.text('撤销成员权限'), 250);
    await tester.tap(find.text('撤销成员权限'));
    await tester.pumpAndSettle();
    expect(transport.revokeCalls, 0);
    expect(find.textContaining('已下载的照片无法追回'), findsOneWidget);
    await tester.tap(find.text('撤销权限'));
    await tester.pumpAndSettle();
    expect(transport.revokeCalls, 1);
    expect(find.text('查看者 · 已撤销'), findsOneWidget);
  });

  testWidgets('viewer membership hides admin actions and errors do not retain permissions', (tester) async {
    final transport = _FamilyTransport()..hasFamily = true..admin = false;
    await tester.pumpWidget(_app(client: _client(transport)));
    await tester.pumpAndSettle();
    expect(find.text('我的权限：查看者'), findsOneWidget);
    expect(find.text('邀请家人'), findsNothing);
    expect(find.text('待审批申请'), findsNothing);
    transport.fail = true;
    await tester.tap(find.byTooltip('刷新家庭'));
    await tester.pumpAndSettle();
    expect(find.text('我的权限：查看者'), findsNothing);
    expect(find.textContaining('暂时无法完成'), findsOneWidget);
    expect(find.textContaining('synthetic-session'), findsNothing);
  });

  testWidgets('changing authenticated clients discards late responses from the old session', (tester) async {
    final oldResponse = Completer<FamilyGatewayResponse>();
    final old = _client(_DelayedTransport(oldResponse.future));
    await tester.pumpWidget(_app(client: old));
    await tester.pump();
    final nextTransport = _FamilyTransport();
    await tester.pumpWidget(_app(client: _client(nextTransport)));
    await tester.pumpAndSettle();
    oldResponse.complete(_response({'families': [{'id': _familyID, 'name': '过期会话家庭'}]}));
    await tester.pumpAndSettle();
    expect(find.text('过期会话家庭'), findsNothing);
    expect(find.text('还没有加入家庭。创建一个家庭，或向管理员获取邀请。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _DelayedTransport implements FamilyGatewayTransport {
  final Future<FamilyGatewayResponse> response;
  _DelayedTransport(this.response);
  @override
  Future<FamilyGatewayResponse> send(FamilyGatewayRequest request) => response;
}
