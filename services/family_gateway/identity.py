"""Optional RS256/OIDC bearer verification; never a login or local role issuer.

Issuer, audience and JWKS URL are operator configuration, never token/QR input.
Install requirements-auth.txt before enabling. No network runs on import.
"""
from __future__ import annotations

import base64
import hashlib
import json
import re
import threading
import time
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


class IdentityVerificationError(Exception):
    def __init__(self):
        super().__init__('unauthenticated')


def _deny():
    raise IdentityVerificationError() from None


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            _deny()
        result[key] = value
    return result


def _json(raw):
    try:
        return json.loads(raw.decode('utf-8'), object_pairs_hook=_unique,
                          parse_constant=lambda _: _deny())
    except (ValueError, TypeError, UnicodeError, RecursionError):
        _deny()


def _https_url(value):
    try:
        u = urlsplit(value)
        if (not isinstance(value, str) or u.scheme != 'https' or not u.hostname or
                u.username is not None or u.password is not None or '?' in value or
                '#' in value or '%' in u.netloc or '\\' in value or
                any(ord(c) < 33 or ord(c) == 127 for c in value) or
                u.port is not None and not 1 <= u.port <= 65535):
            raise ValueError()
        return value
    except (ValueError, TypeError, AttributeError):
        raise ValueError('fixed HTTPS identity URL required') from None


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _fetch_jwks(url):
    # Uses inherited proxy and the platform trust store. No issuer discovery,
    # JWT jku/x5u lookup, arbitrary redirect, bearer, or TLS override is allowed.
    req = Request(url, headers={'Accept': 'application/json'}, method='GET')
    with build_opener(_NoRedirect()).open(req, timeout=10) as response:
        if response.status != 200:
            _deny()
        raw = response.read(65537)
        if len(raw) > 65536:
            _deny()
        return raw


