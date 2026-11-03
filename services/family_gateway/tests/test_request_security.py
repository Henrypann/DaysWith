"""Synthetic WSGI boundary regressions; no listener, issuer or real media."""

import hashlib
import io
import json
from pathlib import Path
import secrets
import tempfile
import unittest
from unittest.mock import patch
import uuid

from services.family_gateway.gateway import Gateway, SyntheticHmacVerifier
from services.family_gateway.storage import ObjectStore, StorageError


def identifier():
    return str(uuid.uuid4()).upper()


class _ObservedInput(io.BytesIO):
    def __init__(self, body=b''):
        super().__init__(body)
        self.read_calls = []

    def read(self, length=-1):
        self.read_calls.append(length)
        return super().read(length)


class RequestSecurityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'request-security.sqlite3'
        self.now = 1900000000
        self.verifier = SyntheticHmacVerifier(
            secrets.token_bytes(32), synthetic_only=True, clock=lambda: self.now,
        )
        self.store = ObjectStore(Path(self.temp.name) / 'objects', max_bytes=1024)
        self.app = self.make_app()
        self.owner = 'synthetic-issuer|parent'

    def make_app(self, **options):
        return Gateway(
            self.path, origin='https://family.example.test',
            verify_bearer=options.pop('verify_bearer', self.verifier),
            clock=lambda: self.now, object_store=self.store, **options,
        )

    def call(self, method, path, body=None, *, raw=None, subject=None,
             authorization=None, environ=None, app=None):
        if raw is None:
            raw = json.dumps(body or {}).encode() if method in ('POST', 'PUT') else b''
        env = {
            'REQUEST_METHOD': method, 'PATH_INFO': path, 'QUERY_STRING': '',
            'HTTP_HOST': 'family.example.test', 'SERVER_NAME': 'family.example.test',
            'SERVER_PORT': '443', 'wsgi.url_scheme': 'https',
            'wsgi.input': io.BytesIO(raw), 'CONTENT_LENGTH': str(len(raw)),
            'CONTENT_TYPE': 'application/json',
            'HTTP_AUTHORIZATION': authorization if authorization is not None else
                'Bearer ' + self.verifier.sign_for_test(subject or self.owner),
        }
        for key, value in (environ or {}).items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
        response = {}

        def start(status, headers):
            response['status'] = int(status.split()[0])
            response['headers'] = dict(headers)

        chunks = (app or self.app)(env, start)
        try:
            response['raw'] = b''.join(chunks)
        finally:
            if hasattr(chunks, 'close'):
                chunks.close()
        response['body'] = (
            json.loads(response['raw'])
            if response['headers'].get('Content-Type', '').startswith('application/json')
            else response['raw']
        )
        return response

    def family_body(self):
        return {'name': 'Synthetic family', 'displayName': 'Parent',
                'relationshipLabel': '爸爸', 'deviceID': identifier()}

    def create_family(self):
        response = self.call('POST', '/v1/families', self.family_body())
        self.assertEqual(response['status'], 200, response['body'])
        return response['body']

    def assert_private_error(self, response, status, code):
        self.assertEqual(response['status'], status, response['body'])
        self.assertEqual(response['body'], {'error': code})
        self.assertEqual(response['headers']['Cache-Control'], 'no-store')
        self.assertEqual(response['headers']['X-Content-Type-Options'], 'nosniff')

    def test_unknown_authority_fields_cannot_override_authenticated_actor(self):
        for field in ('subjectID', 'actor', 'role', 'ownerMemberID', 'permissions'):
            with self.subTest(field=field):
                body = dict(self.family_body(), **{field: self.owner})
                response = self.call('POST', '/v1/families', body, subject='synthetic-guest')
                self.assert_private_error(response, 400, 'invalidRequest')
        families = self.call('GET', '/v1/families', subject='synthetic-guest')
        self.assertEqual(families['body'], {'families': []})

    def test_json_duplicate_fields_are_rejected_without_creating_state(self):
        body = self.family_body()
        canonical = json.dumps(body, separators=(',', ':'))
        samples = [
            '{"name":"hidden",' + canonical[1:],
            canonical[:-1] + ',"deviceID":' + json.dumps(body['deviceID']) + '}',
        ]
        for raw in samples:
            with self.subTest(raw=raw[:30]):
                response = self.call('POST', '/v1/families', raw=raw.encode())
                self.assert_private_error(response, 400, 'invalidRequest')
        self.assertEqual(self.call('GET', '/v1/families')['body'], {'families': []})

    def test_nested_json_duplicates_are_not_accepted_as_record_content(self):
        family = self.create_family()['family']['id']
        record = identifier()
        raw = ('{"id":"' + record + '","content":{"text":"one","text":"two"}}').encode()
        response = self.call('POST', f'/v1/families/{family}/records', raw=raw)
        self.assert_private_error(response, 400, 'invalidRequest')
        self.assertEqual(self.call('GET', f'/v1/families/{family}/records')['body'], {'records': []})

    def test_nonfinite_and_overflow_json_numbers_are_input_errors(self):
        family = self.create_family()['family']['id']
        for number in ('NaN', 'Infinity', '-Infinity', '1e999', '-1e999'):
            with self.subTest(number=number):
                raw = ('{"id":"' + identifier() + '","content":{"number":' + number + '}}').encode()
                response = self.call('POST', f'/v1/families/{family}/records', raw=raw)
                self.assert_private_error(response, 400, 'invalidRequest')
        self.assertEqual(self.call('GET', f'/v1/families/{family}/records')['body'], {'records': []})

    def test_metadata_json_requires_utf8_and_rejects_unpaired_surrogates(self):
        payload = json.dumps(self.family_body())
        samples = [payload.encode('utf-16'), payload.encode('utf-32'),
                   payload.replace('Synthetic family', '\\ud800').encode('utf-8')]
        for raw in samples:
            with self.subTest(prefix=raw[:8]):
                response = self.call('POST', '/v1/families', raw=raw)
                self.assert_private_error(response, 400, 'invalidRequest')
        self.assertEqual(self.call('GET', '/v1/families')['body'], {'families': []})

    def test_deep_or_malformed_json_never_escapes_wsgi_or_changes_state(self):
        for raw in (b'{bad', b'[', b'{"name":"\xff"}', b'[' * 1200 + b']' * 1200):
            with self.subTest(prefix=raw[:8]):
                response = self.call('POST', '/v1/families', raw=raw)
                self.assert_private_error(response, 400, 'invalidRequest')

    def test_bearer_controls_and_unicode_are_rejected_before_verifier(self):
        received = []

        def permissive_adapter(token):
            # Even a provider adapter that normalizes whitespace must not turn
            # an ambiguous or non-ASCII HTTP bearer token into a valid actor.
            received.append(token)
            return self.owner

        app = self.make_app(verify_bearer=permissive_adapter)
        for token in ('synthetic\n', '\tsynthetic', ' synthetic',
                      'synthetic\u200b', 'synthetic\u0085', 'synthetic\x00'):
            with self.subTest(token=repr(token)):
                response = self.call('GET', '/v1/families', authorization='Bearer ' + token, app=app)
                self.assert_private_error(response, 401, 'unauthenticated')
        self.assertEqual(received, [])

    def test_valid_ascii_bearer_is_passed_unchanged_to_verifier(self):
        received = []

        def adapter(token):
            received.append(token)
            return self.owner

        token = 'AbCd_-.~+/09=='
        response = self.call('GET', '/v1/families', authorization='Bearer ' + token,
                             app=self.make_app(verify_bearer=adapter))
        self.assertEqual(response['status'], 200, response['body'])
        self.assertEqual(received, [token])

    def test_missing_or_untrusted_host_is_rejected(self):
        for host in (None, '', 'attacker.example', 'family.example.test.attacker.example',
                     'family.example.test@attacker.example', 'family.example.test\n'):
            with self.subTest(host=host):
                response = self.call('GET', '/v1/families', environ={'HTTP_HOST': host})
                self.assert_private_error(response, 400, 'invalidRequest')

    def test_forwarded_headers_cannot_promote_http_or_spoof_origin(self):
        response = self.call('GET', '/v1/families', environ={
            'wsgi.url_scheme': 'http', 'HTTP_X_FORWARDED_PROTO': 'https',
            'HTTP_FORWARDED': 'proto=https;host=family.example.test',
        })
        self.assert_private_error(response, 400, 'httpsRequired')
        family = self.create_family()['family']['id']
        response = self.call('POST', f'/v1/families/{family}/invitations',
                             {'requestedRole': 'viewer'}, environ={
                                 'HTTP_X_FORWARDED_HOST': 'attacker.example',
                             })
        self.assertEqual(response['status'], 200, response['body'])
        self.assertTrue(response['body']['url'].startswith('https://family.example.test/'))

    def test_ambiguous_paths_and_nonarchive_queries_are_rejected(self):
        for path in ('//v1/families', '/v1//families', '/v1/families/',
                     '/v1/%66amilies', '/v1/families%2Fsecret',
                     '/v1/families;role=admin', '/v1/families/../families'):
            with self.subTest(path=path):
                self.assertEqual(self.call('GET', path)['status'], 404)
        for query in ('role=admin', 'cursor=opaque&limit=1', '%73ubjectID=owner', '='):
            with self.subTest(query=query):
                self.assert_private_error(
                    self.call('GET', '/v1/families', environ={'QUERY_STRING': query}),
                    400, 'invalidRequest',
                )

    def test_unknown_and_sensitive_routes_require_auth_before_reading_body(self):
        family = identifier()
        for method, path in (
            ('GET', '/v1/unknown'), ('GET', '/v1/families'),
            ('POST', f'/v1/families/{family}/credentials'),
            ('PUT', f'/v1/families/{family}/members/{identifier()}/objects/' + '0' * 64),
        ):
            source = _ObservedInput(b'secret body never parsed')
            with self.subTest(path=path):
                response = self.call(method, path, authorization='', environ={'wsgi.input': source})
                self.assert_private_error(response, 401, 'unauthenticated')
                self.assertEqual(source.read_calls, [])

    def test_malformed_content_lengths_and_transfer_encoding_are_rejected_before_read(self):
        for length in ('-1', '+2', '02', '2.0', 'two', '9' * 5000):
            source = _ObservedInput(b'{}')
            with self.subTest(length=length[:20]):
                response = self.call('POST', '/v1/families', raw=b'{}', environ={
                    'CONTENT_LENGTH': length, 'wsgi.input': source,
                })
                self.assert_private_error(response, 400, 'invalidRequest')
                self.assertEqual(source.read_calls, [])
        source = _ObservedInput(json.dumps(self.family_body()).encode())
        response = self.call('POST', '/v1/families', raw=source.getvalue(), environ={
            'HTTP_TRANSFER_ENCODING': 'chunked', 'wsgi.input': source,
        })
        self.assert_private_error(response, 400, 'invalidRequest')
        self.assertEqual(source.read_calls, [])

    def test_json_and_raw_media_size_limits_precede_body_reads(self):
        source = _ObservedInput()
        self.assert_private_error(self.call('POST', '/v1/families', environ={
            'CONTENT_LENGTH': '65537', 'wsgi.input': source,
        }), 413, 'tooLarge')
        self.assertEqual(source.read_calls, [])
        family = self.create_family()
        path = (f'/v1/families/{family["family"]["id"]}/members/'
                f'{family["currentMember"]["id"]}/objects/' + '0' * 64)
        source = _ObservedInput()
        response = self.call('PUT', path, environ={
            'CONTENT_LENGTH': '1025', 'HTTP_X_CONTENT_SHA256': '0' * 64,
            'wsgi.input': source,
        })
        self.assert_private_error(response, 413, 'sizeLimit')
        self.assertEqual(source.read_calls, [])

    def test_raw_media_digest_headers_are_validated_before_read_or_publication(self):
        family = self.create_family()
        data = b'synthetic bounded object'
        digest = hashlib.sha256(data).hexdigest()
        path = (f'/v1/families/{family["family"]["id"]}/members/'
                f'{family["currentMember"]["id"]}/objects/{digest}')
        for supplied in ('', digest.upper(), digest + '\n', 'f' * 64):
            source = _ObservedInput(data)
            with self.subTest(digest=supplied):
                response = self.call('PUT', path, raw=data, environ={
                    'HTTP_X_CONTENT_SHA256': supplied, 'wsgi.input': source,
                })
                self.assertEqual(response['status'], 400)
                self.assertEqual(source.read_calls, [])
                self.assertEqual(self.call('HEAD', path)['status'], 404)

    def test_auth_and_backend_exceptions_return_only_sanitized_errors(self):
        sentinel = 'SYNTHETIC_PRIVATE_PROVIDER_RESPONSE_TOKEN'

        def bad_verifier(token):
            raise RuntimeError(sentinel)

        response = self.call('GET', '/v1/families', app=self.make_app(verify_bearer=bad_verifier))
        self.assert_private_error(response, 401, 'unauthenticated')
        self.assertNotIn(sentinel.encode(), response['raw'])
        family = self.create_family()
        data = b'synthetic backend failure'
        digest = hashlib.sha256(data).hexdigest()
        path = (f'/v1/families/{family["family"]["id"]}/members/'
                f'{family["currentMember"]["id"]}/objects/{digest}')
        for error in (RuntimeError(sentinel), StorageError(sentinel)):
            with self.subTest(error_type=type(error).__name__):
                with patch.object(self.store, 'put', side_effect=error):
                    response = self.call('PUT', path, raw=data,
                                         environ={'HTTP_X_CONTENT_SHA256': digest})
                self.assert_private_error(response, 503, 'unavailable')
                self.assertNotIn(sentinel.encode(), response['raw'])


if __name__ == '__main__':
    unittest.main()
