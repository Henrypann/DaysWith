import 'package:jinbao_core/src/errors.dart';
import 'package:jinbao_core/src/family.dart';
import 'package:test/test.dart';

void main() {
  final family = Family(name: '测试家庭');
  FamilyMember member(FamilyRole role, {String relationship = '妈妈'}) =>
      FamilyMember(
        familyID: family.id,
        subjectID: 'subject-${role.name}',
        displayName: '成员',
        relationshipLabel: relationship,
        role: role,
      );
  bool allowed(
    FamilyMember? actor,
    FamilyPermission permission, {
    String? owner,
    String? familyID,
  }) => FamilyPermissions.allows(
    member: actor,
    familyID: familyID ?? family.id,
    permission: permission,
    recordOwnerMemberID: owner,
  );

  test('stable UUIDs are independent of editable display labels', () {
    final original = member(FamilyRole.contributor);
    final renamed = FamilyMember(
      id: original.id.toLowerCase(),
      familyID: family.id.toLowerCase(),
      subjectID: original.subjectID,
      displayName: '重命名成员',
      relationshipLabel: '管理员',
      role: original.role,
    );
    expect(renamed.id, original.id);
    expect(renamed.familyID, family.id);
    expect(allowed(renamed, FamilyPermission.manageMembers), isFalse);
    expect(() => Family(name: '家庭', id: '妈妈'), throwsA(isA<ContractError>()));
  });

  test(
    'admin and contributor edit only their own records; viewer reads only',
    () {
      for (final role in FamilyRole.values) {
        final actor = member(role);
        expect(allowed(actor, FamilyPermission.readRecords), isTrue);
        expect(
          allowed(actor, FamilyPermission.createRecord),
          role != FamilyRole.viewer,
        );
        expect(
          allowed(actor, FamilyPermission.editRecord, owner: actor.id),
          role != FamilyRole.viewer,
        );
        expect(
          allowed(actor, FamilyPermission.editRecord, owner: member(role).id),
          isFalse,
        );
        expect(allowed(actor, FamilyPermission.editRecord), isFalse);
        for (final permission in [
          FamilyPermission.manageMembers,
          FamilyPermission.issueInvitation,
          FamilyPermission.reviewJoinRequests,
        ]) {
          expect(allowed(actor, permission), role == FamilyRole.admin);
        }
      }
    },
  );

  test('missing, revoked and foreign-family memberships fail closed', () {
    final admin = member(FamilyRole.admin);
    for (final permission in FamilyPermission.values) {
      expect(allowed(null, permission, owner: admin.id), isFalse);
      expect(allowed(admin.revoked(), permission, owner: admin.id), isFalse);
      expect(
        allowed(
          admin,
          permission,
          owner: admin.id,
          familyID: Family(name: '另一个家庭').id,
        ),
        isFalse,
      );
    }
    expect(admin.revoked().id, admin.id);
  });

  test(
    'opaque authenticated subjects retain case and reject trimmed aliases',
    () {
      expect(FamilyActor('Subject-A').subjectID, 'Subject-A');
      expect(FamilyActor('subject-a').subjectID, 'subject-a');
      expect(() => FamilyActor(' Subject-A '), throwsA(isA<ContractError>()));
    },
  );
}
