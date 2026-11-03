/// Experimental invitation gateway contract and IN-MEMORY TEST REFERENCE ONLY.
///
/// This is not trusted authorization: it has no authenticated transport, durable
/// transaction store, real membership backend, credentials, or production wiring.
/// A real gateway must authenticate actors independently and transactionally
/// enforce expiry, single use, approvals, and revocation across all processes.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'family.dart';
import 'text.dart';

enum FamilyInvitationFailure {
  offline,
  denied,
  invalidInvitation,
  expired,
  alreadyUsed,
  revoked,
  confirmationRequired,
  alreadyMember,
  invalidState,
  unsupportedRole,
  lastAdmin,
}

class FamilyInvitationException implements Exception {
  final FamilyInvitationFailure failure;
  const FamilyInvitationException(this.failure);

  @override
  String toString() => 'FamilyInvitationException(${failure.name})';
}

enum FamilyJoinStatus { pending, approved, denied, revoked }

/// Only an HTTPS gateway URL and a random opaque token belong in the QR code.
/// It deliberately contains no family names, roles, passwords, or storage keys.
class FamilyInvitationQr {
  final Uri url;
  FamilyInvitationQr._(this.url);

  @override
  String toString() => 'FamilyInvitationQr(redacted)';
}

class IssuedFamilyInvitation {
  final String id;
  final FamilyInvitationQr qr;
  final FamilyRole requestedRole;
  final DateTime expiresAt;

  IssuedFamilyInvitation._(
    this.id,
    this.qr,
    this.requestedRole,
    this.expiresAt,
  );

  @override
  String toString() => 'IssuedFamilyInvitation($id, qr: redacted)';
}

/// Show familyName and requestedRole before explicit user confirmation.
/// Receiving this preview alone neither consumes the invitation nor grants access.
class FamilyJoinConfirmation {
  final String familyID;
  final String familyName;
  final FamilyRole requestedRole;
  final DateTime expiresAt;
  final String _tokenHash;

  FamilyJoinConfirmation._(Family family, _Invitation invitation)
    : familyID = family.id,
      familyName = family.name,
      requestedRole = invitation.role,
      expiresAt = invitation.expiresAt,
      _tokenHash = invitation.tokenHash;

  @override
  String toString() =>
      'FamilyJoinConfirmation($familyID, ${requestedRole.name})';
}

class FamilyJoinRequest {
  final String id;
  final String familyID;
  final String invitationID;
  final String subjectID;
  final String displayName;
  final String relationshipLabel;
  final FamilyRole requestedRole;
  final FamilyJoinStatus status;
  final String? approvedMemberID;

  FamilyJoinRequest._({
    required this.id,
    required this.familyID,
    required this.invitationID,
    required this.subjectID,
    required this.displayName,
    required this.relationshipLabel,
    required this.requestedRole,
    this.status = FamilyJoinStatus.pending,
    this.approvedMemberID,
  });

  FamilyJoinRequest _resolved(FamilyJoinStatus next, {String? memberID}) =>
      FamilyJoinRequest._(
        id: id,
        familyID: familyID,
        invitationID: invitationID,
        subjectID: subjectID,
        displayName: displayName,
        relationshipLabel: relationshipLabel,
        requestedRole: requestedRole,
        status: next,
        approvedMemberID: memberID,
      );
}

/// Future remote adapter boundary. None of these calls may authorize offline.
abstract interface class FamilyInvitationGateway {
  Future<IssuedFamilyInvitation> issue({
    required FamilyActor actor,
    required FamilyRole requestedRole,
    Duration validity = const Duration(minutes: 10),
  });
  Future<FamilyJoinConfirmation> inspect(Uri qrUrl);
  Future<FamilyJoinRequest> exchange({
    required FamilyActor applicant,
    required FamilyJoinConfirmation confirmation,
    required bool confirmed,
    required String displayName,
    required String relationshipLabel,
  });
  Future<FamilyMember> approve(FamilyActor admin, String requestID);
  Future<FamilyJoinRequest> deny(FamilyActor admin, String requestID);
  Future<void> revokeInvitation(FamilyActor admin, String invitationID);
  Future<void> revokeMember(FamilyActor admin, String memberID);
  Future<FamilyJoinRequest> requestStatus(FamilyActor actor, String requestID);
  Future<bool> allows(
    FamilyActor actor,
    FamilyPermission permission, {
    String? recordOwnerMemberID,
  });
}

