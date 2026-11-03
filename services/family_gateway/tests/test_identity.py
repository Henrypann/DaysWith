import base64
import hashlib
import io
import json
import secrets
import tempfile
import time
import unittest
from pathlib import Path

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.primitives import hashes

from services.family_gateway.gateway import Gateway
from services.family_gateway.identity import OidcJwtVerifier, IdentityVerificationError


def b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b'=').decode()


class IdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        cls.other = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    def setUp(self):
        self.now = int(time.time())
        self.fetches = []
        self.jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(self.key.public_key()))
        self.jwk.update(kid='synthetic-key', alg='RS256', use='sig')
        self.keys = {'keys': [self.jwk]}
        self.verifier = self.make()

    def fetch(self, url):
        self.fetches.append(url)
        return json.dumps(self.keys).encode()

    def make(self, **options):
        return OidcJwtVerifier(issuer='https://identity.example.test/tenant',
                               audience='dayswith-family-gateway',
                               jwks_url='https://keys.example.test/jwks',
                               fetch_jwks=self.fetch, clock=lambda: self.now, **options)

    def claims(self, **changes):
        data = {'iss': 'https://identity.example.test/tenant', 'aud': 'dayswith-family-gateway',
                'sub': 'synthetic-subject', 'iat': self.now - 1, 'exp': self.now + 299}
        data.update(changes)
        return data

    def token(self, **changes):
        return jwt.encode(self.claims(**changes), self.key, algorithm='RS256',
                          headers={'kid': 'synthetic-key'})

    def manual(self, header=None, raw_payload=None):
        h = b64(json.dumps(header or {'alg': 'RS256', 'typ': 'JWT', 'kid': 'synthetic-key'}).encode())
        p = b64(raw_payload or json.dumps(self.claims()).encode())
        text = (h + '.' + p).encode()
        return text.decode() + '.' + b64(self.key.sign(text, padding.PKCS1v15(), hashes.SHA256()))

    def denied(self, token, verifier=None):
        with self.assertRaises(IdentityVerificationError) as error:
            (verifier or self.verifier)(token)
        self.assertEqual(str(error.exception), 'unauthenticated')
        self.assertNotIn(token, repr(error.exception))

    def test_valid_signature_has_stable_issuer_scoped_subject_and_key_cache(self):
        token = self.token()
        subject = self.verifier(token)
        expected = 'oidc:' + hashlib.sha256(json.dumps(
            ['https://identity.example.test/tenant', 'synthetic-subject'], separators=(',', ':')).encode()).hexdigest()
        self.assertEqual(subject, expected)
        self.assertEqual(self.verifier(token), subject)
        self.assertEqual(len(self.fetches), 1)
        self.assertNotEqual(self.verifier(self.token(sub='other-subject')), subject)

    def test_wrong_issuer_audience_signature_or_missing_required_claim_fail(self):
        for changes in [{'iss': 'https://attacker.example'}, {'aud': 'other-client'},
                        {'aud': ['dayswith-family-gateway']}, {'exp': self.now},
                        {'iat': self.now + 100}, {'nbf': self.now + 100},
                        {'exp': self.now + 3601}, {'sub': ' synthetic'}, {'sub': 'bad\nsubject'}]:
            with self.subTest(changes=changes):
                self.denied(self.token(**changes))
        for field in ('iss', 'aud', 'sub', 'exp', 'iat'):
            claims = self.claims()
            del claims[field]
            self.denied(self.manual(raw_payload=json.dumps(claims).encode()))
        self.denied(jwt.encode(self.claims(), self.other, algorithm='RS256', headers={'kid': 'synthetic-key'}))

    def test_header_algorithm_and_remote_key_injection_are_rejected_before_fetch(self):
        for header in [{'alg': 'none'}, {'alg': 'HS256'}, {'alg': 'RS256', 'jku': 'https://attacker.test/keys'},
                       {'alg': 'RS256', 'jwk': self.jwk}, {'alg': 'RS256', 'crit': []},
                       {'alg': 'RS256', 'typ': 'unexpected'}]:
            final = {'typ': 'JWT', 'kid': 'synthetic-key', **header}
            self.denied(self.manual(header=final))
        self.assertEqual(self.fetches, [])

    def test_duplicate_or_nonfinite_claims_and_noncanonical_segments_rejected(self):
        raw = json.dumps(self.claims())[:-1] + ',"sub":"other"}'
        self.denied(self.manual(raw_payload=raw.encode()))
        self.denied(self.manual(raw_payload=b'{"exp":NaN}'))
        self.denied(self.token() + '=')
        self.denied('bad token\r\n')
        self.denied('a' * 8193)

    def test_unknown_kid_cannot_force_unbounded_refresh(self):
        original_token = self.token()
        self.verifier(original_token)
        for i in range(4):
            self.denied(self.manual(header={'alg': 'RS256', 'typ': 'JWT', 'kid': 'missing-' + str(i)}))
        self.assertEqual(len(self.fetches), 1)
        self.now += 31
        self.denied(self.manual(header={'alg': 'RS256', 'typ': 'JWT', 'kid': 'missing'}))
        self.assertEqual(len(self.fetches), 2)
        self.assertEqual(self.verifier(original_token), self.verifier(original_token))

    def test_jwks_duplicates_private_fields_and_small_keys_fail_closed(self):
        small = rsa.generate_private_key(public_exponent=65537, key_size=1024)
        small_jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(small.public_key()))
        cases = [[self.jwk, self.jwk], [dict(self.jwk, d='synthetic-private-field')],
                 [dict(self.jwk, key_ops=['sign'])], [dict(small_jwk, kid='synthetic-key')]]
        for keys in cases:
            self.keys = {'keys': keys}
            self.denied(self.token(), self.make())

    def test_fetch_failure_is_redacted_and_invalidated_cache_cannot_authorize(self):
        self.verifier(self.token())
        self.verifier.invalidate_keys()
        def fail(_):
            raise RuntimeError('synthetic-sensitive-provider-response')
        self.verifier.fetch = fail
        self.denied(self.token())
        self.denied(self.token())
        self.assertNotIn('synthetic-sensitive-provider-response', repr(self.verifier))

    def test_https_identity_config_requires_explicit_bounded_fixed_values(self):
        for url in ['http://issuer.test', 'https://user:password@issuer.test', 'https://issuer.test?x',
                    'https://issuer.test#', 'https://issuer.test:bad', 'https://issuer.test/\n']:
            with self.assertRaises(ValueError):
                OidcJwtVerifier(issuer=url, audience='gateway', jwks_url='https://keys.test/jwks')
        with self.assertRaises(ValueError): self.make(max_lifetime_seconds=86400)
        with self.assertRaises(ValueError): self.make(cache_seconds=0)

    def test_verified_identity_can_be_injected_into_gateway_without_synthetic_auth(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Gateway(Path(directory) / 'gateway.sqlite3', origin='https://family.example.test',
                          verify_bearer=self.verifier)
            body = json.dumps({'name': 'Synthetic family', 'displayName': 'Parent',
                               'relationshipLabel': '家人', 'deviceID': '11111111-1111-4111-8111-111111111111'}).encode()
            env = {'REQUEST_METHOD': 'POST', 'PATH_INFO': '/v1/families', 'QUERY_STRING': '',
                   'wsgi.url_scheme': 'https', 'HTTP_HOST': 'family.example.test',
                   'wsgi.input': io.BytesIO(body), 'CONTENT_LENGTH': str(len(body)),
                   'CONTENT_TYPE': 'application/json', 'HTTP_AUTHORIZATION': 'Bearer ' + self.token()}
            response = {}
            data = b''.join(app(env, lambda status, headers: response.update(status=status)))
            self.assertTrue(response['status'].startswith('200'))
            self.assertEqual(json.loads(data)['currentMember']['subjectID'], self.verifier(self.token()))
