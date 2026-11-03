/// Experimental V3.1 family contracts. These types do not authenticate a user,
/// grant storage credentials, or change the existing Dad/Mom archive protocol.
library;

import 'errors.dart';
import 'text.dart';

enum FamilyRole { admin, contributor, viewer }

enum FamilyMemberStatus { active, revoked }

enum FamilyPermission {
  readRecords,
  createRecord,
  editRecord,
  manageMembers,
  issueInvitation,
  reviewJoinRequests,
}

/// An immutable identity. Names and relationship labels never form object keys.
class Family {
  final String id;
  final String name;

  Family({String? id, required String name})
    : id = familyStableID(id ?? newUuid()),
      name = familyDisplayText(name);
}

/// A subject supplied by a future authenticated gateway, not proof of identity.
/// The experimental reference service trusts this input only for contract tests.
class FamilyActor {
  final String subjectID;

  FamilyActor(String subjectID) : subjectID = familySubjectID(subjectID);
}

class FamilyMember {
  final String id;
  final String familyID;
  final String subjectID;
  final String displayName;
  final String relationshipLabel;
  final FamilyRole role;
  final FamilyMemberStatus status;

  FamilyMember({
    String? id,
    required String familyID,
    required String subjectID,
    required String displayName,
    required String relationshipLabel,
    required this.role,
    this.status = FamilyMemberStatus.active,
  }) : id = familyStableID(id ?? newUuid()),
       familyID = familyStableID(familyID),
       subjectID = familySubjectID(subjectID),
       displayName = familyDisplayText(displayName),
       relationshipLabel = familyDisplayText(relationshipLabel);

  FamilyMember revoked() => FamilyMember(
    id: id,
    familyID: familyID,
    subjectID: subjectID,
    displayName: displayName,
    relationshipLabel: relationshipLabel,
    role: role,
    status: FamilyMemberStatus.revoked,
  );
}

/// Conservative policy: contributors and admins edit their own records only.
/// Changing a display relationship (e.g. to “管理员”) never changes permission.
abstract final class FamilyPermissions {
  static bool allows({
    required FamilyMember? member,
    required String familyID,
    required FamilyPermission permission,
    String? recordOwnerMemberID,
  }) {
    if (member == null ||
        member.status != FamilyMemberStatus.active ||
        member.familyID != familyID.toUpperCase()) {
      return false;
    }
    return switch (permission) {
      FamilyPermission.readRecords => true,
      FamilyPermission.createRecord => member.role != FamilyRole.viewer,
      FamilyPermission.editRecord =>
        member.role != FamilyRole.viewer &&
            recordOwnerMemberID?.toUpperCase() == member.id,
      FamilyPermission.manageMembers ||
      FamilyPermission.issueInvitation ||
      FamilyPermission.reviewJoinRequests => member.role == FamilyRole.admin,
    };
  }
}

String familyStableID(String value) {
  if (!uuidPattern.hasMatch(value)) {
    throw const ContractError('family.id', 'Expected a stable UUID.');
  }
  return value.toUpperCase();
}

String familyDisplayText(String value, {int max = 80}) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > max ||
      normalized.runes.any((rune) => rune < 32 || rune == 127)) {
    throw const ContractError('family.text', 'Invalid family display value.');
  }
  return normalized;
}

/// Authentication subject values are opaque: never trim or case-fold them.
String familySubjectID(String value) {
  if (familyDisplayText(value, max: 256) != value) {
    throw const ContractError('family.subject', 'Invalid opaque subject.');
  }
  return value;
}