/// Deterministic contract harness, NOT an app service or production gateway.
///
/// Mutations have no await point and are atomic within this one Dart isolate.
/// This is not a distributed concurrency guarantee or durable replay protection.
/// The host supplies availability and already authenticated subject identities;
/// neither is verified here. Restarting loses all invitations and memberships.
class ExperimentalInMemoryFamilyInvitationService
    implements FamilyInvitationGateway {
  final Family family;
  final Uri _gateway;
  final DateTime Function() _clock;
  final bool Function() _gatewayAvailable;
  final _random = Random.secure();
  final Map<String, FamilyMember> _members = {};
  final Map<String, _Invitation> _invitations = {};
  final Map<String, FamilyJoinRequest> _requests = {};

  ExperimentalInMemoryFamilyInvitationService({
    required this.family,
    required Uri gatewayOrigin,
    required FamilyMember initialAdmin,
    required this._gatewayAvailable,
    DateTime Function()? clock,
  }) : _gateway = _validateGateway(gatewayOrigin),
       _clock = clock ?? DateTime.now {
    if (initialAdmin.familyID != family.id ||
        initialAdmin.role != FamilyRole.admin ||
        initialAdmin.status != FamilyMemberStatus.active) {
      _fail(FamilyInvitationFailure.denied);
    }
    _members[initialAdmin.id] = initialAdmin;
  }

  @override
  Future<IssuedFamilyInvitation> issue({
    required FamilyActor actor,
    required FamilyRole requestedRole,
    Duration validity = const Duration(minutes: 10),
  }) => Future.sync(() {
    _requireAdmin(actor);
    // Admin promotion needs a separately reviewed, explicit gateway policy.
    if (requestedRole == FamilyRole.admin) {
      _fail(FamilyInvitationFailure.unsupportedRole);
    }
    if (validity <= Duration.zero || validity > const Duration(minutes: 10)) {
      _fail(FamilyInvitationFailure.invalidInvitation);
    }
    final token = base64UrlEncode(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    ).replaceAll('=', '');
    final invitation = _Invitation(
      id: newUuid(),
      tokenHash: _hash(token),
      role: requestedRole,
      expiresAt: _clock().toUtc().add(validity),
    );
    _invitations[invitation.tokenHash] = invitation;
    final qr = FamilyInvitationQr._(
      _gateway.replace(path: '/family-invitations/$token'),
    );
    return IssuedFamilyInvitation._(
      invitation.id,
      qr,
      invitation.role,
      invitation.expiresAt,
    );
  });

  @override
  Future<FamilyJoinConfirmation> inspect(Uri qrUrl) => Future.sync(() {
    _requireOnline();
    final invitation = _usableInvitation(_tokenHash(qrUrl));
    return FamilyJoinConfirmation._(family, invitation);
  });

  @override
  Future<FamilyJoinRequest> exchange({
    required FamilyActor applicant,
    required FamilyJoinConfirmation confirmation,
    required bool confirmed,
    required String displayName,
    required String relationshipLabel,
  }) => Future.sync(() {
    _requireOnline();
    if (!confirmed) _fail(FamilyInvitationFailure.confirmationRequired);
    final invitation = _usableInvitation(confirmation._tokenHash);
    if (confirmation.familyID != family.id ||
        confirmation.familyName != family.name ||
        confirmation.requestedRole != invitation.role ||
        confirmation.expiresAt != invitation.expiresAt) {
      _fail(FamilyInvitationFailure.invalidInvitation);
    }
    if (_member(applicant) != null) {
      _fail(FamilyInvitationFailure.alreadyMember);
    }
    final request = FamilyJoinRequest._(
      id: newUuid(),
      familyID: family.id,
      invitationID: invitation.id,
      subjectID: applicant.subjectID,
      displayName: familyDisplayText(displayName),
      relationshipLabel: familyDisplayText(relationshipLabel),
      requestedRole: invitation.role,
    );
    // Validate everything before these synchronous, single-isolate writes.
    invitation.requestID = request.id;
    _requests[request.id] = request;
    return request;
  });

  @override
  Future<FamilyMember> approve(
    FamilyActor admin,
    String requestID,
  ) => Future.sync(() {
    _requireAdmin(admin);
    final request = _pending(requestID);
    if (_member(FamilyActor(request.subjectID)) != null) {
      _fail(FamilyInvitationFailure.alreadyMember);
    }
    // Expiry limits token exchange. A consumed request awaits explicit admin
    // review even after expiry; revoking that invitation cancels this request.
    final member = FamilyMember(
      familyID: family.id,
      subjectID: request.subjectID,
      displayName: request.displayName,
      relationshipLabel: request.relationshipLabel,
      role: request.requestedRole,
    );
    _members[member.id] = member;
    _requests[request.id] = request._resolved(
      FamilyJoinStatus.approved,
      memberID: member.id,
    );
    return member;
  });

  @override
  Future<FamilyJoinRequest> deny(FamilyActor admin, String requestID) =>
      Future.sync(() {
        _requireAdmin(admin);
        final request = _pending(requestID)._resolved(FamilyJoinStatus.denied);
        _requests[request.id] = request;
        return request;
      });

  @override
  Future<void> revokeInvitation(FamilyActor admin, String invitationID) =>
      Future.sync(() {
        _requireAdmin(admin);
        final matches = _invitations.values.where(
          (item) => item.id == invitationID,
        );
        if (matches.isEmpty) _fail(FamilyInvitationFailure.invalidInvitation);
        final invitation = matches.single;
        invitation.revoked = true;
        final request = _requests[invitation.requestID];
        if (request?.status == FamilyJoinStatus.pending) {
          _requests[request!.id] = request._resolved(FamilyJoinStatus.revoked);
        }
        // Revoking a QR cannot silently revoke an already approved membership.
      });

  @override
  Future<void> revokeMember(FamilyActor admin, String memberID) =>
      Future.sync(() {
        _requireAdmin(admin);
        final member = _members[memberID];
        if (member == null || member.status != FamilyMemberStatus.active) {
          _fail(FamilyInvitationFailure.invalidState);
        }
        if (member.role == FamilyRole.admin &&
            _members.values
                    .where(
                      (item) =>
                          item.role == FamilyRole.admin &&
                          item.status == FamilyMemberStatus.active,
                    )
                    .length <=
                1) {
          _fail(FamilyInvitationFailure.lastAdmin);
        }
        _members[member.id] = member.revoked();
      });

  @override
  Future<FamilyJoinRequest> requestStatus(
    FamilyActor actor,
    String requestID,
  ) => Future.sync(() {
    _requireOnline();
    final request = _requests[requestID];
    if (request == null) _fail(FamilyInvitationFailure.invalidState);
    if (request.subjectID != actor.subjectID &&
        _member(actor)?.role != FamilyRole.admin) {
      _fail(FamilyInvitationFailure.denied);
    }
    return request;
  });

  @override
  Future<bool> allows(
    FamilyActor actor,
    FamilyPermission permission, {
    String? recordOwnerMemberID,
  }) => Future.sync(() {
    _requireOnline();
    return FamilyPermissions.allows(
      member: _member(actor),
      familyID: family.id,
      permission: permission,
      recordOwnerMemberID: recordOwnerMemberID,
    );
  });

  void _requireOnline() {
    if (!_gatewayAvailable()) _fail(FamilyInvitationFailure.offline);
  }

  FamilyMember? _member(FamilyActor actor) {
    final active = _members.values.where(
      (member) =>
          member.subjectID == actor.subjectID &&
          member.status == FamilyMemberStatus.active,
    );
    return active.isEmpty ? null : active.single;
  }

  void _requireAdmin(FamilyActor actor) {
    _requireOnline();
    if (_member(actor)?.role != FamilyRole.admin) {
      _fail(FamilyInvitationFailure.denied);
    }
  }

  FamilyJoinRequest _pending(String id) {
    final request = _requests[id];
    if (request == null || request.status != FamilyJoinStatus.pending) {
      _fail(FamilyInvitationFailure.invalidState);
    }
    return request;
  }

  _Invitation _usableInvitation(String tokenHash) {
    final invitation = _invitations[tokenHash];
    if (invitation == null) _fail(FamilyInvitationFailure.invalidInvitation);
    if (invitation.revoked) _fail(FamilyInvitationFailure.revoked);
    if (invitation.requestID != null) {
      _fail(FamilyInvitationFailure.alreadyUsed);
    }
    if (!_clock().toUtc().isBefore(invitation.expiresAt)) {
      _fail(FamilyInvitationFailure.expired);
    }
    return invitation;
  }

  String _tokenHash(Uri url) {
    if (url.scheme != 'https' ||
        url.origin != _gateway.origin ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        url.pathSegments.length != 2 ||
        url.pathSegments.first != 'family-invitations' ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(url.pathSegments.last) ||
        url.path != '/family-invitations/${url.pathSegments.last}') {
      _fail(FamilyInvitationFailure.invalidInvitation);
    }
    return _hash(url.pathSegments.last);
  }

  static Uri _validateGateway(Uri origin) {
    if (origin.scheme != 'https' ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        (origin.path.isNotEmpty && origin.path != '/')) {
      _fail(FamilyInvitationFailure.invalidInvitation);
    }
    return origin;
  }

  static String _hash(String token) =>
      sha256.convert(utf8.encode(token)).toString();
}

class _Invitation {
  final String id;
  final String tokenHash;
  final FamilyRole role;
  final DateTime expiresAt;
  String? requestID;
  bool revoked = false;

  _Invitation({
    required this.id,
    required this.tokenHash,
    required this.role,
    required this.expiresAt,
  });
}

Never _fail(FamilyInvitationFailure failure) =>
    throw FamilyInvitationException(failure);
