/// Authenticated HTTPS client for the separately deployed family gateway.
///
/// This client does not mint identities, roles, storage credentials or offline
/// grants. A host must supply its independently obtained, short-lived session.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'family.dart';
import 'family_invitations.dart' show FamilyJoinStatus;

enum FamilyGatewayFailure {
  invalidGateway,
  invalidInvitation,
  invalidRequest,
  invalidResponse,
  unauthenticated,
  denied,
  notFound,
  expired,
  alreadyUsed,
  revoked,
  confirmationRequired,
  alreadyMember,
  invalidState,
  unsupportedRole,
  lastAdmin,
  conflict,
  unavailable,
  timeout,
}

/// Deliberately excludes raw transport errors, response bodies and invitation URLs.
class FamilyGatewayException implements Exception {
  final FamilyGatewayFailure failure;
  const FamilyGatewayException(this.failure);

  @override
  String toString() => 'FamilyGatewayException(${failure.name})';
}

class FamilyGatewayRequest {
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final List<int> body;

  FamilyGatewayRequest({
    required this.method,
    required this.uri,
    required Map<String, String> headers,
    required List<int> body,
  }) : headers = Map.unmodifiable(headers),
       body = List.unmodifiable(body);

  @override
  String toString() => 'FamilyGatewayRequest($method, redacted)';
}

class FamilyGatewayResponse {
  final int statusCode;
  final List<int> body;

  FamilyGatewayResponse({required this.statusCode, required List<int> body})
    : body = List.unmodifiable(body);

  @override
  String toString() => 'FamilyGatewayResponse($statusCode, redacted)';
}

abstract interface class FamilyGatewayTransport {
  Future<FamilyGatewayResponse> send(FamilyGatewayRequest request);
}

/// Uses the platform trust store and never follows redirects carrying a bearer.
/// Each operation owns its client, so timing out closes that operation's socket.
class IoFamilyGatewayTransport implements FamilyGatewayTransport {
  final Duration timeout;
  final int maxResponseBytes;

  const IoFamilyGatewayTransport({
    this.timeout = const Duration(seconds: 20),
    this.maxResponseBytes = 1024 * 1024,
  });

  @override
  Future<FamilyGatewayResponse> send(FamilyGatewayRequest request) async {
    if (request.uri.scheme != 'https' || request.uri.host.isEmpty ||
        request.uri.userInfo.isNotEmpty) {
      throw const FamilyGatewayException(FamilyGatewayFailure.invalidGateway);
    }
    final client = HttpClient()..connectionTimeout = timeout;
    Future<FamilyGatewayResponse> perform() async {
      final outgoing = await client.openUrl(request.method, request.uri);
      outgoing.followRedirects = false;
      outgoing.maxRedirects = 0;
      request.headers.forEach(outgoing.headers.set);
      outgoing.add(request.body);
      final incoming = await outgoing.close();
      if (incoming.contentLength > maxResponseBytes) {
        throw const FamilyGatewayException(FamilyGatewayFailure.invalidResponse);
      }
      final bytes = <int>[];
      await for (final chunk in incoming) {
        if (bytes.length + chunk.length > maxResponseBytes) {
          throw const FamilyGatewayException(
            FamilyGatewayFailure.invalidResponse,
          );
        }
        bytes.addAll(chunk);
      }
      return FamilyGatewayResponse(statusCode: incoming.statusCode, body: bytes);
    }

    try {
      return await perform().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }
}

class GatewayMember {
  final FamilyMember member;
  final List<String> deviceIDs;

  GatewayMember._(this.member, List<String> deviceIDs)
    : deviceIDs = List.unmodifiable(deviceIDs);

  String get id => member.id;
  String get familyID => member.familyID;
  String get subjectID => member.subjectID;
  String get displayName => member.displayName;
  String get relationshipLabel => member.relationshipLabel;
  FamilyRole get role => member.role;
  FamilyMemberStatus get status => member.status;

