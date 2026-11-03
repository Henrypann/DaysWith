"""Offline OIDC adversarial/cache tests using ephemeral signing keys only."""

import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import time
import unittest

import jwt
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from services.family_gateway.identity import OidcJwtVerifier, IdentityVerificationError


def b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b'=').decode('ascii')


class IdentitySecurityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.first_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        cls.second_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    def setUp(self):
        self.issued_now = int(time.time())
        self.now = self.issued_now
        self.fetches = []
        self.first_jwk = self.public_jwk(self.first_key)
        self.keys = {'keys': [self.first_jwk]}
        self.response_encoding = 'utf-8'
        self.fetch_error = None
        self.verifier = self.make()

    @staticmethod
    def public_jwk(key, kid='synthetic-key'):
        value = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
        return dict(value, kid=kid, alg='RS256', use='sig')

    def fetch(self, url):
        self.fetches.append(url)
        if self.fetch_error is not None:
            raise self.fetch_error
        return json.dumps(self.keys).encode(self.response_encoding)

    def make(self, **options):
        options = {'cache_seconds': 3, 'minimum_refresh_seconds': 1, **options}
        return OidcJwtVerifier(
            issuer='https://identity.example.test/tenant', audience='synthetic-gateway',
            jwks_url='https://keys.example.test/jwks', fetch_jwks=self.fetch,
            clock=lambda: self.now, **options,
        )

    def claims(self, **changes):
        value = {'iss': 'https://identity.example.test/tenant', 'aud': 'synthetic-gateway',
                 'sub': 'synthetic-subject', 'iat': self.issued_now - 1,
                 'exp': self.issued_now + 299}
        value.update(changes)
        return value

    def token(self, *, key=None, header=None, raw_header=None, raw_claims=None, **claims):
        header = header or {'alg': 'RS256', 'typ': 'JWT', 'kid': 'synthetic-key'}
        encoded_header = b64(raw_header if raw_header is not None else json.dumps(header).encode())
        encoded_claims = b64(raw_claims if raw_claims is not None else json.dumps(self.claims(**claims)).encode())
        signing = (encoded_header + '.' + encoded_claims).encode('ascii')
        signature = (key or self.first_key).sign(signing, padding.PKCS1v15(), hashes.SHA256())
        return signing.decode('ascii') + '.' + b64(signature)

    def denied(self, token, verifier=None):
        with self.assertRaises(IdentityVerificationError) as caught:
            (verifier or self.verifier)(token)
        self.assertEqual(str(caught.exception), 'unauthenticated')
        self.assertIsNone(caught.exception.__cause__)
        return caught.exception

    def test_signed_non_utf8_header_or_claims_are_rejected_before_key_fetch(self):
        header = {'alg': 'RS256', 'typ': 'JWT', 'kid': 'synthetic-key'}
        for encoding in ('utf-16', 'utf-32'):
            for section in ('header', 'claims'):
                with self.subTest(encoding=encoding, section=section):
                    options = (
                        {'raw_header': json.dumps(header).encode(encoding)}
                        if section == 'header'
                        else {'raw_claims': json.dumps(self.claims()).encode(encoding)}
                    )
                    self.denied(self.token(**options))
        self.assertEqual(self.fetches, [])

    def test_non_utf8_jwks_is_rejected_and_failure_refresh_is_throttled(self):
        for encoding in ('utf-16', 'utf-32'):
            with self.subTest(encoding=encoding):
                self.response_encoding = encoding
                verifier = self.make()
                before = len(self.fetches)
                self.denied(self.token(), verifier)
                self.denied(self.token(), verifier)
                self.assertEqual(len(self.fetches) - before, 1)

    def test_utf8_unicode_subject_is_bound_without_rewriting_its_identity(self):
        subject = 'synthetic-外婆'
        token = self.token(sub=subject)
        expected = 'oidc:' + hashlib.sha256(json.dumps(
            ['https://identity.example.test/tenant', subject],
            ensure_ascii=False, separators=(',', ':'),
        ).encode('utf-8')).hexdigest()
        self.assertEqual(self.verifier(token), expected)

    def test_expired_jwks_cache_cannot_authorize_when_refresh_fails(self):
        token = self.token()
        self.verifier(token)
        self.now += 3
        self.fetch_error = OSError('SYNTHETIC_PRIVATE_IDENTITY_NETWORK_RESPONSE')
        self.denied(token)
        self.denied(token)
        self.assertEqual(len(self.fetches), 2)
        self.now += 1
        self.denied(token)
        self.assertEqual(len(self.fetches), 3)

    def test_key_rotation_replaces_old_key_after_bounded_cache_window(self):
        original = self.token()
        replacement = self.token(key=self.second_key)
        subject = self.verifier(original)
        self.keys = {'keys': [self.public_jwk(self.second_key)]}
        # Before expiry only the already cached key is accepted. A changed
        # signature cannot force a fetch or a fallback to untrusted key input.
        self.denied(replacement)
        self.assertEqual(self.verifier(original), subject)
        self.assertEqual(len(self.fetches), 1)
        self.now += 3
        self.assertEqual(self.verifier(replacement), subject)
        self.denied(original)
        self.assertEqual(len(self.fetches), 2)

    def test_simultaneous_unknown_kids_trigger_at_most_one_refresh(self):
        original = self.token()
        self.verifier(original)
        self.now += 1
        tokens = [self.token(header={'alg': 'RS256', 'typ': 'JWT', 'kid': f'absent-{n}'})
                  for n in range(12)]

        def request(token):
            try:
                self.verifier(token)
                return 'authorized'
            except IdentityVerificationError:
                return 'denied'

        with ThreadPoolExecutor(max_workers=2) as pool:
            self.assertEqual(list(pool.map(request, tokens)), ['denied'] * 12)
        self.assertEqual(len(self.fetches), 2)
        self.assertTrue(self.verifier(original).startswith('oidc:'))

    def test_cache_does_not_extend_token_expiration_at_boundary(self):
        verifier = self.make(cache_seconds=300)
        token = self.token(exp=self.issued_now + 30)
        verifier(token)
        self.now += 30
        self.denied(token, verifier)
        # The public key still being cached must not keep a session alive.
        self.assertEqual(len(self.fetches), 1)

    def test_numeric_date_booleans_fractional_and_overlong_sessions_are_denied(self):
        for claims in (
            {'iat': True}, {'exp': True}, {'nbf': False},
            {'iat': float(self.issued_now - 1)}, {'exp': float(self.issued_now + 299)},
            {'nbf': float(self.issued_now - 1)},
            {'iat': self.issued_now - 1, 'exp': self.issued_now + 900},
        ):
            with self.subTest(claims=claims):
                self.denied(self.token(**claims))

    def test_duplicate_header_and_token_key_urls_fail_before_fetch(self):
        duplicate = b'{"alg":"RS256","typ":"JWT","kid":"synthetic-key","kid":"synthetic-key"}'
        self.denied(self.token(raw_header=duplicate))
        for name in ('jku', 'x5u', 'jwk', 'crit', 'b64'):
            with self.subTest(header=name):
                self.denied(self.token(header={
                    'alg': 'RS256', 'typ': 'JWT', 'kid': 'synthetic-key',
                    name: 'https://untrusted.example/never-fetch',
                }))
        self.assertEqual(self.fetches, [])

    def test_role_and_member_claims_do_not_change_server_subject_binding(self):
        subject = self.verifier(self.token())
        noisy = self.token(role='admin', familyID='synthetic-other-family',
                           memberID='synthetic-other-member', subjectID='synthetic-owner')
        self.assertEqual(self.verifier(noisy), subject)

    def test_network_exception_payload_is_not_retained_as_public_error(self):
        sentinel = 'SYNTHETIC_PRIVATE_JWKS_RESPONSE'
        self.fetch_error = RuntimeError(sentinel)
        error = self.denied(self.token())
        self.assertNotIn(sentinel, str(error))
        self.assertNotIn(sentinel, repr(error))
        self.assertTrue(error.__suppress_context__)
        self.assertEqual(len(self.fetches), 1)


if __name__ == '__main__':
    unittest.main()
