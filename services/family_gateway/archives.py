"""Canonical family/v1 snapshots and an authenticated durable archive catalog.

Pure validation follows Dart FamilyArchiveManifest/JsonWire. Repository calls
participate in the gateway's SQLite transaction and never trust claimed owners.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import re
import secrets
from dataclasses import dataclass


MAX_BYTES = 8 * 1024 * 1024
MAX_INTEGER = 9007199254740991
MAX_TIMESTAMP = 8640000000000000
UUID = re.compile(r'[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}')
DIGEST = re.compile(r'[a-f0-9]{64}')
_DART_WS = ''.join(chr(c) for c in (9, 10, 11, 12, 13, 32, 0x85, 0xA0, 0x1680,
                                  *range(0x2000, 0x200B), 0x2028, 0x2029, 0x202F,
                                  0x205F, 0x3000, 0xFEFF))

SCHEMA = '''
CREATE TABLE IF NOT EXISTS archive_snapshots(
 catalog_id INTEGER PRIMARY KEY AUTOINCREMENT,
 family_id TEXT NOT NULL REFERENCES families(id),
 member_id TEXT NOT NULL REFERENCES members(id), device_id TEXT NOT NULL,
 sequence INTEGER NOT NULL, sha256 TEXT NOT NULL, byte_count INTEGER NOT NULL,
 body BLOB NOT NULL, UNIQUE(family_id,member_id,device_id,sequence));
CREATE INDEX IF NOT EXISTS archive_catalog ON archive_snapshots(family_id,catalog_id);
CREATE TABLE IF NOT EXISTS archive_versions(
 family_id TEXT NOT NULL, member_id TEXT NOT NULL, kind TEXT NOT NULL,
 entity_id TEXT NOT NULL, revision INTEGER NOT NULL, fingerprint TEXT NOT NULL, deleted_at INTEGER,
 PRIMARY KEY(family_id,member_id,kind,entity_id,revision));
CREATE TABLE IF NOT EXISTS archive_media_ids(
 family_id TEXT NOT NULL, member_id TEXT NOT NULL, kind TEXT NOT NULL,
 entity_id TEXT NOT NULL, fingerprint TEXT NOT NULL,
 PRIMARY KEY(family_id,member_id,kind,entity_id));
CREATE TABLE IF NOT EXISTS archive_object_references(
 catalog_id INTEGER NOT NULL REFERENCES archive_snapshots(catalog_id),
 family_id TEXT NOT NULL, member_id TEXT NOT NULL,
 sha256 TEXT NOT NULL, byte_count INTEGER NOT NULL,
 PRIMARY KEY(catalog_id,sha256));
CREATE INDEX IF NOT EXISTS archive_referenced_objects
 ON archive_object_references(family_id,member_id,sha256);
CREATE TABLE IF NOT EXISTS archive_cursors(
 token_hash TEXT PRIMARY KEY, subject_id TEXT NOT NULL, family_id TEXT NOT NULL,
 upper_id INTEGER NOT NULL, last_id INTEGER NOT NULL, expires_at INTEGER NOT NULL,
 upper_moderation_id INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS archive_moderations(
 moderation_id INTEGER PRIMARY KEY AUTOINCREMENT, family_id TEXT NOT NULL REFERENCES families(id),
 member_id TEXT NOT NULL REFERENCES members(id), record_id TEXT NOT NULL,
 hidden INTEGER NOT NULL CHECK(hidden IN (0,1)), record_revision INTEGER NOT NULL,
 at INTEGER NOT NULL, actor_member_id TEXT NOT NULL REFERENCES members(id));
CREATE INDEX IF NOT EXISTS archive_moderation_records ON archive_moderations(family_id,member_id,record_id,moderation_id);
'''


class ArchiveError(Exception):
    def __init__(self, code='invalidArchive', status=400):
        self.code, self.status = code, status
        super().__init__(code)


def invalid():
    raise ArchiveError()


def canonical_bytes(value):
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True,
                          separators=(',', ':'), allow_nan=False).encode('utf-8')
    except (TypeError, ValueError, UnicodeError, RecursionError):
        invalid()


def _fields(value, fields):
    if not isinstance(value, dict) or set(value) != set(fields.split()):
        invalid()
    return value


def _integer(value, maximum=MAX_INTEGER, minimum=0):
    if type(value) is not int or not minimum <= value <= maximum:
        invalid()
    return value


def _uuid(value):
    if not isinstance(value, str) or not UUID.fullmatch(value):
        invalid()
    return value


def _hash(value):
    if not isinstance(value, str) or not DIGEST.fullmatch(value):
        invalid()
    return value


def _text(value, maximum=None):
    if not isinstance(value, str):
        invalid()
    try:
        size = len(value.encode('utf-16-le')) // 2
    except UnicodeError:
        invalid()
    if maximum is not None and size > maximum:
        invalid()
    return value


def _items(value, maximum):
    if not isinstance(value, list) or len(value) > maximum:
        invalid()
    ids = [_uuid(item.get('id') if isinstance(item, dict) else None) for item in value]
    if len(set(ids)) != len(ids) or ids != sorted(ids):
        invalid()
    return value


def _timestamp(value):
    return _integer(value, MAX_TIMESTAMP)


def _optional_time(value):
    if value is not None:
        _timestamp(value)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            invalid()
        result[key] = value
    return result


def _no_float(_):
    invalid()


@dataclass(frozen=True)
class Manifest:
    document: dict
    body: bytes
    sha256: str
    objects: dict
    media_ids: dict

    @property
    def records(self):
        return self.document['records']

    @property
    def anniversaries(self):
        return self.document['anniversaries']


def validate_manifest(body, family, member, device, sequence, digest):
    if not isinstance(body, bytes) or not 0 < len(body) <= MAX_BYTES:
        invalid()
    try:
        document = json.loads(body.decode('utf-8'), object_pairs_hook=_pairs,
                              parse_float=_no_float, parse_constant=_no_float)
    except (ValueError, UnicodeError, RecursionError):
        invalid()
    _fields(document, 'version familyID memberID deviceID sequence parentHash records anniversaries')
    if (_integer(document['version']) != 1 or _uuid(document['familyID']) != family or
            _uuid(document['memberID']) != member or _uuid(document['deviceID']) != device or
            _integer(document['sequence'], minimum=1) != sequence):
        invalid()
    parent = document['parentHash']
    if (sequence == 1) != (parent is None):
        invalid()
    if parent is not None:
        _hash(parent)
    objects, media_ids = {}, {}

    def immutable(kind, entity, value):
        fingerprint = hashlib.sha256(canonical_bytes(value)).hexdigest()
        key = (kind, entity)
        if key in media_ids and media_ids[key] != fingerprint:
            invalid()
        media_ids[key] = fingerprint

    for record in _items(document['records'], 10000):
        _fields(record, 'id ownerMemberID writerDeviceID revision occurredAt updatedAt deletedAt title note assets')
        if _uuid(record['ownerMemberID']) != member:
            invalid()
        _uuid(record['writerDeviceID'])
        _integer(record['revision'], minimum=1)
        _timestamp(record['occurredAt'])
        _timestamp(record['updatedAt'])
        _optional_time(record['deletedAt'])
        _text(record['title'], 200)
        _text(record['note'], 10000)
        assets = _items(record['assets'], 30)
        if record['deletedAt'] is None and not assets and not record['title'].strip(_DART_WS) and not record['note'].strip(_DART_WS):
            invalid()
        for asset in assets:
            _fields(asset, 'id kind capturedAt resources')
            _timestamp(asset['capturedAt'])
            roles = {'photo': {'photo', 'preview'}, 'video': {'video', 'preview'},
                     'motionPhoto': {'motionPhoto', 'preview'},
                     'livePhoto': {'livePhotoImage', 'livePhotoVideo', 'preview'}}
            if not isinstance(asset['kind'], str) or asset['kind'] not in roles:
                invalid()
            resources = _items(asset['resources'], 3)
            actual_roles = []
            for resource in resources:
                _fields(resource, 'id role contentType originalFilename byteCount sha256 objectKey')
                role = _text(resource['role'])
                actual_roles.append(role)
                content_type = _text(resource['contentType'], 120)
                prefix = 'video/' if role in ('video', 'livePhotoVideo') else 'image/'
                if not content_type.startswith(prefix) or not re.fullmatch(r'[A-Za-z0-9.+-]+', content_type[len(prefix):]):
                    invalid()
                filename = _text(resource['originalFilename'], 255)
                if not filename or '/' in filename or '\\' in filename or any(ord(c) < 32 for c in filename):
                    invalid()
                count = _integer(resource['byteCount'], 2147483648, 1)
                sha = _hash(resource['sha256'])
                if resource['objectKey'] != f'family/v1/{family}/members/{member}/objects/{sha}':
                    invalid()
                if sha in objects and objects[sha] != count:
                    invalid()
                objects[sha] = count
                immutable('resource', resource['id'], resource)
            if len(actual_roles) != len(roles[asset['kind']]) or set(actual_roles) != roles[asset['kind']]:
                invalid()
            immutable('asset', asset['id'], asset)
    for anniversary in _items(document['anniversaries'], 10000):
        _fields(anniversary, 'id ownerMemberID title date revision deletedAt')
        if _uuid(anniversary['ownerMemberID']) != member:
            invalid()
        _integer(anniversary['revision'], minimum=1)
        _optional_time(anniversary['deletedAt'])
        if not _text(anniversary['title'], 100).strip(_DART_WS):
            invalid()
        date = _text(anniversary['date'])
        if not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}', date):
            invalid()
        try:
            datetime.date.fromisoformat(date)
        except ValueError:
            invalid()
    if canonical_bytes(document) != body or hashlib.sha256(body).hexdigest() != _hash(digest):
        invalid()
    return Manifest(document, body, digest, objects, media_ids)


def descriptor(row):
    return {'familyID': row['family_id'], 'memberID': row['member_id'],
            'deviceID': row['device_id'], 'sequence': row['sequence'],
            'sha256': row['sha256'], 'byteCount': row['byte_count']}


class ArchiveRepository:
    def __init__(self, gateway):
        self.gateway = gateway

    def register_device(self, subject, family, device):
        with self.gateway._transaction() as db:
            member = self.gateway._member(db, subject, family)
            owners = db.execute('SELECT m.subject_id FROM devices d JOIN members m ON m.id=d.member_id WHERE m.family_id=? AND d.device_id=?', (family, device))
            if any(row[0] != subject for row in owners):
                raise ArchiveError('conflict', 409)
            existing = db.execute('SELECT 1 FROM devices WHERE member_id=? AND device_id=?', (member['id'], device)).fetchone()
            if not existing:
                db.execute('INSERT INTO devices VALUES(?,?)', (member['id'], device))
                self.gateway._audit(db, subject, family, 'archive.device.register', device)
            return {'ok': True}

    def _writer(self, db, subject, family, member, device):
        actor = self.gateway._member(db, subject, family)
        if actor['id'] != member or actor['role'] == 'viewer' or not db.execute('SELECT 1 FROM devices WHERE member_id=? AND device_id=?', (member, device)).fetchone():
            # Import avoids a module import cycle and preserves one public error type.
            from .gateway import GatewayError
            raise GatewayError('denied', 403)
        return actor

    def preflight(self, subject, family, member, device):
        with self.gateway._transaction() as db:
            self._writer(db, subject, family, member, device)

    def _verify_media(self, db, manifest, subject, family, member):
        if manifest.objects and self.gateway.object_store is None:
            raise ArchiveError('unavailable', 503)
        from .storage import StorageError
        def authorize(action, f, m, digest):
            current = self.gateway._member(db, subject, f)
            if current['id'] != m or current['role'] == 'viewer':
                raise ArchiveError('denied', 403)
        for digest, count in manifest.objects.items():
            try:
                info = self.gateway.object_store.stat(family, member, digest, authorize=authorize)
            except StorageError as error:
                if error.code == 'notFound':
                    raise ArchiveError('missingMedia', 409) from None
                raise ArchiveError('invalidMedia', 409) from None
            except OSError:
                raise ArchiveError('unavailable', 503) from None
            if info.sha256 != digest or info.size != count:
                raise ArchiveError('invalidMedia', 409)

    def publish(self, subject, family, member, device, sequence, digest, body, *, deletion_intent=False):
        self.gateway._ensure_backend()
        manifest = validate_manifest(body, family, member, device, sequence, digest)
        with self.gateway._transaction() as db:
            actor = self._writer(db, subject, family, member, device)
            if deletion_intent and actor['role'] != 'admin':
                raise ArchiveError('denied', 403)
            transitions = []
            for record in manifest.records:
                if not db.execute('SELECT 1 FROM devices WHERE member_id=? AND device_id=?', (member, record['writerDeviceID'])).fetchone():
                    raise ArchiveError('denied', 403)
            existing = db.execute('SELECT * FROM archive_snapshots WHERE family_id=? AND member_id=? AND device_id=? AND sequence=?', (family, member, device, sequence)).fetchone()
            if existing:
                if existing['sha256'] != digest or bytes(existing['body']) != body:
                    raise ArchiveError('conflict', 409)
                self._verify_media(db, manifest, subject, family, member)
                self.gateway._ensure_backend()
                return descriptor(existing)
            previous = db.execute('SELECT * FROM archive_snapshots WHERE family_id=? AND member_id=? AND device_id=? ORDER BY sequence DESC LIMIT 1', (family, member, device)).fetchone()
            if previous:
                if sequence != previous['sequence'] + 1 or manifest.document['parentHash'] != previous['sha256']:
                    raise ArchiveError('conflict', 409)
                old = json.loads(previous['body'])
                for kind in ('records', 'anniversaries'):
                    by_id = {item['id']: item for item in manifest.document[kind]}
                    for item in old[kind]:
                        replacement = by_id.get(item['id'])
                        if replacement is None or replacement['revision'] < item['revision']:
                            raise ArchiveError('conflict', 409)
            elif sequence != 1 or manifest.document['parentHash'] is not None:
                raise ArchiveError('conflict', 409)
            for kind in ('records', 'anniversaries'):
                for item in manifest.document[kind]:
                    fingerprint = hashlib.sha256(canonical_bytes(item)).hexdigest()
                    if kind == 'records':
                        moderation = db.execute('SELECT hidden,record_revision FROM archive_moderations WHERE family_id=? AND member_id=? AND record_id=? ORDER BY moderation_id DESC LIMIT 1', (family, member, item['id'])).fetchone()
                        if moderation and moderation['hidden']:
                            frozen = db.execute('SELECT fingerprint FROM archive_versions WHERE family_id=? AND member_id=? AND kind=? AND entity_id=? AND revision=?', (family, member, kind, item['id'], moderation['record_revision'])).fetchone()
                            if item['revision'] != moderation['record_revision'] or not frozen or fingerprint != frozen['fingerprint']:
                                raise ArchiveError('denied', 403)
                    head = db.execute('SELECT revision,fingerprint,deleted_at FROM archive_versions WHERE family_id=? AND member_id=? AND kind=? AND entity_id=? ORDER BY revision DESC LIMIT 1', (family, member, kind, item['id'])).fetchone()
                    if head and (item['revision'] < head['revision'] or item['revision'] == head['revision'] and fingerprint != head['fingerprint']):
                        raise ArchiveError('conflict', 409)
                    same = db.execute('SELECT fingerprint FROM archive_versions WHERE family_id=? AND member_id=? AND kind=? AND entity_id=? AND revision=?', (family, member, kind, item['id'], item['revision'])).fetchone()
                    if same and same[0] != fingerprint:
                        raise ArchiveError('conflict', 409)
                    was_deleted = head['deleted_at'] if head else None
                    now_deleted = item['deletedAt']
                    if now_deleted != was_deleted and (now_deleted is not None or was_deleted is not None):
                        if not deletion_intent or actor['role'] != 'admin':
                            raise ArchiveError('deletionIntentRequired', 403)
                        transitions.append((kind, item['id'], 'delete' if now_deleted is not None else 'restore'))
                    db.execute('INSERT OR IGNORE INTO archive_versions VALUES(?,?,?,?,?,?,?)', (family, member, kind, item['id'], item['revision'], fingerprint, now_deleted))
            for (kind, entity), fingerprint in manifest.media_ids.items():
                row = db.execute('SELECT fingerprint FROM archive_media_ids WHERE family_id=? AND member_id=? AND kind=? AND entity_id=?', (family, member, kind, entity)).fetchone()
                if row and row[0] != fingerprint:
                    raise ArchiveError('conflict', 409)
                db.execute('INSERT OR IGNORE INTO archive_media_ids VALUES(?,?,?,?,?)', (family, member, kind, entity, fingerprint))
            self._verify_media(db, manifest, subject, family, member)
            self.gateway._ensure_backend()
            cursor = db.execute('INSERT INTO archive_snapshots(family_id,member_id,device_id,sequence,sha256,byte_count,body) VALUES(?,?,?,?,?,?,?)', (family, member, device, sequence, digest, len(body), body))
            catalog = cursor.lastrowid
            for sha, count in manifest.objects.items():
                db.execute('INSERT INTO archive_object_references VALUES(?,?,?,?,?)', (catalog, family, member, sha, count))
            for kind, entity, action in transitions:
                self.gateway._audit(db, subject, family, f'archive.{kind}.{action}', entity)
            self.gateway._audit(db, subject, family, 'archive.publish', digest)
            return descriptor(db.execute('SELECT * FROM archive_snapshots WHERE catalog_id=?', (catalog,)).fetchone())

    def read(self, subject, family, member, device, sequence, digest):
        self.gateway._ensure_backend()
        with self.gateway._transaction() as db:
            self.gateway._member(db, subject, family)
            row = db.execute('SELECT * FROM archive_snapshots WHERE family_id=? AND member_id=? AND device_id=? AND sequence=? AND sha256=?', (family, member, device, sequence, digest)).fetchone()
            if row is None:
                raise ArchiveError('notFound', 404)
            body = bytes(row['body'])
            if len(body) != row['byte_count'] or hashlib.sha256(body).hexdigest() != digest:
                raise ArchiveError('invalidArchive', 409)
            return body

    @staticmethod
    def moderation_event(row):
        return {'id': row['moderation_id'], 'familyID': row['family_id'],
                'ownerMemberID': row['member_id'], 'recordID': row['record_id'],
                'hidden': bool(row['hidden']), 'recordRevision': row['record_revision'],
                'at': row['at'], 'actorMemberID': row['actor_member_id']}

    def moderate(self, subject, family, owner, record, expected_revision, hidden):
        if type(expected_revision) is not int or not 1 <= expected_revision <= MAX_INTEGER or type(hidden) is not bool:
            raise ArchiveError('invalidRequest')
        with self.gateway._transaction() as db:
            actor = self.gateway._member(db, subject, family, admin=True)
            if not db.execute('SELECT 1 FROM members WHERE id=? AND family_id=?', (owner, family)).fetchone():
                raise ArchiveError('notFound', 404)
            head = db.execute("SELECT revision FROM archive_versions WHERE family_id=? AND member_id=? AND kind='records' AND entity_id=? ORDER BY revision DESC LIMIT 1", (family, owner, record)).fetchone()
            if not head:
                raise ArchiveError('notFound', 404)
            if head['revision'] != expected_revision:
                raise ArchiveError('conflict', 409)
            previous = db.execute('SELECT * FROM archive_moderations WHERE family_id=? AND member_id=? AND record_id=? ORDER BY moderation_id DESC LIMIT 1', (family, owner, record)).fetchone()
            if previous and bool(previous['hidden']) == hidden and previous['record_revision'] == expected_revision:
                return self.moderation_event(previous)
            created = db.execute('INSERT INTO archive_moderations(family_id,member_id,record_id,hidden,record_revision,at,actor_member_id) VALUES(?,?,?,?,?,?,?)', (family, owner, record, int(hidden), expected_revision, int(self.gateway.clock() * 1000), actor['id']))
            self.gateway._audit(db, subject, family, 'archive.moderation.hide' if hidden else 'archive.moderation.unhide', record)
            return self.moderation_event(db.execute('SELECT * FROM archive_moderations WHERE moderation_id=?', (created.lastrowid,)).fetchone())

    def _moderations(self, db, family, upper):
        rows = db.execute('SELECT m.* FROM archive_moderations m WHERE m.family_id=? AND m.moderation_id<=? AND NOT EXISTS(SELECT 1 FROM archive_moderations n WHERE n.family_id=m.family_id AND n.member_id=m.member_id AND n.record_id=m.record_id AND n.moderation_id>m.moderation_id AND n.moderation_id<=?) ORDER BY m.moderation_id', (family, upper, upper))
        return self.gateway._bounded(rows, self.moderation_event)

    def catalog(self, subject, family, cursor=None, limit=100):
        self.gateway._ensure_backend()
        if type(limit) is not int or not 1 <= limit <= 100:
            raise ArchiveError('invalidRequest')
        with self.gateway._transaction() as db:
            self.gateway._member(db, subject, family)
            now = int(self.gateway.clock())
            db.execute('DELETE FROM archive_cursors WHERE expires_at<=?', (now,))
            if cursor is not None:
                if not isinstance(cursor, str) or not re.fullmatch(r'[A-Za-z0-9_-]{32}', cursor):
                    raise ArchiveError('invalidCursor')
                row = db.execute('SELECT * FROM archive_cursors WHERE token_hash=? AND subject_id=? AND family_id=? AND expires_at>?', (hashlib.sha256(cursor.encode()).hexdigest(), subject, family, now)).fetchone()
                if not row:
                    raise ArchiveError('invalidCursor')
                last, upper = row['last_id'], row['upper_id']
                upper_moderation = row['upper_moderation_id']
            else:
                last = 0
                upper_moderation = db.execute('SELECT coalesce(max(moderation_id),0) FROM archive_moderations WHERE family_id=?', (family,)).fetchone()[0]
                upper = db.execute('SELECT coalesce(max(catalog_id),0) FROM archive_snapshots WHERE family_id=?', (family,)).fetchone()[0]
            rows = list(db.execute('SELECT catalog_id,family_id,member_id,device_id,sequence,sha256,byte_count FROM archive_snapshots WHERE family_id=? AND catalog_id>? AND catalog_id<=? ORDER BY catalog_id LIMIT ?', (family, last, upper, limit + 1)))
            selected = rows[:limit]
            next_cursor = None
            if len(rows) > limit:
                next_cursor = secrets.token_urlsafe(24)
                db.execute('INSERT INTO archive_cursors VALUES(?,?,?,?,?,?,?)', (hashlib.sha256(next_cursor.encode()).hexdigest(), subject, family, upper, selected[-1]['catalog_id'], now + 600, upper_moderation))
            return {'snapshots': [descriptor(row) for row in selected], 'nextCursor': next_cursor,
                    'moderationVersion': upper_moderation, 'moderations': self._moderations(db, family, upper_moderation)}