  factory GatewayMember._fromJson(Object? value) {
    final json = _object(value);
    return GatewayMember._(
      FamilyMember(
        id: _string(json, 'id'),
        familyID: _string(json, 'familyID'),
        subjectID: _string(json, 'subjectID'),
        displayName: _string(json, 'displayName'),
        relationshipLabel: _string(json, 'relationshipLabel'),
        role: _role(json['role']),
        status: _memberStatus(json['status']),
      ),
      _list(json['deviceIDs']).map((id) => familyStableID(_text(id))).toList(),
    );
  }
}

class GatewayFamilySnapshot {
  final Family family;
  final String? primaryStorageID;
  final List<GatewayMember> members;
  final GatewayMember currentMember;

  GatewayFamilySnapshot._({
    required this.family,
    required this.primaryStorageID,
    required List<GatewayMember> members,
    required this.currentMember,
  }) : members = List.unmodifiable(members);

  factory GatewayFamilySnapshot._fromJson(Object? value) {
    final json = _object(value);
    final familyJson = _object(json['family']);
    final family = _family(familyJson);
    final members = _list(json['members']).map(GatewayMember._fromJson).toList();
    final current = GatewayMember._fromJson(json['currentMember']);
    if (current.familyID != family.id ||
        current.status != FamilyMemberStatus.active ||
        members.any((member) => member.familyID != family.id) ||
        members.map((member) => member.id).toSet().length != members.length ||
        !members.any(
          (member) => member.id == current.id &&
              member.subjectID == current.subjectID &&
              member.role == current.role && member.status == current.status,
        )) {
      _invalid();
    }
    final storageID = familyJson['primaryStorageID'];
    if (storageID != null && (storageID is! String || storageID.isEmpty)) {
      _invalid();
    }
    return GatewayFamilySnapshot._(
      family: family,
      primaryStorageID: storageID as String?,
      members: members,
      currentMember: current,
    );
  }
}

class GatewayInvitation {
  final String id;
  final Uri url;
  final FamilyRole requestedRole;
  final DateTime expiresAt;

  GatewayInvitation._({
    required this.id,
    required this.url,
    required this.requestedRole,
    required this.expiresAt,
  });

  @override
  String toString() => 'GatewayInvitation($id, redacted)';
}

/// An immutable server preview. The opaque token is private and is consumed only
/// by [FamilyGatewayClient.exchangeInvitation] after explicit confirmation.
class GatewayJoinPreview {
  final String familyID;
  final String familyName;
  final FamilyRole requestedRole;
  final DateTime expiresAt;
  final Uri _origin;
  final String _token;

  GatewayJoinPreview._({
    required this.familyID,
    required this.familyName,
    required this.requestedRole,
    required this.expiresAt,
    required Uri origin,
    required String token,
  }) : _origin = origin,
       _token = token;

  @override
  String toString() => 'GatewayJoinPreview($familyID, ${requestedRole.name})';
}

class GatewayJoinRequest {
  final String id;
  final String familyID;
  final String invitationID;
  final String subjectID;
  final String displayName;
  final String relationshipLabel;
  final FamilyRole requestedRole;
  final FamilyJoinStatus status;
  final String? approvedMemberID;
  final String deviceID;

  GatewayJoinRequest._({
    required this.id,
    required this.familyID,
    required this.invitationID,
    required this.subjectID,
    required this.displayName,
    required this.relationshipLabel,
    required this.requestedRole,
    required this.status,
    required this.approvedMemberID,
    required this.deviceID,
  });