class OidcJwtVerifier:
    """Verify one explicitly configured issuer/audience using public RS256 keys.

    This adapter checks a JWT, not whether the issuer session has been remotely
    revoked. Short token lifetime bounds that window; Gateway membership remains
    checked on every request/chunk. External login, account recovery, TLS/Host and
    JWKS host access are operator setup and are not provisioned here.
    """
    def __init__(self, *, issuer: str, audience: str, jwks_url: str,
                 max_lifetime_seconds=900, cache_seconds=300,
                 minimum_refresh_seconds=30, fetch_jwks=None, clock=time.time):
        try:
            import jwt
            from cryptography.hazmat.primitives.asymmetric import rsa
            version = tuple(int(p) for p in jwt.__version__.split('.')[:3])
            if not (2, 15, 1) <= version < (3, 0, 0):
                raise ValueError()
        except (ImportError, AttributeError, ValueError):
            raise RuntimeError('install the pinned optional identity requirements') from None
        self.issuer, self.jwks_url = _https_url(issuer), _https_url(jwks_url)
        if (not isinstance(audience, str) or not 1 <= len(audience) <= 256 or
                any(ord(c) < 33 or ord(c) == 127 for c in audience)):
            raise ValueError('fixed identity audience required')
        if (type(max_lifetime_seconds) is not int or not 1 <= max_lifetime_seconds <= 3600 or
                type(cache_seconds) is not int or not 1 <= cache_seconds <= 3600 or
                type(minimum_refresh_seconds) is not int or
                not 1 <= minimum_refresh_seconds <= cache_seconds):
            raise ValueError('bounded identity lifetime/cache required')
        self.audience = audience
        self.max_lifetime = max_lifetime_seconds
        self.cache_seconds = cache_seconds
        self.minimum_refresh = minimum_refresh_seconds
        self.fetch = fetch_jwks or _fetch_jwks
        self.clock = clock
        self._keys, self._expires, self._last_fetch = {}, 0, float('-inf')
        self._lock = threading.RLock()

    def __repr__(self):
        return 'OidcJwtVerifier(configured, redacted)'

    def invalidate_keys(self):
        """Explicit host action to discard keys, including after issuer rotation."""
        with self._lock:
            self._keys, self._expires, self._last_fetch = {}, 0, float('-inf')

    def _key(self, kid, jwt):
        with self._lock:
            now = self.clock()
            if now >= self._expires or (kid not in self._keys and
                                        now - self._last_fetch >= self.minimum_refresh):
                # Throttle failures too; unknown attacker-controlled kid values
                # must not initiate an unbounded series of issuer requests.
                self._last_fetch = now
                self._expires = now + self.minimum_refresh
                self._keys = {}
                raw = self.fetch(self.jwks_url)
                if not isinstance(raw, bytes) or len(raw) > 65536:
                    _deny()
                data = _json(raw)
                if (not isinstance(data, dict) or not isinstance(data.get('keys'), list) or
                        not 1 <= len(data['keys']) <= 20):
                    _deny()
                keys, seen = {}, set()
                for key in data['keys']:
                    if not isinstance(key, dict):
                        _deny()
                    key_id = key.get('kid')
                    if (not isinstance(key_id, str) or not re.fullmatch(r'[A-Za-z0-9._-]{1,128}', key_id) or
                            key_id in seen):
                        _deny()
                    seen.add(key_id)
                    if key.get('kty') != 'RSA' or key.get('use', 'sig') != 'sig' or key.get('alg', 'RS256') != 'RS256':
                        continue
                    if (any(part in key for part in ('d', 'p', 'q', 'dp', 'dq', 'qi', 'oth')) or
                            'key_ops' in key and key['key_ops'] != ['verify']):
                        _deny()
                    public = jwt.PyJWK.from_dict(key, algorithm='RS256').key
                    if not 2048 <= public.key_size <= 8192 or public.public_numbers().e != 65537:
                        _deny()
                    keys[key_id] = public
                if not keys:
                    _deny()
                self._keys, self._expires = keys, now + self.cache_seconds
            key = self._keys.get(kid)
            if key is None:
                _deny()
            return key

    def __call__(self, token):
        try:
            import jwt
            if not isinstance(token, str) or len(token) > 8192 or not re.fullmatch(r'[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', token):
                _deny()
            sections = token.split('.')
            # Reject duplicate header and claim names before asking PyJWT to
            # verify. Header data only selects a preconfigured public key.
            def section(value):
                raw = base64.urlsafe_b64decode(value + '=' * (-len(value) % 4))
                if base64.urlsafe_b64encode(raw).rstrip(b'=').decode() != value:
                    _deny()
                return _json(raw)
            header, untrusted_claims = section(sections[0]), section(sections[1])
            if (not isinstance(header, dict) or not isinstance(untrusted_claims, dict) or
                    header.get('alg') != 'RS256' or header.get('typ') not in ('JWT', 'at+jwt') or
                    any(k in header for k in ('jku', 'jwk', 'x5u', 'crit', 'b64')) or
                    not isinstance(header.get('kid'), str) or
                    not re.fullmatch(r'[A-Za-z0-9._-]{1,128}', header['kid'])):
                _deny()
            key = self._key(header['kid'], jwt)
            claims = jwt.decode(token, key, algorithms=['RS256'], issuer=self.issuer,
                                audience=self.audience,
                                options={'require': ['iss', 'aud', 'sub', 'exp', 'iat'], 'strict_aud': True})
            now = self.clock()
            if (type(claims['iat']) is not int or type(claims['exp']) is not int or
                    not claims['iat'] <= now < claims['exp'] or
                    not 1 <= claims['exp'] - claims['iat'] <= self.max_lifetime or
                    'nbf' in claims and (type(claims['nbf']) is not int or claims['nbf'] > now)):
                _deny()
            subject = claims['sub']
            if (not isinstance(subject, str) or not 1 <= len(subject) <= 256 or subject != subject.strip() or
                    any(ord(c) < 32 or ord(c) == 127 for c in subject)):
                _deny()
            # Avoid collisions between equal external subjects from different
            # issuers; do not store raw provider identifiers in membership rows.
            binding = json.dumps([self.issuer, subject], ensure_ascii=False, separators=(',', ':')).encode()
            return 'oidc:' + hashlib.sha256(binding).hexdigest()
        except IdentityVerificationError:
            raise
        except Exception:
            # Never retain JWT/JWKS/provider exception payloads in traceback text.
            raise IdentityVerificationError() from None
