"""Persistent target identity protects a fixed gateway origin from root switches."""
import io
import json
from pathlib import Path
import secrets
import tempfile
import unittest
import uuid

from services.family_gateway.gateway import Gateway, SyntheticHmacVerifier
from services.family_gateway.storage import ObjectStore, StorageError


def uid():
    return str(uuid.uuid4()).upper()


class StorageBindingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.db = self.root / 'binding.sqlite3'
        self.store = ObjectStore(self.root / 'backend')
        self.now = 1900000000
        self.verifier = SyntheticHmacVerifier(secrets.token_bytes(32), synthetic_only=True, clock=lambda: self.now)
        self.app = self.make(self.store)
        created = self.call(self.app, 'POST', '/v1/families', {
            'name': 'Synthetic target', 'displayName': 'Parent',
            'relationshipLabel': '爸爸', 'deviceID': uid()})
        self.assertEqual(200, created['status'])
        self.family = created['body']['family']['id']
        self.member = created['body']['currentMember']['id']
        self.device = created['body']['currentMember']['deviceIDs'][0]

    def make(self, store):
        return Gateway(self.db, origin='https://family.example.test',
                       verify_bearer=self.verifier, clock=lambda: self.now, object_store=store)

    def call(self, app, method, path, body=None, raw=None):
        raw = json.dumps(body or {}).encode() if raw is None and method in ('POST', 'PUT') else raw or b''
        env = {'REQUEST_METHOD': method, 'PATH_INFO': path, 'QUERY_STRING': '',
               'HTTP_HOST': 'family.example.test', 'wsgi.url_scheme': 'https',
               'wsgi.input': io.BytesIO(raw), 'CONTENT_LENGTH': str(len(raw)),
               'CONTENT_TYPE': 'application/json',
               'HTTP_AUTHORIZATION': 'Bearer ' + self.verifier.sign_for_test('synthetic-owner')}
        response = {}
        def start(status, headers):
            response['status'] = int(status.split()[0])
        response['body'] = json.loads(b''.join(app(env, start)))
        return response

    def test_same_backend_restart_keeps_primary_storage_identity(self):
        expected = self.store.storage_id
        detail = self.call(self.app, 'GET', '/v1/families/' + self.family)['body']
        self.assertEqual(expected, detail['family']['primaryStorageID'])
        reopened = ObjectStore(self.root / 'backend')
        again = self.call(self.make(reopened), 'GET', '/v1/families/' + self.family)['body']
        self.assertEqual(expected, reopened.storage_id)
        self.assertEqual(expected, again['family']['primaryStorageID'])

    def test_new_root_cannot_silently_rebind_existing_database(self):
        other = ObjectStore(self.root / 'other-backend')
        self.assertNotEqual(self.store.storage_id, other.storage_id)
        with self.assertRaises(ValueError):
            self.make(other)
        self.assertEqual(self.store.storage_id, self.call(self.app, 'GET', '/v1/families/' + self.family)['body']['family']['primaryStorageID'])
        self.assertEqual([], self.call(self.app, 'GET', f'/v1/families/{self.family}/archive')['body']['snapshots'])

    def test_backend_unavailable_keeps_metadata_but_disables_all_archive_data(self):
        app = self.make(None)
        detail = self.call(app, 'GET', '/v1/families/' + self.family)
        self.assertEqual(200, detail['status'])
        self.assertEqual(self.store.storage_id, detail['body']['family']['primaryStorageID'])
        for method, path in (
            ('GET', f'/v1/families/{self.family}/archive'),
            ('GET', f'/v1/families/{self.family}/members/{self.member}/devices/{self.device}/snapshots/1/' + '0'*64),
            ('PUT', f'/v1/families/{self.family}/members/{self.member}/devices/{self.device}/snapshots/1/' + '0'*64),
            ('GET', f'/v1/families/{self.family}/members/{self.member}/objects/' + '0'*64),
        ):
            with self.subTest(path=path, method=method):
                response = self.call(app, method, path)
                self.assertEqual(503, response['status'])
                self.assertEqual({'error': 'unavailable'}, response['body'])

    def test_missing_or_corrupt_marker_cannot_authorize_live_or_reopened_backend(self):
        marker = self.root / 'backend' / '.dayswith-storage-id'
        original = marker.read_bytes()
        marker.unlink()
        self.assertEqual(503, self.call(self.app, 'GET', f'/v1/families/{self.family}/archive')['status'])
        with self.assertRaises(StorageError):
            ObjectStore(self.root / 'backend')
        marker.write_bytes(b'{"version":1,"id":"not-a-storage-id"}')
        marker.chmod(0o600)
        with self.assertRaises(StorageError):
            ObjectStore(self.root / 'backend')
        self.assertNotIn(b'secret', original.lower())
        self.assertNotIn(b'password', original.lower())
        self.assertNotIn(b'credential', original.lower())

    def test_unbound_metadata_database_can_bind_once_when_backend_is_configured(self):
        path = self.root / 'metadata-only.sqlite3'
        metadata = Gateway(path, origin='https://family.example.test', verify_bearer=self.verifier, clock=lambda: self.now)
        created = self.call(metadata, 'POST', '/v1/families', {
            'name': 'Before setup', 'displayName': 'Parent', 'relationshipLabel': '家长', 'deviceID': uid()})['body']
        self.assertIsNone(created['family']['primaryStorageID'])
        bound = Gateway(path, origin='https://family.example.test', verify_bearer=self.verifier,
                        clock=lambda: self.now, object_store=self.store)
        detail = self.call(bound, 'GET', '/v1/families/' + created['family']['id'])['body']
        self.assertEqual(self.store.storage_id, detail['family']['primaryStorageID'])


if __name__ == '__main__':
    unittest.main()