  factory GatewayJoinRequest._fromJson(Object? value) {
    final json = _object(value);
    final status = _joinStatus(json['status']);
    final approved = json['approvedMemberID'];
    final memberID = approved == null ? null : familyStableID(_text(approved));
    if ((status == FamilyJoinStatus.approved) != (memberID != null)) _invalid();
    return GatewayJoinRequest._(
      id: familyStableID(_string(json, 'id')),
      familyID: familyStableID(_string(json, 'familyID')),
      invitationID: familyStableID(_string(json, 'invitationID')),
      subjectID: familySubjectID(_string(json, 'subjectID')),
      displayName: familyDisplayText(_string(json, 'displayName')),
      relationshipLabel: familyDisplayText(_string(json, 'relationshipLabel')),
      requestedRole: _invitedRole(json['requestedRole']),
      status: status,
      approvedMemberID: memberID,
      deviceID: familyStableID(_string(json, 'deviceID')),
    );
  }
}

class FamilyGatewayClient {
  final Uri origin;
  final Future<String?> Function() _accessToken;
  final FamilyGatewayTransport _transport;
  final Duration timeout;
  final DateTime Function() _clock;

  FamilyGatewayClient({
    required Uri origin,
    required Future<String?> Function() accessToken,
    FamilyGatewayTransport? transport,
    this.timeout = const Duration(seconds: 20),
    DateTime Function()? clock,
  }) : origin = _gatewayOrigin(origin),
       _accessToken = accessToken,
       _transport = transport ?? IoFamilyGatewayTransport(timeout: timeout),
       _clock = clock ?? DateTime.now {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout');
    }
  }

  Future<List<Family>> listFamilies() => _perform('GET', '/v1/families', (json) {
    final families = _list(json['families']).map((item) => _family(_object(item))).toList();
    if (families.map((family) => family.id).toSet().length != families.length) _invalid();
    return List.unmodifiable(families);
  });

  Future<GatewayFamilySnapshot> createFamily({
    required String name,
    required String displayName,
    required String relationshipLabel,
    required String deviceID,
  }) async => _perform(
    'POST',
    '/v1/families',
    GatewayFamilySnapshot._fromJson,
    body: {
      'name': familyDisplayText(name),
      'displayName': familyDisplayText(displayName),
      'relationshipLabel': familyDisplayText(relationshipLabel),
      'deviceID': familyStableID(deviceID),
    },
  );

  Future<GatewayFamilySnapshot> getFamily(String familyID) {
    final id = familyStableID(familyID);
    return _perform('GET', '/v1/families/$id', (json) {
      final snapshot = GatewayFamilySnapshot._fromJson(json);
      if (snapshot.family.id != id) _invalid();
      return snapshot;
    });
  }

  Future<GatewayInvitation> issueInvitation(
    String familyID,
    FamilyRole requestedRole,
  ) async {
    if (requestedRole == FamilyRole.admin) {
      throw const FamilyGatewayException(FamilyGatewayFailure.unsupportedRole);
    }
    return _perform(
      'POST', '/v1/families/${familyStableID(familyID)}/invitations',
      (json) {
        final url = Uri.tryParse(_string(json, 'url'));
        if (url == null) _invalid();
        _invitationToken(url);
        final role = _invitedRole(json['requestedRole']);
        if (role != requestedRole) _invalid();
        return GatewayInvitation._(
          id: familyStableID(_string(json, 'id')),
          url: url,
          requestedRole: role,
          expiresAt: _expiry(json['expiresAt']),
        );
      },
      body: {'requestedRole': requestedRole.name},
    );
  }

  Future<GatewayJoinPreview> inspectInvitation(Uri qrUrl) async {
    final token = _invitationToken(qrUrl);
    return _perform('GET', '/v1/invitations/$token', (json) => GatewayJoinPreview._(
      familyID: familyStableID(_string(json, 'familyID')),
      familyName: familyDisplayText(_string(json, 'familyName')),
      requestedRole: _invitedRole(json['requestedRole']),
      expiresAt: _expiry(json['expiresAt']),
      origin: origin,
      token: token,
    ));
  }

