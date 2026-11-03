"""Persistent, fail-closed Family Gateway application (Python standard library).

No default identity provider, credential issuer, listener, or storage backend is
installed. The host must terminate HTTPS and supply a verified bearer-subject
function. SyntheticHmacVerifier is deliberately opt-in for isolated tests only.
"""
from __future__ import annotations

import base64
import contextlib
import hashlib
import hmac
import json
import os
import stat
import re
import secrets
import sqlite3
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable
from urllib.parse import urlsplit


class GatewayError(Exception):
    def __init__(self, code: str, status: int = 400):
        self.code, self.status = code, status
        super().__init__(code)


def _fail(code, status=400):
    raise GatewayError(code, status)


def _text(value, maximum=80):
    from .archives import _DART_WS
    if not isinstance(value, str):
        _fail('invalidRequest')
    normalized = value.strip(_DART_WS)
    try:
        length = len(normalized.encode('utf-16-le')) // 2
    except UnicodeError:
        _fail('invalidRequest')
    if not normalized or length > maximum or any(ord(c) < 32 or ord(c) == 127 for c in value):
        _fail('invalidRequest')
    return normalized


def _subject(value):
    if _text(value, 256) != value:
        _fail('unauthenticated', 401)
    return value


def _id(value=None):
    if value is None:
        return str(uuid.uuid4()).upper()
    if not isinstance(value, str) or not re.fullmatch(
            r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', value):
        _fail('invalidRequest')
    return value.upper()


def _iso(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat().replace('+00:00', 'Z')


def _hash(token):
    return hashlib.sha256(token.encode('ascii')).hexdigest()


def _b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')


def _unb64(value):
    if not re.fullmatch(r'[A-Za-z0-9_-]+', value):
        _fail('unauthenticated', 401)
    return base64.urlsafe_b64decode(value + '=' * (-len(value) % 4))


class _LimitedInput:
    """Expose EOF at HTTP Content-Length without probing a persistent socket."""
    def __init__(self, source, length):
        self.source, self.remaining = source, length

    def read(self, length=-1):
        if self.remaining == 0:
            return b''
        amount = self.remaining if length < 0 else min(length, self.remaining)
        data = self.source.read(amount)
        if not isinstance(data, bytes) or len(data) > amount:
            _fail('invalidRequest')
        self.remaining -= len(data)
        return data


def _request_length(environ, maximum=None):
    if environ.get('HTTP_TRANSFER_ENCODING') or environ.get('TRANSFER_ENCODING'):
        _fail('invalidRequest')
    raw = environ.get('CONTENT_LENGTH', '') or '0'
    if not isinstance(raw, str) or len(raw) > 19 or not re.fullmatch(r'0|[1-9][0-9]*', raw):
        _fail('invalidRequest')
    length = int(raw)
    if maximum is not None and length > maximum:
        _fail('tooLarge', 413)
    return length


def _read_body(environ, length):
    source = _LimitedInput(environ['wsgi.input'], length)
    output = bytearray()
    while source.remaining:
        chunk = source.read(min(source.remaining, 64 * 1024))
        if not chunk:
            break
        output.extend(chunk)
    return bytes(output)


def _metadata_json(raw):
    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                _fail('invalidRequest')
            result[key] = value
        return result
    def no_number(_):
        _fail('invalidRequest')
    def validate_strings(value):
        if isinstance(value, str):
            value.encode('utf-8')
        elif isinstance(value, list):
            for item in value:
                validate_strings(item)
        elif isinstance(value, dict):
            for key, item in value.items():
                validate_strings(key)
                validate_strings(item)
    try:
        value = json.loads(raw.decode('utf-8'), object_pairs_hook=pairs,
                           parse_float=no_number, parse_constant=no_number)
        validate_strings(value)
        return value
    except (ValueError, UnicodeError, RecursionError):
        _fail('invalidRequest')


_STORAGE_PUBLIC_ERRORS = {
    'invalidObjectPath', 'unsafeStoragePath', 'notFound', 'sizeLimit',
    'invalidDigest', 'objectDigestMismatch', 'invalidBody', 'sizeMismatch',
    'digestMismatch', 'immutableConflict', 'corruptObject', 'denied',
    'invalidCosScope', 'invalidDuration', 'stsNotConfigured',
    'invalidStsResponse', 'stsUnavailable',
}


def _storage_error(error):
    if error.code not in _STORAGE_PUBLIC_ERRORS:
        _fail('unavailable', 503)
    status = {'notFound': 404, 'immutableConflict': 409, 'sizeLimit': 413,
              'denied': 403, 'stsNotConfigured': 503, 'invalidStsResponse': 503,
              'stsUnavailable': 503}.get(error.code, 400)
    _fail(error.code, status)


class SyntheticHmacVerifier:
    """Short-lived signed credentials for synthetic tests, never a default login.

    There is no issuance HTTP endpoint. Production must inject an independently
    verified OIDC/JWT/session adapter with issuer, audience, expiry and algorithm
    validation and its own identity recovery/revocation policy.
    """
    def __init__(self, key: bytes, *, synthetic_only: bool, clock=time.time):
        if synthetic_only is not True or not isinstance(key, bytes) or len(key) < 32:
            raise ValueError('explicit synthetic setup and a 32-byte key required')
        self._key, self._clock = key, clock

    def sign_for_test(self, subject: str, duration=300):
        _subject(subject)
        if not 1 <= duration <= 900:
            raise ValueError('test token lifetime must be 1..900 seconds')
        now = int(self._clock())
        payload = _b64(json.dumps({'sub': subject, 'iat': now, 'exp': now + duration,
                                  'iss': 'dayswith-synthetic-tests',
                                  'aud': 'dayswith-family-gateway'},
                                 sort_keys=True, separators=(',', ':')).encode())
        return payload + '.' + _b64(hmac.digest(self._key, payload.encode(), 'sha256'))

    def __call__(self, token: str):
        try:
            payload, signature = token.split('.')
            expected = hmac.digest(self._key, payload.encode('ascii'), 'sha256')
            if not hmac.compare_digest(expected, _unb64(signature)):
                _fail('unauthenticated', 401)
            data = json.loads(_unb64(payload))
            now = self._clock()
            if (data.get('iss') != 'dayswith-synthetic-tests' or
                    data.get('aud') != 'dayswith-family-gateway' or
                    type(data.get('iat')) is not int or type(data.get('exp')) is not int or
                    not data['iat'] <= now < data['exp'] or
                    not 1 <= data['exp'] - data['iat'] <= 900):
                _fail('unauthenticated', 401)
            return _subject(data['sub'])
        except GatewayError:
            raise
        except (ValueError, TypeError, KeyError, UnicodeError):
            _fail('unauthenticated', 401)


_SCHEMA = '''
CREATE TABLE IF NOT EXISTS gateway_storage_binding(
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), storage_id TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS families(
 id TEXT PRIMARY KEY, name TEXT NOT NULL, primary_storage_id TEXT);
CREATE TABLE IF NOT EXISTS members(
 id TEXT PRIMARY KEY, family_id TEXT NOT NULL REFERENCES families(id),
 subject_id TEXT NOT NULL, display_name TEXT NOT NULL, relationship_label TEXT NOT NULL,
 role TEXT NOT NULL CHECK(role IN ('admin','contributor','viewer')),
 status TEXT NOT NULL CHECK(status IN ('active','revoked')));
CREATE UNIQUE INDEX IF NOT EXISTS active_members ON members(family_id,subject_id)
 WHERE status='active';
CREATE TABLE IF NOT EXISTS devices(
 member_id TEXT NOT NULL REFERENCES members(id), device_id TEXT NOT NULL,
 PRIMARY KEY(member_id,device_id));
CREATE TABLE IF NOT EXISTS invitations(
 id TEXT PRIMARY KEY, family_id TEXT NOT NULL REFERENCES families(id),
 token_hash TEXT NOT NULL UNIQUE, role TEXT NOT NULL, expires_at INTEGER NOT NULL,
 revoked INTEGER NOT NULL DEFAULT 0, request_id TEXT);
CREATE TABLE IF NOT EXISTS requests(
 id TEXT PRIMARY KEY, family_id TEXT NOT NULL REFERENCES families(id),
 invitation_id TEXT NOT NULL REFERENCES invitations(id), subject_id TEXT NOT NULL,
 display_name TEXT NOT NULL, relationship_label TEXT NOT NULL,
 requested_role TEXT NOT NULL, status TEXT NOT NULL,
 approved_member_id TEXT, device_id TEXT NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS pending_requests ON requests(family_id,subject_id)
 WHERE status='pending';
CREATE TABLE IF NOT EXISTS audit(
 sequence INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL,
 subject_id TEXT NOT NULL, family_id TEXT NOT NULL, action TEXT NOT NULL,
 target_id TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS rate_limits(
 subject_id TEXT NOT NULL, window INTEGER NOT NULL, count INTEGER NOT NULL,
 PRIMARY KEY(subject_id,window));
CREATE TABLE IF NOT EXISTS records(
 id TEXT PRIMARY KEY, family_id TEXT NOT NULL REFERENCES families(id),
 owner_member_id TEXT NOT NULL REFERENCES members(id), revision INTEGER NOT NULL,
 content TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0);
'''


class Gateway:
    """WSGI application; request bodies are never an authentication source."""
    def __init__(self, database: str | Path, *, origin: str,
                 verify_bearer: Callable[[str], str] | None = None,
                 clock=time.time, object_store=None, sts_issuer=None, cos_scope=None, requests_per_minute=360):
        from .storage import validate_https_origin, StorageError
        try:
            self.origin = validate_https_origin(origin)
        except StorageError:
            raise ValueError('fixed HTTPS gateway origin required') from None
        self.database = str(database)
        if self.database == ':memory:':
            raise ValueError('a persistent database path is required')
        self.verify_bearer = verify_bearer
        self.clock = clock
        self.object_store = object_store
        self.sts_issuer, self.cos_scope = sts_issuer, cos_scope
        self.requests_per_minute = requests_per_minute
        try:
            descriptor = os.open(self.database, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(descriptor)
        except FileExistsError:
            metadata = os.lstat(self.database)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077:
                raise ValueError('private regular database file required')
        if not isinstance(requests_per_minute, int) or requests_per_minute < 1:
            raise ValueError('requests_per_minute must be positive')
        with contextlib.closing(self._connect()) as db:
            if db.execute('PRAGMA user_version').fetchone()[0] not in (0, 1):
                raise ValueError('unsupported gateway database version')
            db.executescript(_SCHEMA)
            from .archives import SCHEMA as ARCHIVE_SCHEMA
            db.executescript(ARCHIVE_SCHEMA)
            if 'deleted_at' not in {row[1] for row in db.execute('PRAGMA table_info(archive_versions)')}:
                db.execute('ALTER TABLE archive_versions ADD COLUMN deleted_at INTEGER')
            if 'upper_moderation_id' not in {row[1] for row in db.execute('PRAGMA table_info(archive_cursors)')}:
                db.execute('ALTER TABLE archive_cursors ADD COLUMN upper_moderation_id INTEGER NOT NULL DEFAULT 0')
            db.execute('PRAGMA user_version=1')
            self._bind_storage(db)

    def _bind_storage(self, db):
        db.execute('BEGIN IMMEDIATE')
        try:
            row = db.execute('SELECT storage_id FROM gateway_storage_binding WHERE singleton=1').fetchone()
            expected = row[0] if row else None
            observed = self.object_store.storage_id if self.object_store is not None else None
            if observed is not None and (not isinstance(observed, str) or not re.fullmatch(r'gateway:[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}', observed)):
                raise ValueError('valid backend storage identity required')
            if expected is not None and observed is not None and expected != observed:
                raise ValueError('backend storage identity does not match the bound database')
            if expected is None and observed is not None:
                db.execute('INSERT INTO gateway_storage_binding VALUES(1,?)', (observed,))
                expected = observed
            if expected is not None:
                if db.execute('SELECT 1 FROM families WHERE primary_storage_id IS NOT NULL AND primary_storage_id<>? LIMIT 1', (expected,)).fetchone():
                    raise ValueError('family storage identity does not match the bound database')
                db.execute('UPDATE families SET primary_storage_id=? WHERE primary_storage_id IS NULL', (expected,))
            self._storage_id = expected
            db.commit()
        except Exception:
            db.rollback()
            raise

    def _ensure_backend(self):
        if self.object_store is None or self._storage_id is None:
            _fail('unavailable', 503)
        try:
            if self.object_store.storage_id != self._storage_id:
                _fail('unavailable', 503)
        except GatewayError:
            raise
        except Exception:
            _fail('unavailable', 503)

    def _connect(self):
        db = sqlite3.connect(self.database, timeout=10, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON')
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('PRAGMA busy_timeout=10000')
        return db

    @contextlib.contextmanager
    def _transaction(self):
        db = self._connect()
        try:
            db.execute('BEGIN IMMEDIATE')
            yield db
            db.commit()
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()

    def _audit(self, db, subject, family, action, target):
        db.execute('INSERT INTO audit(at,subject_id,family_id,action,target_id) VALUES(?,?,?,?,?)',
                   (int(self.clock()), subject, family, action, target))

    def _member(self, db, subject, family, *, admin=False):
        row = db.execute("SELECT * FROM members WHERE family_id=? AND subject_id=? AND status='active'",
                         (family, subject)).fetchone()
        if not row or (admin and row['role'] != 'admin'):
            _fail('denied', 403)
        return row

    def _member_json(self, db, row):
        return {'id': row['id'], 'familyID': row['family_id'], 'subjectID': row['subject_id'],
                'displayName': row['display_name'], 'relationshipLabel': row['relationship_label'],
                'role': row['role'], 'status': row['status'],
                'deviceIDs': [r[0] for r in db.execute(
                    'SELECT device_id FROM devices WHERE member_id=? ORDER BY device_id', (row['id'],))]}

    @staticmethod
    def _family_json(row):
        return {'id': row['id'], 'name': row['name'], 'primaryStorageID': row['primary_storage_id']}

    @staticmethod
    def _request_json(row):
        return {'id': row['id'], 'familyID': row['family_id'],
                'invitationID': row['invitation_id'], 'subjectID': row['subject_id'],
                'displayName': row['display_name'], 'relationshipLabel': row['relationship_label'],
                'requestedRole': row['requested_role'], 'status': row['status'],
                'approvedMemberID': row['approved_member_id'], 'deviceID': row['device_id']}

    @staticmethod
    def _bounded(rows, mapper):
        values, encoded_size = [], 0
        for row in rows:
            value = mapper(row)
            encoded_size += len(json.dumps(value, ensure_ascii=False).encode()) + 2
            if len(values) >= 2000 or encoded_size > 768 * 1024:
                _fail('tooLarge', 413)
            values.append(value)
        return values

    def _family_detail(self, db, subject, family_id):
        current = self._member(db, subject, family_id)
        family = db.execute('SELECT * FROM families WHERE id=?', (family_id,)).fetchone()
        members = db.execute('SELECT * FROM members WHERE family_id=? ORDER BY id', (family_id,))
        return {'family': self._family_json(family),
                'members': self._bounded(members, lambda m: self._member_json(db, m)),
                'currentMember': self._member_json(db, current)}

    @staticmethod
    def _fields(body, required, optional=()):
        if not isinstance(body, dict) or not set(required) <= body.keys() or not body.keys() <= set(required) | set(optional):
            _fail('invalidRequest')

    def _usable_invitation(self, db, token):
        if not re.fullmatch(r'[A-Za-z0-9_-]{43}', token):
            _fail('invalidInvitation', 404)
        row = db.execute('SELECT * FROM invitations WHERE token_hash=?', (_hash(token),)).fetchone()
        if not row:
            _fail('invalidInvitation', 404)
        if row['revoked']:
            _fail('revoked', 410)
        if row['request_id']:
            _fail('alreadyUsed', 409)
        if self.clock() >= row['expires_at']:
            _fail('expired', 410)
        return row

    def _preview(self, db, invitation):
        family = db.execute('SELECT * FROM families WHERE id=?', (invitation['family_id'],)).fetchone()
        return {'familyID': family['id'], 'familyName': family['name'],
                'requestedRole': invitation['role'], 'expiresAt': _iso(invitation['expires_at'])}

    def dispatch(self, subject, method, path, body=None):
        """For trusted in-process adapters; public callers must go through WSGI auth."""
        _subject(subject)
        if not re.fullmatch(r'/v1(?:/[A-Za-z0-9_-]+)+|/v1', path):
            _fail('notFound', 404)
        parts = path.strip('/').split('/')[1:]
        with self._transaction() as db:
            if parts == ['families']:
                if method == 'GET':
                    rows = db.execute("SELECT f.* FROM families f JOIN members m ON f.id=m.family_id WHERE m.subject_id=? AND m.status='active' ORDER BY f.id", (subject,))
                    return {'families': self._bounded(rows, self._family_json)}
                if method == 'POST':
                    self._fields(body, {'name', 'displayName', 'relationshipLabel', 'deviceID'})
                    family, member, device = _id(), _id(), _id(body['deviceID'])
                    db.execute('INSERT INTO families VALUES(?,?,?)', (family, _text(body['name']), self._storage_id))
                    db.execute('INSERT INTO members VALUES(?,?,?,?,?,?,?)',
                               (member, family, subject, _text(body['displayName']),
                                _text(body['relationshipLabel']), 'admin', 'active'))
                    db.execute('INSERT INTO devices VALUES(?,?)', (member, device))
                    self._audit(db, subject, family, 'family.create', family)
                    return self._family_detail(db, subject, family)
            if len(parts) >= 2 and parts[0] == 'families':
                family = _id(parts[1])
                if len(parts) == 2 and method == 'GET':
                    return self._family_detail(db, subject, family)
                if len(parts) == 3 and parts[2] == 'invitations' and method == 'POST':
                    self._member(db, subject, family, admin=True)
                    self._fields(body, {'requestedRole'})
                    role = body['requestedRole']
                    if role not in ('viewer', 'contributor'):
                        _fail('unsupportedRole')
                    token, invitation = secrets.token_urlsafe(32), _id()
                    expires = int(self.clock()) + 600
                    db.execute('INSERT INTO invitations(id,family_id,token_hash,role,expires_at) VALUES(?,?,?,?,?)',
                               (invitation, family, _hash(token), role, expires))
                    self._audit(db, subject, family, 'invitation.issue', invitation)
                    return {'id': invitation, 'url': self.origin + '/family-invitations/' + token,
                            'requestedRole': role, 'expiresAt': _iso(expires)}
                if len(parts) == 3 and parts[2] == 'requests' and method == 'GET':
                    self._member(db, subject, family, admin=True)
                    return {'requests': self._bounded(db.execute(
                        "SELECT * FROM requests WHERE family_id=? AND status='pending' ORDER BY id", (family,)), self._request_json)}
                if len(parts) == 5 and parts[4] == 'revoke' and method == 'POST':
                    self._member(db, subject, family, admin=True)
                    target = _id(parts[3])
                    if parts[2] == 'invitations':
                        row = db.execute('SELECT * FROM invitations WHERE id=? AND family_id=?', (target, family)).fetchone()
                        if not row:
                            _fail('notFound', 404)
                        db.execute('UPDATE invitations SET revoked=1 WHERE id=?', (target,))
                        db.execute("UPDATE requests SET status='revoked' WHERE invitation_id=? AND status='pending'", (target,))
                        self._audit(db, subject, family, 'invitation.revoke', target)
                        return {'ok': True}
                    if parts[2] == 'members':
                        row = db.execute("SELECT * FROM members WHERE id=? AND family_id=? AND status='active'", (target, family)).fetchone()
                        if not row:
                            _fail('invalidState', 409)
                        if row['role'] == 'admin' and db.execute("SELECT count(*) FROM members WHERE family_id=? AND role='admin' AND status='active'", (family,)).fetchone()[0] <= 1:
                            _fail('lastAdmin', 409)
                        db.execute("UPDATE members SET status='revoked' WHERE id=?", (target,))
                        self._audit(db, subject, family, 'member.revoke', target)
                        return {'ok': True}
                if len(parts) == 3 and parts[2] == 'audit' and method == 'GET':
                    self._member(db, subject, family, admin=True)
                    return {'events': [dict(r) for r in db.execute(
                        'SELECT sequence,at,subject_id AS subjectID,action,target_id AS targetID FROM audit WHERE family_id=? ORDER BY sequence DESC LIMIT 200', (family,))]}
                if len(parts) in (3, 4) and parts[2] == 'records':
                    return self._records(db, subject, family, method, parts[3:], body)
            if len(parts) in (2, 3) and parts[0] == 'invitations':
                invitation = self._usable_invitation(db, parts[1])
                if len(parts) == 2 and method == 'GET':
                    return self._preview(db, invitation)
                if len(parts) == 3 and parts[2] == 'requests' and method == 'POST':
                    self._fields(body, {'confirmed', 'familyID', 'familyName', 'requestedRole', 'expiresAt', 'displayName', 'relationshipLabel', 'deviceID'})
                    if body['confirmed'] is not True:
                        _fail('confirmationRequired')
                    preview = self._preview(db, invitation)
                    try:
                        confirmed_expiry = datetime.fromisoformat(body['expiresAt'].replace('Z', '+00:00'))
                        if confirmed_expiry.tzinfo is None or confirmed_expiry.timestamp() != invitation['expires_at']:
                            _fail('invalidInvitation')
                    except (ValueError, TypeError, AttributeError, OverflowError):
                        _fail('invalidInvitation')
                    if any(body[k] != v for k, v in preview.items() if k != 'expiresAt'):
                        _fail('invalidInvitation')
                    family = invitation['family_id']
                    if db.execute("SELECT id FROM members WHERE family_id=? AND subject_id=? AND status='active'", (family, subject)).fetchone():
                        _fail('alreadyMember', 409)
                    if db.execute("SELECT id FROM requests WHERE family_id=? AND subject_id=? AND status='pending'", (family, subject)).fetchone():
                        _fail('invalidState', 409)
                    request = _id()
                    db.execute('INSERT INTO requests VALUES(?,?,?,?,?,?,?,?,?,?)',
                               (request, family, invitation['id'], subject,
                                _text(body['displayName']), _text(body['relationshipLabel']),
                                invitation['role'], 'pending', None, _id(body['deviceID'])))
                    db.execute('UPDATE invitations SET request_id=? WHERE id=?', (request, invitation['id']))
                    self._audit(db, subject, family, 'join.request', request)
                    return self._request_json(db.execute('SELECT * FROM requests WHERE id=?', (request,)).fetchone())
            if parts == ['requests'] and method == 'GET':
                return {'requests': self._bounded(db.execute(
                    'SELECT * FROM requests WHERE subject_id=? ORDER BY rowid DESC', (subject,)), self._request_json)}
            if len(parts) in (2, 3) and parts[0] == 'requests':
                request_id = _id(parts[1])
                row = db.execute('SELECT * FROM requests WHERE id=?', (request_id,)).fetchone()
                if not row:
                    _fail('notFound', 404)
                if len(parts) == 2 and method == 'GET':
                    if row['subject_id'] != subject:
                        self._member(db, subject, row['family_id'], admin=True)
                    return self._request_json(row)
                if len(parts) == 3 and method == 'POST':
                    self._member(db, subject, row['family_id'], admin=True)
                    if row['status'] != 'pending':
                        _fail('invalidState', 409)
                    if parts[2] == 'approve':
                        if db.execute("SELECT id FROM members WHERE family_id=? AND subject_id=? AND status='active'", (row['family_id'], row['subject_id'])).fetchone():
                            _fail('alreadyMember', 409)
                        if db.execute('SELECT 1 FROM devices d JOIN members m ON m.id=d.member_id WHERE m.family_id=? AND d.device_id=? AND m.subject_id<>?', (row['family_id'], row['device_id'], row['subject_id'])).fetchone():
                            _fail('conflict', 409)
                        member = _id()
                        db.execute('INSERT INTO members VALUES(?,?,?,?,?,?,?)',
                                   (member, row['family_id'], row['subject_id'], row['display_name'], row['relationship_label'], row['requested_role'], 'active'))
                        db.execute('INSERT INTO devices VALUES(?,?)', (member, row['device_id']))
                        db.execute("UPDATE requests SET status='approved',approved_member_id=? WHERE id=?", (member, request_id))
                        self._audit(db, subject, row['family_id'], 'join.approve', request_id)
                        return self._member_json(db, db.execute('SELECT * FROM members WHERE id=?', (member,)).fetchone())
                    if parts[2] == 'deny':
                        db.execute("UPDATE requests SET status='denied' WHERE id=?", (request_id,))
                        self._audit(db, subject, row['family_id'], 'join.deny', request_id)
                        return self._request_json(db.execute('SELECT * FROM requests WHERE id=?', (request_id,)).fetchone())
            _fail('notFound', 404)

    def _records(self, db, subject, family, method, tail, body):
        member = self._member(db, subject, family)
        def mapped(row):
            return {'id': row['id'], 'familyID': family, 'ownerMemberID': row['owner_member_id'],
                    'revision': row['revision'], 'content': json.loads(row['content']), 'deleted': bool(row['deleted'])}
        if not tail and method == 'GET':
            return {'records': self._bounded(db.execute('SELECT * FROM records WHERE family_id=? ORDER BY id', (family,)), mapped)}
        if not tail and method == 'POST':
            self._fields(body, {'id', 'content'})
            if member['role'] == 'viewer':
                _fail('denied', 403)
            record = _id(body['id'])
            if not isinstance(body['content'], dict):
                _fail('invalidRequest')
            content = json.dumps(body['content'], ensure_ascii=False, allow_nan=False)
            existing = db.execute('SELECT * FROM records WHERE id=?', (record,)).fetchone()
            if existing:
                if (existing['family_id'] == family and existing['owner_member_id'] == member['id'] and
                        not existing['deleted'] and json.loads(existing['content']) == body['content']):
                    return mapped(existing)
                _fail('conflict', 409)
            db.execute('INSERT INTO records VALUES(?,?,?,?,?,0)', (record, family, member['id'], 1, content))
            self._audit(db, subject, family, 'record.create', record)
            return mapped(db.execute('SELECT * FROM records WHERE id=?', (record,)).fetchone())
        if tail and len(tail) == 1:
            record = _id(tail[0])
            row = db.execute('SELECT * FROM records WHERE id=? AND family_id=?', (record, family)).fetchone()
            if not row:
                _fail('notFound', 404)
            if method == 'GET':
                return mapped(row)
            if method == 'PUT':
                self._fields(body, {'expectedRevision', 'content'})
                if member['role'] == 'viewer' or member['id'] != row['owner_member_id']:
                    _fail('denied', 403)
                if type(body['expectedRevision']) is not int or body['expectedRevision'] != row['revision'] or row['deleted']:
                    _fail('conflict', 409)
                if not isinstance(body['content'], dict):
                    _fail('invalidRequest')
                db.execute('UPDATE records SET revision=revision+1,content=? WHERE id=?',
                           (json.dumps(body['content'], ensure_ascii=False, allow_nan=False), record))
                self._audit(db, subject, family, 'record.edit', record)
                return mapped(db.execute('SELECT * FROM records WHERE id=?', (record,)).fetchone())
            if method == 'DELETE':
                # Deletion is a separate explicit admin operation, never implied by edit.
                if member['role'] != 'admin':
                    _fail('denied', 403)
                if row['deleted']:
                    return {'ok': True}
                db.execute('UPDATE records SET deleted=1,revision=revision+1 WHERE id=?', (record,))
                self._audit(db, subject, family, 'record.delete', record)
                return {'ok': True}
        _fail('notFound', 404)

    def _authenticate(self, environ):
        if environ.get('wsgi.url_scheme') != 'https':
            _fail('httpsRequired', 400)
        if self.verify_bearer is None:
            _fail('unavailable', 503)
        auth = environ.get('HTTP_AUTHORIZATION', '')
        if (not isinstance(auth, str) or len(auth) > 8192 or auth[:7].lower() != 'bearer ' or
                not re.fullmatch(r'[A-Za-z0-9._~+/-]+=*', auth[7:])):
            _fail('unauthenticated', 401)
        host = environ.get('HTTP_HOST', '')
        try:
            if not isinstance(host, str) or not re.fullmatch(r'[A-Za-z0-9.\[\]:-]+', host):
                _fail('invalidRequest')
            observed, expected = urlsplit('https://' + host), urlsplit(self.origin)
            if observed.hostname != expected.hostname or (observed.port or 443) != (expected.port or 443):
                _fail('invalidRequest')
        except ValueError:
            _fail('invalidRequest')
        try:
            subject = _subject(self.verify_bearer(auth[7:]))
        except Exception:
            _fail('unauthenticated', 401)
        with self._transaction() as db:
            window = int(self.clock()) // 60
            db.execute('DELETE FROM rate_limits WHERE window<?', (window - 2,))
            row = db.execute('SELECT count FROM rate_limits WHERE subject_id=? AND window=?', (subject, window)).fetchone()
            if row and row[0] >= self.requests_per_minute:
                _fail('rateLimited', 429)
            db.execute('INSERT INTO rate_limits VALUES(?,?,1) ON CONFLICT(subject_id,window) DO UPDATE SET count=count+1', (subject, window))
        return subject

    def _media(self, environ, subject, path):
        self._ensure_backend()
        match = re.fullmatch(r'/v1/families/([A-Fa-f0-9-]+)/members/([A-Fa-f0-9-]+)/objects/([a-f0-9]{64})', path)
        if not match:
            _fail('notFound', 404)
        family, owner = map(_id, match.groups()[:2])
        obj = match.group(3)
        method = environ['REQUEST_METHOD']
        def authorize(action, family_id, owner_id, object_id):
            self._ensure_backend()
            with self._transaction() as db:
                member = self._member(db, subject, family_id)
                target = db.execute("SELECT id FROM members WHERE id=? AND family_id=?", (owner_id, family_id)).fetchone()
                if target is None:
                    _fail('denied', 403)
                if action == 'write' and (member['role'] == 'viewer' or member['id'] != owner_id):
                    _fail('denied', 403)
                if action == 'delete' and member['role'] != 'admin':
                    _fail('denied', 403)
        from .storage import StorageError
        try:
            if method == 'PUT':
                size = _request_length(environ)
                info = self.object_store.put(family, owner, obj, _LimitedInput(environ['wsgi.input'], int(size)),
                                             size=int(size), sha256=environ.get('HTTP_X_CONTENT_SHA256', ''), authorize=authorize)
                self._ensure_backend()
                with self._transaction() as db:
                    self._audit(db, subject, family, 'object.put', obj)
                return 200, {'Content-Type': 'application/json'}, [json.dumps(info.to_dict()).encode()]
            if method == 'GET':
                info = self.object_store.stat(family, owner, obj, authorize=authorize)
                return 200, {'Content-Type': 'application/octet-stream', 'Content-Length': str(info.size),
                             'X-Content-SHA256': info.sha256}, self.object_store.read(family, owner, obj, authorize=authorize)
            if method == 'HEAD':
                info = self.object_store.stat(family, owner, obj, authorize=authorize)
                return 200, {'Content-Length': str(info.size), 'X-Content-SHA256': info.sha256}, []
            if method == 'DELETE':
                authorize('delete', family, owner, obj)
                # Durable intent precedes unlink; a crash may leave an unfinished
                # intent, never an unaudited destructive operation.
                with self._transaction() as db:
                    self._member(db, subject, family, admin=True)
                    self._audit(db, subject, family, 'object.delete.request', obj)
                with self._transaction() as db:
                    self._member(db, subject, family, admin=True)
                    if db.execute('SELECT 1 FROM archive_object_references WHERE family_id=? AND member_id=? AND sha256=? LIMIT 1', (family, owner, obj)).fetchone():
                        _fail('referencedObject', 409)
                    def locked_authorize(action, f, m, digest):
                        self._member(db, subject, f, admin=True)
                    self.object_store.delete(family, owner, obj, authorize=locked_authorize)
                    self._audit(db, subject, family, 'object.delete', obj)
                return 200, {'Content-Type': 'application/json'}, [b'{"ok":true}']
        except OSError:
            if method == 'DELETE':
                with self._transaction() as db:
                    self._audit(db, subject, family, 'object.delete.failed', obj)
            _fail('unavailable', 503)
        except StorageError as error:
            if method == 'DELETE':
                with self._transaction() as db:
                    self._audit(db, subject, family, 'object.delete.failed', obj)
            _storage_error(error)
        _fail('notFound', 404)

    def _credentials(self, subject, family, body):
        self._fields(body, set(), {'durationSeconds'})
        if self.sts_issuer is None or self.cos_scope is None:
            _fail('unavailable', 503)
        with self._transaction() as db:
            member = self._member(db, subject, family)
            member_id, role = member['id'], member['role']
        def authorize(action, family_id, target_id, object_id):
            with self._transaction() as db:
                current = self._member(db, subject, family_id)
                if current['id'] != target_id or current['role'] != role:
                    _fail('denied', 403)
        from .storage import StorageError
        try:
            credentials = self.sts_issuer.issue(
                self.cos_scope, family, member_id, role, authorize=authorize,
                duration_seconds=body.get('durationSeconds', 600))
        except StorageError as error:
            _storage_error(error)
        with self._transaction() as db:
            self._member(db, subject, family)
            self._audit(db, subject, family, 'sts.issue', member_id)
        return credentials.to_dict()

    def _archive_route(self, environ, subject, path):
        from .archives import ArchiveRepository, ArchiveError, MAX_BYTES, MAX_INTEGER
        repo = ArchiveRepository(self)
        method = environ.get('REQUEST_METHOD', '')
        catalog = re.fullmatch(r'/v1/families/([A-Fa-f0-9-]+)/archive', path)
        snapshot = re.fullmatch(r'/v1/families/([A-Fa-f0-9-]+)/members/([A-Fa-f0-9-]+)/devices/([A-Fa-f0-9-]+)/snapshots/([1-9][0-9]{0,15})/([a-f0-9]{64})', path)
        register = re.fullmatch(r'/v1/families/([A-Fa-f0-9-]+)/devices/([A-Fa-f0-9-]+)', path)
        if catalog and method == 'GET':
            self._ensure_backend()
            fields = {}
            query = environ.get('QUERY_STRING', '')
            if query:
                if not re.fullmatch(r'[A-Za-z0-9_=&-]+', query):
                    _fail('invalidRequest')
                for pair in query.split('&'):
                    if pair.count('=') != 1:
                        _fail('invalidRequest')
                    key, value = pair.split('=')
                    if key not in ('cursor', 'limit') or key in fields or not value:
                        _fail('invalidRequest')
                    fields[key] = value
            raw_limit = fields.get('limit', '100')
            if not re.fullmatch(r'[1-9][0-9]{0,2}', raw_limit):
                _fail('invalidRequest')
            result = repo.catalog(subject, _id(catalog.group(1)), fields.get('cursor'), int(raw_limit))
            return 200, {'Content-Type': 'application/json; charset=utf-8'}, [json.dumps(result).encode()]
        if environ.get('QUERY_STRING'):
            _fail('invalidRequest')
        if register and method == 'POST':
            length = _request_length(environ, 65536)
            if environ.get('CONTENT_TYPE', '').split(';')[0].strip() != 'application/json':
                _fail('invalidRequest')
            raw = _read_body(environ, length)
            if len(raw) != length:
                _fail('invalidRequest')
            self._fields(_metadata_json(raw), set())
            result = repo.register_device(subject, _id(register.group(1)), _id(register.group(2)))
            return 200, {'Content-Type': 'application/json'}, [json.dumps(result).encode()]
        if snapshot:
            self._ensure_backend()
            family, member, device = map(_id, snapshot.groups()[:3])
            sequence, digest = int(snapshot.group(4)), snapshot.group(5)
            if sequence > MAX_INTEGER:
                _fail('invalidRequest')
            if method == 'PUT':
                repo.preflight(subject, family, member, device)
                length = _request_length(environ, MAX_BYTES)
                if environ.get('CONTENT_TYPE', '').split(';')[0].strip() != 'application/json':
                    _fail('invalidRequest')
                header_digest = environ.get('HTTP_X_CONTENT_SHA256')
                if header_digest is not None and header_digest != digest:
                    _fail('invalidArchive')
                raw = _read_body(environ, length)
                if len(raw) != length:
                    _fail('invalidArchive')
                intent = environ.get('HTTP_X_DAYSWITH_DELETION_INTENT')
                if intent not in (None, 'explicit-admin-action'):
                    _fail('invalidRequest')
                result = repo.publish(subject, family, member, device, sequence, digest, raw,
                                      deletion_intent=intent is not None)
                return 200, {'Content-Type': 'application/json'}, [json.dumps(result).encode()]
            if method == 'GET':
                raw = repo.read(subject, family, member, device, sequence, digest)
                return 200, {'Content-Type': 'application/json; charset=utf-8',
                             'Content-Length': str(len(raw)), 'X-Content-SHA256': digest}, [raw]
        _fail('notFound', 404)

    def __call__(self, environ, start_response):
        from .archives import ArchiveError
        headers = {'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff'}
        try:
            subject = self._authenticate(environ)
            _request_length(environ)
            path = environ.get('PATH_INFO', '')
            method = environ.get('REQUEST_METHOD', '')
            archive_path = re.fullmatch(r'/v1/families/[A-Fa-f0-9-]+/(?:archive|devices/[A-Fa-f0-9-]+|members/[A-Fa-f0-9-]+/devices/[A-Fa-f0-9-]+/snapshots/[^/]+/[^/]+)', path)
            if archive_path:
                status, extra, response = self._archive_route(environ, subject, path)
                headers.update(extra)
            elif environ.get('QUERY_STRING'):
                _fail('invalidRequest')
            elif '/objects/' in path:
                status, extra, response = self._media(environ, subject, path)
                headers.update(extra)
            else:
                length = _request_length(environ, 65536)
                body = None
                if method in ('POST', 'PUT'):
                    if environ.get('CONTENT_TYPE', '').split(';')[0].strip() != 'application/json':
                        _fail('invalidRequest')
                    raw = _read_body(environ, length)
                    if len(raw) != length:
                        _fail('invalidRequest')
                    body = _metadata_json(raw)
                credentials_route = re.fullmatch(r'/v1/families/([A-Fa-f0-9-]+)/credentials', path)
                moderation_route = re.fullmatch(r'/v1/families/([A-Fa-f0-9-]+)/members/([A-Fa-f0-9-]+)/records/([A-Fa-f0-9-]+)/moderation', path)
                if method == 'POST' and moderation_route:
                    from .archives import ArchiveRepository
                    self._fields(body, {'expectedRevision', 'hidden'})
                    result = ArchiveRepository(self).moderate(subject, *map(_id, moderation_route.groups()), body['expectedRevision'], body['hidden'])
                elif method == 'POST' and credentials_route:
                    result = self._credentials(subject, _id(credentials_route.group(1)), body)
                else:
                    result = self.dispatch(subject, method, path, body)
                status, response = 200, [json.dumps(result, ensure_ascii=False).encode()]
                headers['Content-Type'] = 'application/json; charset=utf-8'
        except (GatewayError, ArchiveError) as error:
            status, response = error.status, [json.dumps({'error': error.code}).encode()]
            headers['Content-Type'] = 'application/json; charset=utf-8'
        except Exception:
            # No provider exception, key, URL, input, or local path crosses WSGI.
            status, response = 503, [b'{"error":"unavailable"}']
            headers['Content-Type'] = 'application/json; charset=utf-8'
        phrases = {200: 'OK', 400: 'Bad Request', 401: 'Unauthorized', 403: 'Forbidden',
                   404: 'Not Found', 409: 'Conflict', 410: 'Gone', 413: 'Content Too Large',
                   429: 'Too Many Requests', 503: 'Service Unavailable'}
        start_response(f'{status} {phrases[status]}', list(headers.items()))
        return response
