"""Explicit, opt-in Tencent official STS SDK callback; no live/default issuer.

GetFederationToken uses URL-encoded Policy per the official API contract. The
only accepted policy is the gateway's configured-family read-only COS policy.
"""
from __future__ import annotations

import importlib.metadata
import json
import re
import secrets
import time
from urllib.parse import quote

from .storage import CosScope, StorageError, cos_policy

_SDK_VERSION = '3.0.1459'
_ENDPOINTS = {'sts.tencentcloudapi.com', 'sts.intl.tencentcloudapi.com'}


def _sdk():
    try:
        for package in ('tencentcloud-sdk-python-sts', 'tencentcloud-sdk-python-common'):
            if importlib.metadata.version(package) != _SDK_VERSION:
                raise ImportError()
        from tencentcloud.common.credential import Credential
        from tencentcloud.common.profile.http_profile import HttpProfile
        from tencentcloud.common.profile.client_profile import ClientProfile
        from tencentcloud.sts.v20180813 import models, sts_client
        return Credential, HttpProfile, ClientProfile, models, sts_client
    except (ImportError, importlib.metadata.PackageNotFoundError):
        raise StorageError('stsNotConfigured') from None


class TencentCosStsCallback:
    """Callable for RestrictedStsIssuer. No credentials or requests by default."""
    def __init__(self, scope: CosScope, *, client=None, enabled=False, clock=time.time):
        if not isinstance(scope, CosScope) or type(enabled) is not bool:
            raise ValueError('explicit COS scope and boolean enable flag required')
        self.scope, self._client = scope, client
        self._enabled, self._clock = enabled, clock
        self._client_factory = None

    def __repr__(self):
        return 'TencentCosStsCallback(redacted)'

    @classmethod
    def from_credential_provider(cls, scope, credential_provider, *, enabled=False,
                                 endpoint='sts.tencentcloudapi.com', region='',
                                 timeout=10, clock=time.time):
        if (endpoint not in _ENDPOINTS or type(timeout) is not int or not 1 <= timeout <= 10 or
                not callable(credential_provider)):
            raise ValueError('explicit HTTPS STS endpoint and bounded provider required')
        selected_region = region or scope.region
        if not isinstance(selected_region, str) or not re.fullmatch(r'[a-z]{2}-[a-z0-9-]{1,40}', selected_region):
            raise ValueError('explicit STS region required')
        callback = cls(scope, enabled=enabled, clock=clock)
        def build():
            Credential, HttpProfile, ClientProfile, _, sts_client = _sdk()
            try:
                credential = credential_provider()
            except Exception:
                raise StorageError('stsUnavailable') from None
            if not isinstance(credential, Credential) or credential.token is not None:
                raise StorageError('stsUnavailable')
            http = HttpProfile(protocol='https', endpoint=endpoint, reqMethod='POST',
                               reqTimeout=timeout, keepAlive=False)
            profile = ClientProfile(signMethod='TC3-HMAC-SHA256', httpProfile=http,
                                    disable_region_breaker=True, retryer=None)
            try:
                return sts_client.StsClient(credential, selected_region, profile=profile)
            except Exception:
                raise StorageError('stsUnavailable') from None
        callback._client_factory = build
        return callback

    def _validate_policy(self, policy):
        try:
            if not isinstance(policy, dict) or set(policy) != {'version', 'statement'}:
                raise ValueError()
            statements = policy['statement']
            if not isinstance(statements, list) or len(statements) != 1:
                raise ValueError()
            statement = statements[0]
            if not isinstance(statement, dict) or set(statement) != {'effect', 'action', 'resource'}:
                raise ValueError()
            resources = statement['resource']
            if not isinstance(resources, list) or len(resources) != 1 or not isinstance(resources[0], str):
                raise ValueError()
            prefix = f'qcs::cos:{self.scope.region}:uid/{self.scope.appid}:{self.scope.bucket}/family/v1/'
            match = re.fullmatch(re.escape(prefix) + r'([0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12})/members/\*/objects/\*', resources[0])
            if not match:
                raise ValueError()
            expected = cos_policy(self.scope, match.group(1), match.group(1), 'viewer')
            if policy != expected:
                raise ValueError()
            encoded = json.dumps(policy, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
            if len(encoded.encode()) > 8192:
                raise ValueError()
            return quote(encoded, safe='')
        except (ValueError, TypeError, KeyError, UnicodeError, RecursionError):
            raise StorageError('invalidStsPolicy') from None

    def __call__(self, policy, duration_seconds):
        if not self._enabled:
            raise StorageError('stsNotConfigured')
        if type(duration_seconds) is not int or not 1 <= duration_seconds <= 600:
            raise StorageError('invalidDuration')
        encoded_policy = self._validate_policy(policy)
        started = int(self._clock())
        try:
            _, _, _, models, _ = _sdk()
            client = self._client or (self._client_factory() if self._client_factory else None)
            if client is None:
                raise StorageError('stsNotConfigured')
            request = models.GetFederationTokenRequest()
            # Name is letters-only per API, randomized without family/subject IDs.
            request.Name = 'dayswith' + ''.join(secrets.choice('abcdefghijklmnopqrstuvwxyz') for _ in range(24))
            request.Policy = encoded_policy
            request.DurationSeconds = duration_seconds
            try:
                response = client.GetFederationToken(request)
            except Exception:
                raise StorageError('stsUnavailable') from None
            credentials, expiry = response.Credentials, response.ExpiredTime
            values = {'tmpSecretId': credentials.TmpSecretId,
                      'tmpSecretKey': credentials.TmpSecretKey,
                      'sessionToken': credentials.Token}
            bounds = {'tmpSecretId': 1024, 'tmpSecretKey': 1024, 'sessionToken': 4096}
            if (type(expiry) is not int or not int(self._clock()) < expiry <= started + duration_seconds or
                    any(not isinstance(value, str) or not value or
                        len(value.encode('utf-8')) > bounds[key] or
                        any(ord(c) < 33 or ord(c) == 127 for c in value)
                        for key, value in values.items())):
                raise StorageError('invalidStsResponse')
            return {'credentials': values, 'expiredTime': expiry}
        except StorageError:
            raise
        except Exception:
            # Never expose SDK response, request IDs, credentials or provider text.
            raise StorageError('stsUnavailable') from None