  Future<GatewayJoinRequest> exchangeInvitation(
    GatewayJoinPreview preview, {
    required bool confirmed,
    required String displayName,
    required String relationshipLabel,
    required String deviceID,
  }) async {
    if (!confirmed) {
      throw const FamilyGatewayException(FamilyGatewayFailure.confirmationRequired);
    }
    if (preview._origin != origin) {
      throw const FamilyGatewayException(FamilyGatewayFailure.invalidInvitation);
    }
    if (!_clock().toUtc().isBefore(preview.expiresAt)) {
      throw const FamilyGatewayException(FamilyGatewayFailure.expired);
    }
    return _perform(
      'POST', '/v1/invitations/${preview._token}/requests',
      (json) {
        final request = GatewayJoinRequest._fromJson(json);
        if (request.familyID != preview.familyID ||
            request.requestedRole != preview.requestedRole ||
            request.status != FamilyJoinStatus.pending) _invalid();
        return request;
      },
      body: {
        'confirmed': true,
        'familyID': preview.familyID,
        'familyName': preview.familyName,
        'requestedRole': preview.requestedRole.name,
        'expiresAt': preview.expiresAt.toIso8601String(),
        'displayName': familyDisplayText(displayName),
        'relationshipLabel': familyDisplayText(relationshipLabel),
        'deviceID': familyStableID(deviceID),
      },
    );
  }

  Future<List<GatewayJoinRequest>> pendingRequests(String familyID) {
    final id = familyStableID(familyID);
    return _perform('GET', '/v1/families/$id/requests', (json) {
      final requests = _list(json['requests']).map(GatewayJoinRequest._fromJson).toList();
      if (requests.any((r) => r.familyID != id || r.status != FamilyJoinStatus.pending)) {
        _invalid();
      }
      return List.unmodifiable(requests);
    });
  }

  /// Refreshes pending/processed applications after restart without persisting
  /// invitation tokens. The server derives the subject from the bearer session.
  Future<List<GatewayJoinRequest>> ownRequests() =>
      _perform('GET', '/v1/requests', (json) => List.unmodifiable(
        _list(json['requests']).map(GatewayJoinRequest._fromJson),
      ));

  Future<GatewayJoinRequest> requestStatus(String requestID) {
    final id = familyStableID(requestID);
    return _perform('GET', '/v1/requests/$id', (json) {
      final request = GatewayJoinRequest._fromJson(json);
      if (request.id != id) _invalid();
      return request;
    });
  }

  Future<GatewayMember> approve(String requestID) => _perform(
    'POST', '/v1/requests/${familyStableID(requestID)}/approve',
    GatewayMember._fromJson,
  );

  Future<GatewayJoinRequest> deny(String requestID) {
    final id = familyStableID(requestID);
    return _perform('POST', '/v1/requests/$id/deny', (json) {
      final request = GatewayJoinRequest._fromJson(json);
      if (request.id != id || request.status != FamilyJoinStatus.denied) _invalid();
      return request;
    });
  }

  Future<void> revokeInvitation(String familyID, String invitationID) =>
      _perform('POST', '/v1/families/${familyStableID(familyID)}/invitations/${familyStableID(invitationID)}/revoke', _ack);

  Future<void> revokeMember(String familyID, String memberID) =>
      _perform('POST', '/v1/families/${familyStableID(familyID)}/members/${familyStableID(memberID)}/revoke', _ack);

  String _invitationToken(Uri url) {
    if (url.scheme != 'https' || url.host.isEmpty || url.origin != origin.origin ||
        url.userInfo.isNotEmpty || url.hasQuery || url.hasFragment ||
        url.pathSegments.length != 2 || url.pathSegments.first != 'family-invitations' ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(url.pathSegments.last) ||
        url.path != '/family-invitations/${url.pathSegments.last}') {
      throw const FamilyGatewayException(FamilyGatewayFailure.invalidInvitation);
    }
    return url.pathSegments.last;
  }

