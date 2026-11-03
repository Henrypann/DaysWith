import hashlib
import io
import json
from pathlib import Path
import secrets
import sqlite3
import tempfile
import threading
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor

from services.family_gateway.gateway import Gateway, GatewayError, SyntheticHmacVerifier
from services.family_gateway.storage import ObjectStore, RestrictedStsIssuer, CosScope


def uid():
    return str(uuid.uuid4()).upper()


class GatewayTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'family.sqlite3'
        self.now = 1900000000
        self.verifier = SyntheticHmacVerifier(secrets.token_bytes(32), synthetic_only=True, clock=lambda: self.now)
        self.store = ObjectStore(Path(self.tmp.name) / 'objects')
        self.app = self.make_app()
        self.owner = 'issuer|synthetic-parent'
        self.guest = 'issuer|synthetic-grandparent'
        self.family = self.create_family()
        self.fid = self.family['family']['id']
        self.mid = self.family['currentMember']['id']

    def make_app(self, **kwargs):
        return Gateway(self.path, origin='https://family.example.test',
                       verify_bearer=self.verifier, clock=lambda: self.now,
                       object_store=self.store, **kwargs)

    def call(self, method, path, body=None, *, subject=None, token=None, app=None,
             scheme='https', content_type='application/json', headers=None, raw=None):
        if raw is None:
            raw = json.dumps(body or {}).encode() if method in ('POST', 'PUT') else b''
        env = {'REQUEST_METHOD': method, 'PATH_INFO': path, 'QUERY_STRING': '',
               'wsgi.url_scheme': scheme, 'HTTP_HOST': 'family.example.test', 'wsgi.input': io.BytesIO(raw),
               'CONTENT_LENGTH': str(len(raw)), 'CONTENT_TYPE': content_type}
        if token is None and subject is not False:
            token = self.verifier.sign_for_test(subject or self.owner)
        if token:
            env['HTTP_AUTHORIZATION'] = 'Bearer ' + token
        env.update(headers or {})
        result = {}
        def start(status, values):
            result['status'] = int(status.split()[0])
            result['headers'] = dict(values)
        data = b''.join((app or self.app)(env, start))
        result['body'] = json.loads(data) if result['headers'].get('Content-Type', '').startswith('application/json') else data
        return result

    def create_family(self, subject=None):
        response = self.call('POST', '/v1/families', {
            'name': 'Synthetic family', 'displayName': 'Parent',
            'relationshipLabel': '爸爸', 'deviceID': uid()}, subject=subject)
        self.assertEqual(response['status'], 200, response['body'])
        return response['body']

    def issue(self, role='contributor'):
        response = self.call('POST', f'/v1/families/{self.fid}/invitations', {'requestedRole': role})
        self.assertEqual(response['status'], 200, response['body'])
        return response['body']

    def apply(self, invite=None, subject=None):
        invite = invite or self.issue()
        token = invite['url'].rsplit('/', 1)[1]
        preview = self.call('GET', '/v1/invitations/' + token, subject=subject or self.guest)
        self.assertEqual(preview['status'], 200)
        body = dict(preview['body'], confirmed=True, displayName='Grandparent',
                    relationshipLabel='外婆', deviceID=uid())
        response = self.call('POST', f'/v1/invitations/{token}/requests', body, subject=subject or self.guest)
        self.assertEqual(response['status'], 200, response['body'])
        return response['body']

    def join(self, role='contributor', subject=None):
        request = self.apply(self.issue(role), subject)
        response = self.call('POST', '/v1/requests/' + request['id'] + '/approve')
        self.assertEqual(response['status'], 200, response['body'])
        return response['body']

    def test_identity_is_verified_and_no_default_auth_exists(self):
        self.assertEqual(self.call('GET', '/v1/families', subject=False)['status'], 401)
        self.assertEqual(self.call('GET', '/v1/families', token='not.valid')['status'], 401)
        closed = Gateway(self.path, origin='https://family.example.test')
        self.assertEqual(self.call('GET', '/v1/families', app=closed)['body'], {'error': 'unavailable'})
        forged = self.call('POST', '/v1/families', {'name': 'a', 'displayName': 'b',
            'relationshipLabel': 'c', 'deviceID': uid(), 'subjectID': self.owner}, subject=self.guest)
        self.assertEqual(forged['status'], 400)
        self.assertEqual(self.call('GET', '/v1/families', subject=self.guest)['body']['families'], [])

    def test_https_and_signed_token_expiry_required(self):
        self.assertEqual(self.call('GET', '/v1/families', scheme='http')['status'], 400)
        token = self.verifier.sign_for_test(self.owner, duration=1)
        self.now += 1
        self.assertEqual(self.call('GET', '/v1/families', token=token)['status'], 401)
        with self.assertRaises(ValueError):
            SyntheticHmacVerifier(b'x'*32, synthetic_only=False)

    def test_invitation_requires_confirmation_and_admin_approval(self):
        invite = self.issue()
        token = invite['url'].rsplit('/', 1)[1]
        preview = self.call('GET', '/v1/invitations/' + token, subject=self.guest)['body']
        self.assertEqual(self.call('GET', f'/v1/families/{self.fid}', subject=self.guest)['status'], 403)
        body = dict(preview, confirmed=False, displayName='Guest', relationshipLabel='亲人', deviceID=uid())
        self.assertEqual(self.call('POST', f'/v1/invitations/{token}/requests', body, subject=self.guest)['body']['error'], 'confirmationRequired')
        body['confirmed'] = True
        # Dart UTC strings include a millisecond field; compare instants.
        body['expiresAt'] = body['expiresAt'].replace('Z', '.000Z')
        request = self.call('POST', f'/v1/invitations/{token}/requests', body, subject=self.guest)['body']
        self.assertEqual(request['status'], 'pending')
        self.assertEqual(self.call('GET', f'/v1/families/{self.fid}', subject=self.guest)['status'], 403)
        self.assertEqual(self.call('GET', '/v1/requests', subject=self.guest)['body']['requests'][0]['id'], request['id'])
        self.assertEqual(self.call('GET', '/v1/requests', subject='outsider')['body'], {'requests': []})
        approved = self.call('POST', '/v1/requests/' + request['id'] + '/approve')['body']
        self.assertEqual(approved['subjectID'], self.guest)
        self.assertEqual(approved['deviceIDs'], [body['deviceID']])
        self.assertEqual(self.call('GET', f'/v1/families/{self.fid}', subject=self.guest)['status'], 200)

    def test_expiry_at_boundary_and_confirmation_binding(self):
        invite = self.issue()
        token = invite['url'].rsplit('/', 1)[1]
        preview = self.call('GET', '/v1/invitations/' + token, subject=self.guest)['body']
        body = dict(preview, confirmed=True, displayName='Guest', relationshipLabel='亲人', deviceID=uid())
        body['requestedRole'] = 'admin'
        self.assertEqual(self.call('POST', f'/v1/invitations/{token}/requests', body, subject=self.guest)['body']['error'], 'invalidInvitation')
        self.now += 600
        self.assertEqual(self.call('GET', '/v1/invitations/' + token, subject=self.guest)['body']['error'], 'expired')

    def test_restart_prevents_replay_and_duplicate_approval(self):
        invite = self.issue()
        request = self.apply(invite)
        restart = self.make_app()
        token = invite['url'].rsplit('/', 1)[1]
        self.assertEqual(self.call('GET', '/v1/invitations/' + token, app=restart)['body']['error'], 'alreadyUsed')
        self.assertEqual(self.call('POST', '/v1/requests/' + request['id'] + '/approve', app=restart)['status'], 200)
        self.assertEqual(self.call('POST', '/v1/requests/' + request['id'] + '/approve', app=restart)['body']['error'], 'invalidState')
        members = self.call('GET', f'/v1/families/{self.fid}', app=restart)['body']['members']
        self.assertEqual(sum(m['subjectID'] == self.guest for m in members), 1)

    def test_simultaneous_exchange_is_transactional_across_instances(self):
        invite = self.issue()
        token = invite['url'].rsplit('/', 1)[1]
        preview = self.call('GET', '/v1/invitations/' + token)['body']
        barrier = threading.Barrier(2)
        other_app = self.make_app()
        def exchange(pair):
            subject, app = pair
            barrier.wait()
            return self.call('POST', f'/v1/invitations/{token}/requests',
                dict(preview, confirmed=True, displayName='Guest', relationshipLabel='亲人', deviceID=uid()), subject=subject, app=app)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(exchange, [('first', self.app), ('second', other_app)]))
        self.assertEqual(sorted(r['status'] for r in results), [200, 409])
        self.assertEqual([r['body']['error'] for r in results if r['status'] == 409], ['alreadyUsed'])

    def test_simultaneous_approval_creates_only_one_member(self):
        request = self.apply()
        barrier = threading.Barrier(2)
        other_app = self.make_app()
        def approve(app):
            barrier.wait()
            return self.call('POST', '/v1/requests/' + request['id'] + '/approve', app=app)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(approve, [self.app, other_app]))
        self.assertEqual(sorted(r['status'] for r in results), [200, 409])

    def test_revoke_invitation_cancels_pending_request_and_deny_cannot_replay(self):
        invite = self.issue()
        request = self.apply(invite)
        self.assertEqual(self.call('POST', f'/v1/families/{self.fid}/invitations/{invite["id"]}/revoke')['status'], 200)
        self.assertEqual(self.call('GET', '/v1/requests/' + request['id'], subject=self.guest)['body']['status'], 'revoked')
        self.assertEqual(self.call('POST', '/v1/requests/' + request['id'] + '/approve')['status'], 409)
        invite2 = self.issue()
        request2 = self.apply(invite2, 'different-applicant')
        self.assertEqual(self.call('POST', '/v1/requests/' + request2['id'] + '/deny')['body']['status'], 'denied')
        self.assertEqual(self.call('GET', '/v1/invitations/' + invite2['url'].rsplit('/', 1)[1])['body']['error'], 'alreadyUsed')

    def test_only_admin_can_review_and_last_admin_cannot_revoke_self(self):
        member = self.join()
        invite = self.issue()
        request = self.apply(invite, 'next-applicant')
        for action in ('approve', 'deny'):
            self.assertEqual(self.call('POST', '/v1/requests/' + request['id'] + '/' + action, subject=self.guest)['status'], 403)
        self.assertEqual(self.call('GET', f'/v1/families/{self.fid}/requests', subject=self.guest)['status'], 403)
        self.assertEqual(self.call('POST', f'/v1/families/{self.fid}/members/{self.mid}/revoke')['body']['error'], 'lastAdmin')
        self.assertEqual(self.call('POST', f'/v1/families/{self.fid}/invitations', {'requestedRole': 'admin'})['body']['error'], 'unsupportedRole')

    def test_revocation_blocks_new_reads_and_creates_no_duplicate_member(self):
        member = self.join()
        self.assertEqual(self.call('POST', f'/v1/families/{self.fid}/members/{member["id"]}/revoke')['status'], 200)
        for path in (f'/v1/families/{self.fid}', f'/v1/families/{self.fid}/records'):
            self.assertEqual(self.call('GET', path, subject=self.guest)['status'], 403)
        self.assertEqual(self.call('GET', '/v1/families', subject=self.guest)['body'], {'families': []})
        # Explicitly invited, approved rejoin creates a new identity; old ownership is not reassigned.
        new_member = self.join()
        self.assertNotEqual(member['id'], new_member['id'])

    def test_contributor_can_edit_only_own_and_viewer_cannot_create(self):
        member = self.join()
        viewer = self.join('viewer', 'viewer')
        record = uid()
        path = f'/v1/families/{self.fid}/records'
        response = self.call('POST', path, {'id': record, 'content': {'text': 'synthetic'}}, subject=self.guest)
        self.assertEqual(response['body']['ownerMemberID'], member['id'])
        edit = {'expectedRevision': 1, 'content': {'text': 'updated'}}
        self.assertEqual(self.call('PUT', path + '/' + record, edit)['status'], 403)
        self.assertEqual(self.call('PUT', path + '/' + record, edit, subject=self.guest)['body']['revision'], 2)
        self.assertEqual(self.call('PUT', path + '/' + record, edit, subject=self.guest)['status'], 409)
        self.assertEqual(self.call('POST', path, {'id': uid(), 'content': {}}, subject='viewer')['status'], 403)
        self.assertEqual(self.call('DELETE', path + '/' + record, subject=self.guest)['status'], 403)
        self.assertEqual(self.call('DELETE', path + '/' + record)['status'], 200)

    def test_media_stream_is_scoped_immutable_and_revocable(self):
        member = self.join()
        viewer = self.join('viewer', 'viewer')
        data = b'synthetic original' * 50
        oid = hashlib.sha256(data).hexdigest()
        path = f'/v1/families/{self.fid}/members/{member["id"]}/objects/{oid}'
        data = b'synthetic original' * 50
        headers = {'HTTP_X_CONTENT_SHA256': hashlib.sha256(data).hexdigest()}
        response = self.call('PUT', path, raw=data, headers=headers, subject=self.guest)
        self.assertEqual(response['status'], 200, response['body'])
        self.assertEqual(self.call('PUT', path, raw=b'changed', headers={'HTTP_X_CONTENT_SHA256': hashlib.sha256(b'changed').hexdigest()}, subject=self.guest)['status'], 400)
        self.assertEqual(self.call('PUT', path, raw=data, headers=headers, subject='viewer')['status'], 403)
        self.assertEqual(self.call('PUT', path, raw=data, headers=headers)['status'], 403)
        self.assertEqual(self.call('GET', path, subject='viewer')['body'], data)
        self.assertEqual(self.call('DELETE', path, subject=self.guest)['status'], 403)
        self.call('POST', f'/v1/families/{self.fid}/members/{viewer["id"]}/revoke')
        self.assertEqual(self.call('GET', path, subject='viewer')['status'], 403)
        self.assertEqual(self.call('DELETE', path)['status'], 200)

    def test_credentials_endpoint_is_disabled_until_configured_and_rechecks_revocation(self):
        member = self.join()
        path = f'/v1/families/{self.fid}/credentials'
        self.assertEqual(self.call('POST', path, subject=self.guest)['status'], 503)
        issued = []
        def issue(policy, duration):
            issued.append(policy)
            return {'credentials': {'tmpSecretId': 'synthetic-id',
                    'tmpSecretKey': 'synthetic-key', 'sessionToken': 'synthetic-token'},
                    'expiredTime': self.now + duration}
        app = Gateway(self.path, origin='https://family.example.test',
                      verify_bearer=self.verifier, clock=lambda: self.now,
                      sts_issuer=RestrictedStsIssuer(issue, clock=lambda: self.now),
                      cos_scope=CosScope('synthetic-123456', 'ap-test', '123456'))
        response = self.call('POST', path, {'durationSeconds': 600}, subject=self.guest, app=app)
        self.assertEqual(response['status'], 200)
        self.assertEqual(issued[0]['statement'][0]['action'], ['name/cos:GetObject', 'name/cos:HeadObject'])
        self.assertNotIn('synthetic-key', json.dumps(self.call('GET', f'/v1/families/{self.fid}/audit')['body']))
        self.call('POST', f'/v1/families/{self.fid}/members/{member["id"]}/revoke')
        self.assertEqual(self.call('POST', path, subject=self.guest, app=app)['status'], 403)
        self.assertEqual(len(issued), 1)

    def test_repeated_record_create_is_idempotent_without_overwriting(self):
        self.join()
        path = f'/v1/families/{self.fid}/records'
        record = {'id': uid(), 'content': {'text': 'one synthetic record'}}
        first = self.call('POST', path, record, subject=self.guest)
        second = self.call('POST', path, record, subject=self.guest)
        self.assertEqual(first['body'], second['body'])
        changed = dict(record, content={'text': 'changed'})
        self.assertEqual(self.call('POST', path, changed, subject=self.guest)['status'], 409)
        self.assertEqual(len(self.call('GET', path)['body']['records']), 1)

    def test_wsgi_put_never_reads_past_declared_content_length(self):
        class PersistentInput:
            def __init__(self, data):
                self.data, self.position = data, 0
            def read(self, amount):
                if amount > len(self.data) - self.position or self.position == len(self.data):
                    raise AssertionError('read beyond declared HTTP body could block')
                result = self.data[self.position:self.position + amount]
                self.position += len(result)
                return result
        for data in (b'', b'bounded original'):
            digest = hashlib.sha256(data).hexdigest()
            path = f'/v1/families/{self.fid}/members/{self.mid}/objects/{digest}'
            result = self.call('PUT', path, raw=data, headers={
                'wsgi.input': PersistentInput(data), 'HTTP_X_CONTENT_SHA256': digest})
            self.assertEqual(result['status'], 200, result['body'])

    def test_delete_audit_intent_precedes_destructive_backend(self):
        digest = hashlib.sha256(b'synthetic').hexdigest()
        path = f'/v1/families/{self.fid}/members/{self.mid}/objects/{digest}'
        original = self.store.delete
        def delete(family, member, obj, *, authorize):
            with sqlite3.connect(self.path) as db:
                self.assertEqual(db.execute('SELECT action FROM audit ORDER BY sequence DESC LIMIT 1').fetchone()[0], 'object.delete.request')
            raise OSError('synthetic storage interruption')
        self.store.delete = delete
        try:
            self.assertEqual(self.call('DELETE', path)['status'], 503)
            events = self.call('GET', f'/v1/families/{self.fid}/audit')['body']['events']
            self.assertEqual(events[0]['action'], 'object.delete.failed')
            self.assertEqual(events[1]['action'], 'object.delete.request')
        finally:
            self.store.delete = original

    def test_large_list_fails_explicitly_without_partial_or_unbounded_response(self):
        with sqlite3.connect(self.path) as db:
            for index in range(14):
                db.execute('INSERT INTO records VALUES(?,?,?,?,?,0)',
                           (uid(), self.fid, self.mid, 1, json.dumps({'text': 'x' * 64000})))
        response = self.call('GET', f'/v1/families/{self.fid}/records')
        self.assertEqual(response['status'], 413)
        self.assertEqual(response['body'], {'error': 'tooLarge'})

    def test_profile_display_limits_match_dart_utf16_and_trim_behavior(self):
        base = {'name': 'Valid', 'displayName': 'Parent', 'relationshipLabel': '家长', 'deviceID': uid()}
        for field in ('name', 'displayName', 'relationshipLabel'):
            for invalid in ('😀' * 41, '\ufeff \ufeff \ufeff'):
                with self.subTest(field=field, value=repr(invalid)):
                    self.assertEqual(self.call('POST', '/v1/families', dict(base, **{field: invalid}))['status'], 400)
        accepted = self.call('POST', '/v1/families', dict(base, name='😀' * 40))
        self.assertEqual(accepted['status'], 200)
        self.assertEqual(accepted['body']['family']['name'], '😀' * 40)

    def test_authenticated_opaque_subject_never_normalizes_into_another_identity(self):
        for invalid in ('\ufeffsubject', 'subject\ufeff', '😀' * 129):
            with self.subTest(subject=repr(invalid)):
                with self.assertRaises(GatewayError):
                    self.verifier.sign_for_test(invalid)

    def test_cross_family_cannot_read_or_manage(self):
        unrelated = self.create_family(subject='outsider')
        self.assertEqual(self.call('GET', f'/v1/families/{self.fid}', subject='outsider')['status'], 403)
        self.assertEqual(self.call('POST', f'/v1/families/{self.fid}/members/{self.mid}/revoke', subject='outsider')['status'], 403)

    def test_no_tokens_saved_in_database_or_audit(self):
        invite = self.issue()
        token = invite['url'].rsplit('/', 1)[1]
        self.apply(invite)
        with sqlite3.connect(self.path) as db:
            text = '\n'.join(db.iterdump())
        self.assertNotIn(token, text)
        self.assertIn(hashlib.sha256(token.encode()).hexdigest(), text)
        events = self.call('GET', f'/v1/families/{self.fid}/audit')['body']['events']
        self.assertNotIn(token, json.dumps(events))

    def test_rate_and_body_limits_are_explicit(self):
        app = self.make_app(requests_per_minute=1)
        # Separate synthetic subject avoids previous setup's rate count.
        self.assertEqual(self.call('GET', '/v1/families', subject='new', app=app)['status'], 200)
        self.assertEqual(self.call('GET', '/v1/families', subject='new', app=app)['status'], 429)
        self.assertEqual(self.call('POST', '/v1/families', raw=b'x'*65537)['status'], 413)
        self.assertEqual(self.call('POST', '/v1/families', raw=b'{bad')['status'], 400)
        self.assertEqual(self.call('POST', '/v1/families', raw=b'{}', content_type='text/plain')['status'], 400)


if __name__ == '__main__':
    unittest.main()
