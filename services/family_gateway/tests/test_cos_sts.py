"""Offline tests against Tencent's real STS request/response models.

All callers, credentials and provider responses below are synthetic. The SDK
client is replaced before construction; no STS endpoint or credential discovery
is contacted by this suite.
"""
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import traceback
import unittest
from unittest.mock import Mock, patch
from urllib.parse import quote, unquote
import uuid

from tencentcloud.common import credential
from tencentcloud.common.exception.tencent_cloud_sdk_exception import TencentCloudSDKException
from tencentcloud.sts.v20180813 import models, sts_client

from services.family_gateway.cos_sts import TencentCosStsCallback
from services.family_gateway.storage import CosScope, RestrictedStsIssuer, StorageError, cos_policy


class FakeStsClient:
    def __init__(self, response):
        self.response = response
        self.requests = []
        self.failure = None

    def GetFederationToken(self, request):
        self.requests.append(request)
        if self.failure:
            raise self.failure
        return self.response(request)


class TencentCosStsTests(unittest.TestCase):
    def setUp(self):
        self.now = 1900000000
        self.scope = CosScope('synthetic-1250000000', 'ap-beijing', '1250000000')
        self.family = str(uuid.uuid4()).upper()
        self.member = str(uuid.uuid4()).upper()
        self.policy = cos_policy(self.scope, self.family, self.member, 'viewer')
        self.client = FakeStsClient(lambda req: self.response(expiry=self.now + req.DurationSeconds))

    def response(self, *, expiry=None, secret_id='synthetic-sts-id',
                 secret_key='synthetic-sts-key', token='synthetic-sts-token'):
        result = models.GetFederationTokenResponse()
        result.Credentials = models.Credentials()
        result.Credentials.TmpSecretId = secret_id
        result.Credentials.TmpSecretKey = secret_key
        result.Credentials.Token = token
        result.ExpiredTime = self.now + 600 if expiry is None else expiry
        result.Expiration = 'ignored; ExpiredTime is the validated authoritative field'
        result.RequestId = 'synthetic-request-id'
        return result

    def adapter(self, **kwargs):
        return TencentCosStsCallback(self.scope, client=self.client, enabled=True,
                                     clock=lambda: self.now, **kwargs)

    def test_default_disabled_never_calls_provider_or_client(self):
        callback = TencentCosStsCallback(self.scope, client=self.client, clock=lambda: self.now)
        with self.assertRaises(StorageError) as caught:
            callback(self.policy, 600)
        self.assertEqual('stsNotConfigured', caught.exception.code)
        self.assertEqual([], self.client.requests)
        provider = Mock(side_effect=AssertionError('credential provider must remain unused'))
        callback = TencentCosStsCallback.from_credential_provider(self.scope, provider)
        with self.assertRaises(StorageError) as caught:
            callback(self.policy, 600)
        self.assertEqual('stsNotConfigured', caught.exception.code)
        provider.assert_not_called()

    def test_enabling_requires_explicit_boolean_configuration(self):
        for value in (1, 'true', None):
            with self.subTest(enabled=value), self.assertRaises(ValueError):
                TencentCosStsCallback(self.scope, client=self.client, enabled=value)
        self.assertEqual([], self.client.requests)

    def test_disabled_import_and_invocation_do_not_import_optional_sdk(self):
        code = '''
import builtins
original = builtins.__import__
def guard(name, *args, **kwargs):
    if name.startswith('tencentcloud'):
        raise AssertionError('disabled adapter tried to import SDK')
    return original(name, *args, **kwargs)
builtins.__import__ = guard
from services.family_gateway.cos_sts import TencentCosStsCallback
from services.family_gateway.storage import CosScope, StorageError
scope = CosScope('synthetic-1250000000', 'ap-beijing', '1250000000')
callback = TencentCosStsCallback.from_credential_provider(scope, lambda: None)
try:
    callback({}, 600)
except StorageError as error:
    assert error.code == 'stsNotConfigured'
else:
    raise AssertionError('disabled adapter did not fail closed')
'''
        completed = subprocess.run([sys.executable, '-c', code], cwd=Path(__file__).resolve().parents[3],
                                   env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'),
                                   timeout=10, capture_output=True)
        self.assertEqual(0, completed.returncode, completed.stderr.decode())

    def test_uses_real_sdk_model_exact_urlencoded_policy_and_safe_random_name(self):
        callback = self.adapter()
        result = callback(self.policy, 600)
        callback(self.policy, 600)
        self.assertEqual(2, len(self.client.requests))
        for request in self.client.requests:
            self.assertIsInstance(request, models.GetFederationTokenRequest)
            expected = json.dumps(self.policy, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
            self.assertEqual(quote(expected, safe=''), request.Policy)
            self.assertEqual(self.policy, json.loads(unquote(request.Policy)))
            self.assertEqual(600, request.DurationSeconds)
            self.assertRegex(request.Name, r'^dayswith[a-z]{24}$')
            self.assertEqual(32, len(request.Name))
            self.assertNotIn(self.family, request.Name)
            self.assertNotIn(self.member, request.Name)
            payload = json.loads(request.to_json_string())
            self.assertEqual({'Name', 'Policy', 'DurationSeconds'}, set(payload))
        self.assertNotEqual(self.client.requests[0].Name, self.client.requests[1].Name)
        self.assertEqual({
            'credentials': {'tmpSecretId': 'synthetic-sts-id', 'tmpSecretKey': 'synthetic-sts-key',
                            'sessionToken': 'synthetic-sts-token'},
            'expiredTime': self.now + 600,
        }, result)

    def test_duration_bounds_are_enforced_before_sdk_call(self):
        callback = self.adapter()
        for invalid in (0, -1, 601, True, False, 1.0, '600', None):
            with self.subTest(duration=invalid), self.assertRaises(StorageError):
                callback(self.policy, invalid)
        self.assertEqual([], self.client.requests)
        self.assertEqual(self.now + 1, callback(self.policy, 1)['expiredTime'])
        self.assertEqual(self.now + 600, callback(self.policy, 600)['expiredTime'])

    def invalid_policies(self):
        variants = [None, [], '{}']
        for key, value in (('version', '1.0'), ('principal', '*'), ('condition', {})):
            item = copy.deepcopy(self.policy)
            item[key] = value
            variants.append(item)
        for statement in ([], self.policy['statement'] * 2, {}):
            item = copy.deepcopy(self.policy)
            item['statement'] = statement
            variants.append(item)
        for key, value in (
            ('effect', 'deny'), ('principal', '*'), ('condition', {'safe': True}),
            ('action', ['name/cos:GetObject']),
            ('action', ['name/cos:GetObject', 'name/cos:GetObject']),
            ('action', ['name/cos:GetObject', 'name/cos:HeadObject', 'name/cos:PutObject']),
            ('action', ['name/cos:*']), ('resource', ['*']),
        ):
            item = copy.deepcopy(self.policy)
            item['statement'][0][key] = value
            variants.append(item)
        resource = self.policy['statement'][0]['resource'][0]
        for changed in (
            resource.replace(self.scope.bucket, 'other-1250000000'),
            resource.replace(self.scope.region, 'ap-shanghai'),
            resource.replace('uid/1250000000', 'uid/1234567890'),
            resource.replace(self.family, '*'), resource.replace(self.family, self.family.lower()),
            resource.replace('/members/*/objects/*', '/*'),
            resource.replace('/members/*/objects/*', '/members/*/objects/*/..'),
            resource + '*', resource + '/',
        ):
            item = copy.deepcopy(self.policy)
            item['statement'][0]['resource'] = [changed]
            variants.append(item)
        item = copy.deepcopy(self.policy)
        item['statement'][0]['resource'] *= 2
        variants.append(item)
        return variants

    def test_policy_mutations_cannot_widen_scope_before_sdk_call(self):
        callback = self.adapter()
        for index, invalid in enumerate(self.invalid_policies()):
            with self.subTest(case=index), self.assertRaises(StorageError):
                callback(invalid, 600)
        self.assertEqual([], self.client.requests)

    def test_factory_is_lazy_validates_policy_then_uses_explicit_credential_only(self):
        synthetic = credential.Credential('synthetic-provider-id', 'synthetic-provider-key')
        provider = Mock(return_value=synthetic)
        with patch.object(sts_client, 'StsClient', return_value=self.client) as constructor, \
                patch.object(credential, 'DefaultCredentialProvider', side_effect=AssertionError('no discovery')), \
                patch.object(credential, 'EnvironmentVariableCredential', side_effect=AssertionError('no env')), \
                patch.object(credential, 'CVMRoleCredential', side_effect=AssertionError('no metadata')):
            callback = TencentCosStsCallback.from_credential_provider(
                self.scope, provider, enabled=True, timeout=3, clock=lambda: self.now)
            provider.assert_not_called()
            constructor.assert_not_called()
            invalid = copy.deepcopy(self.policy)
            invalid['statement'][0]['action'].append('name/cos:PutObject')
            with self.assertRaises(StorageError):
                callback(invalid, 600)
            provider.assert_not_called()
            constructor.assert_not_called()
            self.assertEqual(self.now + 600, callback(self.policy, 600)['expiredTime'])
        provider.assert_called_once_with()
        constructor.assert_called_once()
        args, kwargs = constructor.call_args
        self.assertIs(synthetic, args[0] if args else kwargs['credential'])
        self.assertEqual(self.scope.region, args[1] if len(args) > 1 else kwargs['region'])
        profile = kwargs.get('profile', kwargs.get('clientProfile', args[2] if len(args) > 2 else None))
        self.assertIsNotNone(profile)
        self.assertEqual('TC3-HMAC-SHA256', profile.signMethod)
        self.assertIsNone(profile.retryer)
        self.assertTrue(profile.disable_region_breaker)
        self.assertEqual('sts.tencentcloudapi.com', profile.httpProfile.endpoint)
        self.assertEqual('https', profile.httpProfile.protocol)
        self.assertEqual('POST', profile.httpProfile.reqMethod)
        self.assertEqual(3, profile.httpProfile.reqTimeout)
        self.assertIsNot(False, profile.httpProfile.certification)

    def test_only_exact_official_endpoints_and_bounded_timeout_are_accepted(self):
        provider = Mock(return_value=credential.Credential('synthetic-id', 'synthetic-key'))
        for endpoint in ('evil.invalid', 'https://sts.tencentcloudapi.com',
                         'sts.tencentcloudapi.com.evil.invalid', 'sts.tencentcloudapi.com:443',
                         'sts.tencentcloudapi.com/path', 'sts.tencentcloudapi.com\n'):
            with self.subTest(endpoint=endpoint), self.assertRaises((ValueError, StorageError)):
                callback = TencentCosStsCallback.from_credential_provider(
                    self.scope, provider, enabled=True, endpoint=endpoint, clock=lambda: self.now)
                callback(self.policy, 600)
        for timeout in (0, 11, True, 1.5):
            with self.subTest(timeout=timeout), self.assertRaises((ValueError, StorageError)):
                callback = TencentCosStsCallback.from_credential_provider(
                    self.scope, provider, enabled=True, timeout=timeout, clock=lambda: self.now)
                callback(self.policy, 600)
        provider.assert_not_called()
        with patch.object(sts_client, 'StsClient', return_value=self.client) as constructor:
            callback = TencentCosStsCallback.from_credential_provider(
                self.scope, provider, enabled=True, endpoint='sts.intl.tencentcloudapi.com',
                region='ap-guangzhou', timeout=1, clock=lambda: self.now)
            callback(self.policy, 600)
        args, kwargs = constructor.call_args
        self.assertEqual('ap-guangzhou', args[1] if len(args) > 1 else kwargs['region'])
        profile = kwargs.get('profile', kwargs.get('clientProfile', args[2] if len(args) > 2 else None))
        self.assertEqual('sts.intl.tencentcloudapi.com', profile.httpProfile.endpoint)

    def test_credential_provider_type_and_exceptions_fail_closed(self):
        for returned in (None, {'secretId': 'synthetic-id', 'secretKey': 'synthetic-key'}, object(),
                         credential.Credential('synthetic-id', 'synthetic-key', token='synthetic-session'),
                         credential.Credential('synthetic-id', 'synthetic-key', token='')):
            with patch.object(sts_client, 'StsClient', return_value=self.client) as constructor:
                callback = TencentCosStsCallback.from_credential_provider(
                    self.scope, lambda: returned, enabled=True, clock=lambda: self.now)
                with self.assertRaises(StorageError):
                    callback(self.policy, 600)
                constructor.assert_not_called()
        provider = Mock(side_effect=RuntimeError('synthetic-provider-secret-must-not-escape'))
        callback = TencentCosStsCallback.from_credential_provider(
            self.scope, provider, enabled=True, clock=lambda: self.now)
        with self.assertRaises(StorageError) as caught:
            callback(self.policy, 600)
        self.assertEqual('stsUnavailable', caught.exception.code)
        self.assertNotIn('synthetic-provider-secret', ''.join(traceback.format_exception(caught.exception)))

    def test_response_field_casing_type_length_and_expiry_are_validated(self):
        callback = self.adapter()
        invalid = [None, {}, self.response(secret_id=''), self.response(secret_key=None),
                   self.response(token=42), self.response(token='x' * 16385),
                   self.response(secret_id='x' * 1025), self.response(secret_key='x' * 1025),
                   self.response(token='x' * 4097), self.response(secret_key='界' * 342),
                   self.response(token='synthetic token'), self.response(secret_id='synthetic\nid')]
        for expiry in (self.now, self.now - 1, self.now + 601, True, float(self.now + 600), str(self.now + 600)):
            invalid.append(self.response(expiry=expiry))
        missing = self.response()
        missing.Credentials = None
        invalid.append(missing)
        for index, response in enumerate(invalid):
            self.client.response = lambda request, value=response: value
            with self.subTest(case=index), self.assertRaises(StorageError):
                callback(self.policy, 600)

    def test_official_credential_length_boundaries_are_accepted_exactly(self):
        self.client.response = lambda request: self.response(
            secret_id='i' * 1024, secret_key='k' * 1024, token='t' * 4096)
        result = self.adapter()(self.policy, 600)
        self.assertEqual(1024, len(result['credentials']['tmpSecretId']))
        self.assertEqual(1024, len(result['credentials']['tmpSecretKey']))
        self.assertEqual(4096, len(result['credentials']['sessionToken']))

    def test_unavailable_or_unpinned_official_sdk_fails_before_client_call(self):
        callback = self.adapter()
        with patch('services.family_gateway.cos_sts.importlib.metadata.version', return_value='0.0.0'):
            with self.assertRaises(StorageError) as caught:
                callback(self.policy, 600)
        self.assertEqual('stsNotConfigured', caught.exception.code)
        self.assertEqual([], self.client.requests)

    def test_enabled_without_client_or_provider_does_not_discover_credentials(self):
        with patch.object(credential, 'DefaultCredentialProvider', side_effect=AssertionError('no discovery')):
            callback = TencentCosStsCallback(self.scope, enabled=True, clock=lambda: self.now)
            with self.assertRaises(StorageError) as caught:
                callback(self.policy, 600)
        self.assertEqual('stsNotConfigured', caught.exception.code)

    def test_provider_sdk_error_is_sanitized_without_retry_or_secret_exception_chain(self):
        self.client.failure = TencentCloudSDKException('SyntheticError', 'synthetic-credential-bearing-response')
        with self.assertRaises(StorageError) as caught:
            self.adapter()(self.policy, 600)
        self.assertEqual('stsUnavailable', caught.exception.code)
        self.assertEqual(1, len(self.client.requests))
        self.assertNotIn('synthetic-credential', ''.join(traceback.format_exception(caught.exception)))
        self.assertTrue(caught.exception.__suppress_context__)

    def test_provider_domain_exceptions_cannot_escape_boundary_redaction(self):
        sensitive = 'synthetic-domain-error-credential-payload'
        self.client.failure = StorageError(sensitive)
        operations = [lambda: self.adapter()(self.policy, 600)]
        provider_failure = Mock(side_effect=StorageError(sensitive))
        provider_callback = TencentCosStsCallback.from_credential_provider(
            self.scope, provider_failure, enabled=True, clock=lambda: self.now)
        operations.append(lambda: provider_callback(self.policy, 600))
        for operation in operations:
            with self.assertRaises(StorageError) as caught:
                operation()
            self.assertEqual('stsUnavailable', caught.exception.code)
            self.assertNotIn(sensitive, ''.join(traceback.format_exception(caught.exception)))
        provider = lambda: credential.Credential('synthetic-id', 'synthetic-key')
        callback = TencentCosStsCallback.from_credential_provider(
            self.scope, provider, enabled=True, clock=lambda: self.now)
        with patch.object(sts_client, 'StsClient', side_effect=StorageError(sensitive)):
            with self.assertRaises(StorageError) as caught:
                callback(self.policy, 600)
        self.assertEqual('stsUnavailable', caught.exception.code)
        self.assertNotIn(sensitive, ''.join(traceback.format_exception(caught.exception)))

    def test_response_expiring_during_provider_call_is_rejected(self):
        def slow(request):
            response = self.response(expiry=self.now + request.DurationSeconds)
            self.now += request.DurationSeconds
            return response
        self.client.response = slow
        with self.assertRaises(StorageError):
            self.adapter()(self.policy, 600)

    def test_restricted_issuer_revocation_before_and_after_provider_call(self):
        active = True
        def authorize(*args):
            if not active:
                raise PermissionError('synthetic revoked membership')
        issuer = RestrictedStsIssuer(self.adapter(), clock=lambda: self.now)
        active = False
        with self.assertRaises(PermissionError):
            issuer.issue(self.scope, self.family, self.member, 'viewer', authorize=authorize)
        self.assertEqual([], self.client.requests)
        active = True
        def revoke_while_issuing(request):
            nonlocal active
            active = False
            return self.response(expiry=self.now + request.DurationSeconds)
        self.client.response = revoke_while_issuing
        with self.assertRaises(PermissionError):
            issuer.issue(self.scope, self.family, self.member, 'viewer', authorize=authorize)
        self.assertEqual(1, len(self.client.requests))
        with self.assertRaises(PermissionError):
            issuer.issue(self.scope, self.family, self.member, 'viewer', authorize=authorize)
        self.assertEqual(1, len(self.client.requests))


if __name__ == '__main__':
    unittest.main()