  Future<T> _perform<T>(
    String method,
    String path,
    T Function(Map<String, Object?>) decode, {
    Map<String, Object?>? body,
  }) async {
    try {
      final token = await _accessToken().timeout(timeout);
      if (token == null || token.isEmpty || token.length > 8192 ||
          !RegExp(r'^[A-Za-z0-9\-._~+/]+=*$').hasMatch(token)) {
        throw const FamilyGatewayException(FamilyGatewayFailure.unauthenticated);
      }
      final bytes = body == null && method == 'GET'
          ? <int>[] : utf8.encode(jsonEncode(body ?? <String, Object?>{}));
      if (bytes.length > 64 * 1024) {
        throw const FamilyGatewayException(FamilyGatewayFailure.invalidRequest);
      }
      final response = await _transport.send(FamilyGatewayRequest(
        method: method,
        uri: origin.replace(path: path),
        headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json',
          'Content-Type': 'application/json'},
        body: bytes,
      )).timeout(timeout);
      if (response.body.length > 1024 * 1024) _invalid();
      // Redirects, authentication failures and server faults cannot become a
      // cached success, even if their response contains success-shaped JSON.
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (response.statusCode == 401) {
          throw const FamilyGatewayException(FamilyGatewayFailure.unauthenticated);
        }
        if (response.statusCode >= 300 && response.statusCode < 400) _invalid();
        Map<String, Object?> errorJson;
        try {
          errorJson = _object(jsonDecode(utf8.decode(response.body)));
        } catch (_) {
          throw const FamilyGatewayException(FamilyGatewayFailure.unavailable);
        }
        final code = errorJson['error'];
        final matches = FamilyGatewayFailure.values.where((failure) => failure.name == code);
        throw FamilyGatewayException(matches.isEmpty ? FamilyGatewayFailure.unavailable : matches.first);
      }
      try {
        return decode(_object(jsonDecode(utf8.decode(response.body))));
      } on FamilyGatewayException {
        rethrow;
      } catch (_) {
        _invalid();
      }
    } on FamilyGatewayException {
      rethrow;
    } on TimeoutException {
      throw const FamilyGatewayException(FamilyGatewayFailure.timeout);
    } catch (_) {
      // Socket and TLS errors can include the full requested invitation URL.
      throw const FamilyGatewayException(FamilyGatewayFailure.unavailable);
    }
  }
}

Uri _gatewayOrigin(Uri value) {
  if (value.scheme != 'https' || value.host.isEmpty || value.userInfo.isNotEmpty ||
      value.hasQuery || value.hasFragment || (value.path.isNotEmpty && value.path != '/')) {
    throw const FamilyGatewayException(FamilyGatewayFailure.invalidGateway);
  }
  return Uri.parse(value.origin);
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) _invalid();
  return Map<String, Object?>.from(value);
}

List<Object?> _list(Object? value) {
  if (value is! List || value.length > 2000) _invalid();
  return List<Object?>.from(value);
}

String _text(Object? value) {
  if (value is! String || value.isEmpty || value.length > 8192) _invalid();
  return value;
}

String _string(Map<String, Object?> json, String key) => _text(json[key]);

Family _family(Map<String, Object?> json) =>
    Family(id: _string(json, 'id'), name: _string(json, 'name'));

FamilyRole _role(Object? value) {
  for (final role in FamilyRole.values) { if (role.name == value) return role; }
  _invalid();
}

FamilyRole _invitedRole(Object? value) {
  final role = _role(value);
  if (role == FamilyRole.admin) _invalid();
  return role;
}

FamilyMemberStatus _memberStatus(Object? value) {
  for (final status in FamilyMemberStatus.values) { if (status.name == value) return status; }
  _invalid();
}

FamilyJoinStatus _joinStatus(Object? value) {
  for (final status in FamilyJoinStatus.values) { if (status.name == value) return status; }
  _invalid();
}

DateTime _expiry(Object? value) {
  final text = _text(value);
  final result = DateTime.tryParse(text);
  if (!text.endsWith('Z') || result == null || !result.isUtc) _invalid();
  return result;
}

void _ack(Map<String, Object?> json) { if (json['ok'] != true) _invalid(); }

Never _invalid() =>
    throw const FamilyGatewayException(FamilyGatewayFailure.invalidResponse);
