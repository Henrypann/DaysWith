import 'package:jinbao_core/src/family.dart';
import 'package:jinbao_core/src/family_invitations.dart';
import 'package:test/test.dart';

Matcher fails(FamilyInvitationFailure failure) => throwsA(
  isA<FamilyInvitationException>().having(
    (error) => error.failure,
    'failure',
    failure,
  ),
);

void main() {
  late DateTime now;
  late bool online;
  late Family family;
  late FamilyMember adminMember;
  late FamilyActor admin;
  late ExperimentalInMemoryFamilyInvitationService service;

  setUp(() {
    now = DateTime.utc(2030, 1, 1);
    online = true;
    family = Family(name: '测试家庭');
    admin = FamilyActor('authenticated-admin-subject');
    adminMember = FamilyMember(
      familyID: family.id,
      subjectID: admin.subjectID,
      displayName: '管理员',
      relationshipLabel: '爸爸',
      role: FamilyRole.admin,
    );
    service = ExperimentalInMemoryFamilyInvitationService(
      family: family,
      gatewayOrigin: Uri.parse('https://gateway.example.invalid'),
      initialAdmin: adminMember,
      gatewayAvailable: () => online,
      clock: () => now,
    );
  });

  Future<IssuedFamilyInvitation> issue([
    FamilyRole role = FamilyRole.contributor,
  ]) => service.issue(actor: admin, requestedRole: role);

  Future<FamilyJoinRequest> join(
    IssuedFamilyInvitation invitation, {
    String subject = 'applicant',
    bool confirmed = true,
  }) async {
    final confirmation = await service.inspect(invitation.qr.url);
    return service.exchange(
      applicant: FamilyActor(subject),
      confirmation: confirmation,
      confirmed: confirmed,
      displayName: '新成员',
      relationshipLabel: '妈妈',
    );
  }

  test('QR is only pinned HTTPS gateway URL and opaque token; diagnostics redact it', () async {
    final invitation = await issue();
    final url = invitation.qr.url;
    expect(url.scheme, 'https');
    expect(url.origin, 'https://gateway.example.invalid');
    expect(url.pathSegments.first, 'family-invitations');
    expect(url.pathSegments.last.length, 43);
    expect(url.hasQuery, isFalse);
    expect(url.hasFragment, isFalse);
    expect(url.toString(), isNot(contains(family.id)));
    expect(url.toString(), isNot(contains(family.name)));
    expect(invitation.toString(), isNot(contains(url.pathSegments.last)));
    expect(invitation.qr.toString(), isNot(contains(url.pathSegments.last)));
    expect(invitation.expiresAt, now.add(const Duration(minutes: 10)));
    final second = await issue();
    expect(second.qr.url, isNot(url));
  });

  test('preview includes family and requested role; explicit confirmation does not grant access', () async {
    final invitation = await issue();
    final preview = await service.inspect(invitation.qr.url);
    expect(preview.familyID, family.id);
    expect(preview.familyName, family.name);
    expect(preview.requestedRole, FamilyRole.contributor);
    await expectLater(
      join(invitation, confirmed: false),
      fails(FamilyInvitationFailure.confirmationRequired),
    );
    final request = await join(invitation);
    expect(request.status, FamilyJoinStatus.pending);
    expect(
      await service.allows(
        FamilyActor('applicant'),
        FamilyPermission.readRecords,
      ),
      isFalse,
    );
    final member = await service.approve(admin, request.id);
    expect(member.role, FamilyRole.contributor);
    expect(
      await service.allows(
        FamilyActor('applicant'),
        FamilyPermission.editRecord,
        recordOwnerMemberID: member.id,
      ),
      isTrue,
    );
    expect(
      await service.allows(
        FamilyActor('applicant'),
        FamilyPermission.editRecord,
        recordOwnerMemberID: adminMember.id,
      ),
      isFalse,
    );
    expect(
      (await service.requestStatus(
        FamilyActor('applicant'),
        request.id,
      )).approvedMemberID,
      member.id,
    );
  });

  test('expiry is enforced at exchange, including exact boundary after a valid preview', () async {
    final invitation = await issue();
    final preview = await service.inspect(invitation.qr.url);
    now = invitation.expiresAt;
    await expectLater(
      service.exchange(
        applicant: FamilyActor('applicant'),
        confirmation: preview,
        confirmed: true,
        displayName: '成员',
        relationshipLabel: '妈妈',
      ),
      fails(FamilyInvitationFailure.expired),
    );
    await expectLater(
      service.inspect(invitation.qr.url),
      fails(FamilyInvitationFailure.expired),
    );
    await expectLater(
      service.issue(
        actor: admin,
        requestedRole: FamilyRole.viewer,
        validity: const Duration(minutes: 11),
      ),
      fails(FamilyInvitationFailure.invalidInvitation),
    );
    await expectLater(
      service.issue(
        actor: admin,
        requestedRole: FamilyRole.viewer,
        validity: Duration.zero,
      ),
      fails(FamilyInvitationFailure.invalidInvitation),
    );
  });

  test('simultaneous exchanges consume the token exactly once', () async {
    final invitation = await issue();
    final preview = await service.inspect(invitation.qr.url);
    Future<Object> attempt(String subject) async {
      try {
        return await service.exchange(
          applicant: FamilyActor(subject),
          confirmation: preview,
          confirmed: true,
          displayName: subject,
          relationshipLabel: '家人',
        );
      } on FamilyInvitationException catch (error) {
        return error.failure;
      }
    }

    final outcomes = await Future.wait([attempt('first'), attempt('second')]);
    expect(outcomes.whereType<FamilyJoinRequest>().length, 1);
    expect(
      outcomes.whereType<FamilyInvitationFailure>().single,
      FamilyInvitationFailure.alreadyUsed,
    );
    await expectLater(
      service.inspect(invitation.qr.url),
      fails(FamilyInvitationFailure.alreadyUsed),
    );
  });

  test('simultaneous admin approvals create one membership and cannot approve twice', () async {
    final request = await join(await issue());
    Future<Object> approve() async {
      try {
        return await service.approve(admin, request.id);
      } on FamilyInvitationException catch (error) {
        return error.failure;
      }
    }

    final outcomes = await Future.wait([approve(), approve()]);
    expect(outcomes.whereType<FamilyMember>().length, 1);
    expect(
      outcomes.whereType<FamilyInvitationFailure>().single,
      FamilyInvitationFailure.invalidState,
    );
    await expectLater(
      service.deny(admin, request.id),
      fails(FamilyInvitationFailure.invalidState),
    );
  });

  test('denial consumes the invitation and grants no membership', () async {
    final invitation = await issue();
    final request = await join(invitation);
    expect(
      (await service.deny(admin, request.id)).status,
      FamilyJoinStatus.denied,
    );
    await expectLater(
      join(invitation),
      fails(FamilyInvitationFailure.alreadyUsed),
    );
    await expectLater(
      service.approve(admin, request.id),
      fails(FamilyInvitationFailure.invalidState),
    );
    expect(
      await service.allows(
        FamilyActor('applicant'),
        FamilyPermission.readRecords,
      ),
      isFalse,
    );
  });

  test(
    'revoking a QR invalidates previews and cancels pending approval',
    () async {
      final invitation = await issue();
      final preview = await service.inspect(invitation.qr.url);
      await service.revokeInvitation(admin, invitation.id);
      await expectLater(
        service.exchange(
          applicant: FamilyActor('applicant'),
          confirmation: preview,
          confirmed: true,
          displayName: '成员',
          relationshipLabel: '妈妈',
        ),
        fails(FamilyInvitationFailure.revoked),
      );
      final pendingInvitation = await issue();
      final pending = await join(pendingInvitation);
      await service.revokeInvitation(admin, pendingInvitation.id);
      expect(
        (await service.requestStatus(admin, pending.id)).status,
        FamilyJoinStatus.revoked,
      );
      await expectLater(
        service.approve(admin, pending.id),
        fails(FamilyInvitationFailure.invalidState),
      );
    },
  );

  test('member revocation removes access without changing stable IDs or deleting records', () async {
    final invitation = await issue(FamilyRole.viewer);
    final member = await service.approve(admin, (await join(invitation)).id);
    final actor = FamilyActor('applicant');
    expect(await service.allows(actor, FamilyPermission.readRecords), isTrue);
    expect(await service.allows(actor, FamilyPermission.createRecord), isFalse);
    await service.revokeInvitation(admin, invitation.id);
    expect(await service.allows(actor, FamilyPermission.readRecords), isTrue);
    await service.revokeMember(admin, member.id);
    expect(await service.allows(actor, FamilyPermission.readRecords), isFalse);
    await expectLater(
      service.issue(actor: actor, requestedRole: FamilyRole.viewer),
      fails(FamilyInvitationFailure.denied),
    );
    await expectLater(
      service.revokeMember(admin, adminMember.id),
      fails(FamilyInvitationFailure.lastAdmin),
    );
  });

  test('offline issue, inspect, exchange, approval, revoke and access all fail closed', () async {
    final invitation = await issue();
    final preview = await service.inspect(invitation.qr.url);
    final pending = await join(await issue(), subject: 'pending');
    online = false;
    await expectLater(issue(), fails(FamilyInvitationFailure.offline));
    await expectLater(
      service.inspect(invitation.qr.url),
      fails(FamilyInvitationFailure.offline),
    );
    await expectLater(
      service.exchange(
        applicant: FamilyActor('applicant'),
        confirmation: preview,
        confirmed: true,
        displayName: '成员',
        relationshipLabel: '妈妈',
      ),
      fails(FamilyInvitationFailure.offline),
    );
    await expectLater(
      service.approve(admin, pending.id),
      fails(FamilyInvitationFailure.offline),
    );
    await expectLater(
      service.deny(admin, pending.id),
      fails(FamilyInvitationFailure.offline),
    );
    await expectLater(
      service.revokeInvitation(admin, invitation.id),
      fails(FamilyInvitationFailure.offline),
    );
    await expectLater(
      service.revokeMember(admin, adminMember.id),
      fails(FamilyInvitationFailure.offline),
    );
    await expectLater(
      service.requestStatus(admin, pending.id),
      fails(FamilyInvitationFailure.offline),
    );
    await expectLater(
      service.allows(admin, FamilyPermission.readRecords),
      fails(FamilyInvitationFailure.offline),
    );
    online = true;
    expect(
      (await service.approve(admin, pending.id)).role,
      FamilyRole.contributor,
    );
    expect((await join(invitation)).status, FamilyJoinStatus.pending);
  });

  test('untrusted endpoints, credential-bearing QR values and malformed tokens fail', () async {
    final invitation = await issue();
    for (final url in [
      invitation.qr.url.replace(scheme: 'http'),
      invitation.qr.url.replace(host: 'attacker.invalid'),
      invitation.qr.url.replace(userInfo: 'password'),
      invitation.qr.url.replace(query: 'SecretKey=never-accept'),
      invitation.qr.url.replace(fragment: 'password'),
      invitation.qr.url.replace(path: '/family-invitations/short'),
      Uri.parse('/relative'),
    ]) {
      await expectLater(
        service.inspect(url),
        fails(FamilyInvitationFailure.invalidInvitation),
      );
    }
    expect(
      () => ExperimentalInMemoryFamilyInvitationService(
        family: family,
        gatewayOrigin: Uri.parse('http://gateway.invalid'),
        initialAdmin: adminMember,
        gatewayAvailable: () => true,
      ),
      throwsA(isA<FamilyInvitationException>()),
    );
  });

  test('only active admin reviews requests; no QR admin escalation or applicant self-approval', () async {
    await expectLater(
      issue(FamilyRole.admin),
      fails(FamilyInvitationFailure.unsupportedRole),
    );
    final request = await join(await issue());
    final applicant = FamilyActor('applicant');
    await expectLater(
      service.approve(applicant, request.id),
      fails(FamilyInvitationFailure.denied),
    );
    await expectLater(
      service.deny(applicant, request.id),
      fails(FamilyInvitationFailure.denied),
    );
    await expectLater(
      service.requestStatus(FamilyActor('stranger'), request.id),
      fails(FamilyInvitationFailure.denied),
    );
    final member = await service.approve(admin, request.id);
    await expectLater(
      service.revokeMember(applicant, member.id),
      fails(FamilyInvitationFailure.denied),
    );
    await expectLater(
      service.issue(actor: applicant, requestedRole: FamilyRole.viewer),
      fails(FamilyInvitationFailure.denied),
    );
  });
}
