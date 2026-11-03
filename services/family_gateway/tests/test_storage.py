import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
import unittest
from unittest.mock import patch
import uuid

from services.family_gateway.storage import (
    CosScope, ObjectStore, RestrictedStsIssuer, StorageError,
    cos_policy, validate_https_origin,
)


def identifier():
    return str(uuid.uuid4()).upper()


def allowed(*args):
    pass


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "objects"
        self.store = ObjectStore(self.root)
        self.ids = (identifier(), identifier(), "0" * 64)

    def put(self, body=b"synthetic original", **kwargs):
        self.ids = (*self.ids[:2], hashlib.sha256(body).hexdigest())
        return self.store.put(
            *self.ids, io.BytesIO(body), size=len(body),
            sha256=hashlib.sha256(body).hexdigest(), authorize=allowed, **kwargs,
        )

    def error(self, code, operation):
        with self.assertRaises(StorageError) as caught:
            operation()
        self.assertEqual(code, caught.exception.code)

    def test_write_read_stat_and_reopen_persist_exact_bytes(self):
        body = bytes(range(256)) * 1300
        info = self.put(body)
        reopened = ObjectStore(self.root)
        self.assertEqual(body, b"".join(reopened.read(*self.ids, authorize=allowed)))
        self.assertEqual(info, reopened.stat(*self.ids, authorize=allowed))
        self.assertEqual(len(body), info.to_dict()["size"])
        self.assertEqual(
            f"family/v1/{self.ids[0]}/members/{self.ids[1]}/objects/{self.ids[2]}", info.key
        )

    def test_uppercase_normalization(self):
        self.put()
        self.assertEqual(
            self.store.stat(*self.ids, authorize=allowed),
            self.store.stat(*(i.lower() for i in self.ids), authorize=allowed),
        )

    def test_zero_bytes_is_valid_explicit_object(self):
        self.assertEqual(0, self.put(b"").size)

    def test_immutable_same_bytes_retry_is_idempotent(self):
        self.assertEqual(self.put(), self.put())

    def test_immutable_different_bytes_never_replace(self):
        self.put(b"first")
        # Even corrupt external state under a content address must not be
        # overwritten silently; recovery needs explicit quarantine/repair.
        target = self.root / self.store.key(*self.ids)
        target.write_bytes(b"externally corrupted")
        self.error("immutableConflict", lambda: self.put(b"first"))
        self.assertEqual(b"externally corrupted", target.read_bytes())

    def test_corrupted_content_address_fails_stat_and_stream_completion(self):
        self.put(b"original")
        target = self.root / self.store.key(*self.ids)
        target.write_bytes(b"modified")
        self.error("corruptObject", lambda: self.store.stat(*self.ids, authorize=allowed))
        self.error("corruptObject", lambda: b"".join(self.store.read(*self.ids, authorize=allowed)))

    def test_concurrent_put_never_overwrites_winner(self):
        bodies = [b"one", b"one"]
        def work(body):
            try:
                return self.put(body).sha256
            except StorageError as e:
                return e.code
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(work, bodies))
        self.assertEqual(0, results.count("immutableConflict"))
        stored = b"".join(self.store.read(*self.ids, authorize=allowed))
        self.assertIn(stored, bodies)
        self.assertIn(hashlib.sha256(stored).hexdigest(), results)

    def test_hash_mismatch_leaves_no_object_or_temporary(self):
        self.error("digestMismatch", lambda: self.store.put(
            *self.ids, io.BytesIO(b"bad"), size=3, sha256="0" * 64, authorize=allowed,
        ))
        self.error("notFound", lambda: self.store.stat(*self.ids, authorize=allowed))
        self.assertFalse(list(self.root.rglob(".upload-*")))

    def test_declared_shorter_or_longer_body_rejected(self):
        self.ids = (*self.ids[:2], hashlib.sha256(b"body").hexdigest())
        for size in (1, 9):
            self.error("sizeMismatch", lambda: self.store.put(
                *self.ids, io.BytesIO(b"body"), size=size,
                sha256=hashlib.sha256(b"body").hexdigest(), authorize=allowed,
            ))
        self.assertFalse(list(self.root.rglob(".upload-*")))

    def test_size_and_digest_inputs_bounded(self):
        for size in (-1, True, self.store.max_bytes + 1):
            self.error("sizeLimit", lambda: self.store.put(
                *self.ids, io.BytesIO(), size=size, sha256="0" * 64, authorize=allowed,
            ))
        self.error("invalidDigest", lambda: self.store.put(
            *self.ids, io.BytesIO(), size=0, sha256="../digest", authorize=allowed,
        ))

    def test_stream_read_is_bounded(self):
        class Bounded(io.BytesIO):
            def read(self, size=-1):
                self_test.assertGreater(size, 0)
                self_test.assertLessEqual(size, ObjectStore.chunk_bytes)
                return super().read(size)
        self_test = self
        body = b"b" * (ObjectStore.chunk_bytes * 3)
        self.ids = (*self.ids[:2], hashlib.sha256(body).hexdigest())
        self.store.put(*self.ids, Bounded(body), size=len(body),
                       sha256=hashlib.sha256(body).hexdigest(), authorize=allowed)

    def test_source_error_does_not_commit(self):
        class Broken:
            def read(self, size):
                raise OSError("synthetic interrupted upload")
        with self.assertRaises(OSError):
            self.store.put(*self.ids, Broken(), size=1, sha256="0" * 64, authorize=allowed)
        self.assertFalse(list(self.root.rglob(".upload-*")))
        self.error("notFound", lambda: self.store.stat(*self.ids, authorize=allowed))

    def test_random_temporary_collision_does_not_delete_another_upload(self):
        self.put()
        directory = (self.root / self.store.key(*self.ids)).parent
        temporary = directory / (".upload-" + "0" * 32)
        temporary.write_bytes(b"another pending upload")
        with patch("services.family_gateway.storage.secrets.token_hex", return_value="0" * 32):
            with self.assertRaises(FileExistsError):
                self.put()
        self.assertEqual(b"another pending upload", temporary.read_bytes())

    def test_revocation_before_commit_denies_and_removes_partial(self):
        self.ids = (*self.ids[:2], hashlib.sha256(b"a").hexdigest())
        calls = 0
        def revoke(action, *ids):
            nonlocal calls
            calls += 1
            if calls >= 4:
                raise PermissionError("revoked")
        with self.assertRaises(PermissionError):
            self.store.put(*self.ids, io.BytesIO(b"a"), size=1,
                           sha256=hashlib.sha256(b"a").hexdigest(), authorize=revoke)
        self.error("notFound", lambda: self.store.stat(*self.ids, authorize=allowed))
        self.assertFalse(list(self.root.rglob(".upload-*")))

    def test_read_rechecks_authorization_each_chunk(self):
        self.put(b"b" * (ObjectStore.chunk_bytes + 1))
        active = True
        def auth(*args):
            if not active:
                raise PermissionError("revoked")
        stream = self.store.read(*self.ids, authorize=auth)
        self.assertEqual(ObjectStore.chunk_bytes, len(next(stream)))
        active = False
        with self.assertRaises(PermissionError):
            next(stream)

    def test_traversal_and_names_rejected_before_io(self):
        for bad in ("..", "../a", "display name", "a/b", self.ids[0] + "/", ""):
            self.error("invalidObjectPath", lambda: self.store.stat(bad, *self.ids[1:], authorize=allowed))

    def test_only_canonical_content_address_and_matching_header_allowed(self):
        for bad in (identifier(), "A" * 64, "a" * 63, "a" * 64 + "/", "../digest"):
            self.error("invalidObjectPath", lambda: self.store.stat(*self.ids[:2], bad, authorize=allowed))
        self.error("objectDigestMismatch", lambda: self.store.put(
            *self.ids, io.BytesIO(b""), size=0,
            sha256=hashlib.sha256(b"").hexdigest(), authorize=allowed,
        ))

    def test_symlink_root_and_nested_directories_rejected(self):
        link = Path(self.temp.name) / "link"
        link.symlink_to(self.root, target_is_directory=True)
        self.error("unsafeStoragePath", lambda: ObjectStore(link))
        target = Path(self.temp.name) / "other"
        target.mkdir()
        (self.root / "family").symlink_to(target, target_is_directory=True)
        self.error("unsafeStoragePath", lambda: self.put())
        self.assertEqual([], list(target.iterdir()))

    def test_symlink_final_object_rejected_for_read_stat_and_put(self):
        self.put()
        target = self.root / self.store.key(*self.ids)
        target.unlink()
        outside = Path(self.temp.name) / "private"
        outside.write_bytes(b"private")
        target.symlink_to(outside)
        for op in (
            lambda: self.store.stat(*self.ids, authorize=allowed),
            lambda: b"".join(self.store.read(*self.ids, authorize=allowed)),
            lambda: self.put(),
            lambda: self.store.delete(*self.ids, authorize=allowed),
        ):
            self.error("unsafeStoragePath", op)
        self.assertEqual(b"private", outside.read_bytes())

    def test_delete_is_explicit_and_authorized(self):
        self.put()
        def denied(*args):
            raise PermissionError("denied")
        with self.assertRaises(PermissionError):
            self.store.delete(*self.ids, authorize=denied)
        self.store.delete(*self.ids, authorize=allowed)
        self.error("notFound", lambda: self.store.stat(*self.ids, authorize=allowed))


class StorageIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "dedicated-objects"
        self.store = ObjectStore(self.root)
        self.marker = self.root / ObjectStore.identity_marker
        self.body = b"synthetic identity-bound original"
        self.ids = (identifier(), identifier(), hashlib.sha256(self.body).hexdigest())

    def error(self, code, operation):
        with self.assertRaises(StorageError) as caught:
            operation()
        self.assertEqual(code, caught.exception.code)

    def put(self):
        return self.store.put(*self.ids, io.BytesIO(self.body), size=len(self.body),
                              sha256=self.ids[2], authorize=allowed)

    def test_restart_keeps_same_random_private_nonsecret_storage_identity(self):
        storage_id = self.store.storage_id
        self.assertEqual(storage_id, ObjectStore(self.root).storage_id)
        self.assertRegex(storage_id, r"^gateway:[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}$")
        marker = json.loads(self.marker.read_bytes())
        self.assertEqual({"id", "version"}, set(marker))
        self.assertEqual(1, marker["version"])
        self.assertEqual(4, uuid.UUID(marker["id"]).version)
        self.assertEqual("gateway:" + marker["id"], storage_id)
        self.assertEqual(0o600, self.marker.stat().st_mode & 0o777)
        self.assertLess(len(self.marker.read_bytes()), ObjectStore.marker_limit)
        self.assertFalse(list(self.root.glob(".identity-*")))

    def test_new_root_has_different_identity(self):
        other = ObjectStore(Path(self.temp.name) / "another-dedicated-root")
        self.assertNotEqual(self.store.storage_id, other.storage_id)

    def test_existing_unmarked_even_empty_root_is_not_auto_adopted(self):
        existing = Path(self.temp.name) / "preexisting"
        existing.mkdir()
        self.error("invalidStorageIdentity", lambda: ObjectStore(existing))
        self.assertEqual([], list(existing.iterdir()))

    def test_concurrent_initializers_cannot_publish_two_identities(self):
        root = Path(self.temp.name) / "concurrent-root"
        barrier = threading.Barrier(2)
        def initialize(_):
            barrier.wait()
            try:
                return ObjectStore(root).storage_id
            except StorageError as error:
                # An initializer observing an unfinished marker must fail
                # closed rather than create a second identity for that root.
                self.assertEqual("invalidStorageIdentity", error.code)
                return None
        with ThreadPoolExecutor(max_workers=2) as pool:
            values = list(pool.map(initialize, range(2)))
        successful = {value for value in values if value is not None}
        self.assertEqual(1, len(successful))
        self.assertEqual(successful.pop(), ObjectStore(root).storage_id)

    def test_deleted_marker_blocks_every_existing_instance_operation(self):
        self.put()
        self.marker.unlink()
        for operation in (
            lambda: self.store.storage_id,
            self.put,
            lambda: self.store.stat(*self.ids, authorize=allowed),
            lambda: b"".join(self.store.read(*self.ids, authorize=allowed)),
            lambda: self.store.delete(*self.ids, authorize=allowed),
        ):
            self.error("storageIdentityMismatch", operation)
        self.error("invalidStorageIdentity", lambda: ObjectStore(self.root))
        self.assertEqual(self.body, (self.root / self.store.key(*self.ids)).read_bytes())
        self.assertFalse(list(self.root.rglob(".upload-*")))

    def test_corrupt_oversize_and_unknown_markers_fail_closed(self):
        original = json.loads(self.marker.read_bytes())
        invalid = [b"not json", b"x" * (ObjectStore.marker_limit + 1),
                   canonical_marker(dict(original, version=2)),
                   canonical_marker(dict(original, version=True)),
                   canonical_marker(dict(original, unexpected="field")),
                   canonical_marker(dict(original, id="not-a-uuid")),
                   canonical_marker(dict(original, id=original["id"].lower())),
                   b'{"version":1,"version":1,"id":"' + original['id'].encode() + b'"}\n']
        for raw in invalid:
            with self.subTest(raw=raw[:40]):
                self.marker.write_bytes(raw)
                self.error("invalidStorageIdentity", lambda: ObjectStore(self.root))
        self.error("storageIdentityMismatch", lambda: self.store.storage_id)

    def test_replaced_marker_same_content_is_detected_by_live_instance(self):
        replacement = self.root / "replacement"
        replacement.write_bytes(self.marker.read_bytes())
        replacement.chmod(0o600)
        os.replace(replacement, self.marker)
        self.error("storageIdentityMismatch", self.put)

    def test_marker_unsafe_permissions_hardlink_symlink_and_nonregular_rejected(self):
        self.marker.chmod(0o644)
        self.error("invalidStorageIdentity", lambda: ObjectStore(self.root))
        self.marker.chmod(0o600)
        hardlink = self.root / "alias"
        os.link(self.marker, hardlink)
        self.error("invalidStorageIdentity", lambda: ObjectStore(self.root))
        hardlink.unlink()
        backup = self.root / "saved-marker"
        self.marker.rename(backup)
        self.marker.symlink_to(backup)
        self.error("invalidStorageIdentity", lambda: ObjectStore(self.root))
        self.marker.unlink()
        self.marker.mkdir()
        self.error("invalidStorageIdentity", lambda: ObjectStore(self.root))
        self.marker.rmdir()
        os.mkfifo(self.marker, 0o600)
        self.error("invalidStorageIdentity", lambda: ObjectStore(self.root))

    def test_replaced_root_and_cloned_marker_never_rebind_live_instance(self):
        self.put()
        marker = self.marker.read_bytes()
        old_root = Path(self.temp.name) / "old-root"
        self.root.rename(old_root)
        self.root.mkdir(mode=0o700)
        self.marker.write_bytes(marker)
        self.marker.chmod(0o600)
        self.error("storageIdentityMismatch", lambda: self.store.storage_id)
        self.error("storageIdentityMismatch", self.put)
        self.assertEqual([ObjectStore.identity_marker], [p.name for p in self.root.iterdir()])
        self.assertEqual(self.body, (old_root / self.store.key(*self.ids)).read_bytes())

    def test_different_root_identity_blocks_live_instance_before_write(self):
        original = self.store.storage_id
        self.root.rename(Path(self.temp.name) / "old-root")
        replacement = ObjectStore(self.root)
        self.assertNotEqual(original, replacement.storage_id)
        self.error("storageIdentityMismatch", self.put)
        self.assertFalse((self.root / "family").exists())

    def test_marker_change_mid_upload_or_read_cannot_complete(self):
        class Changed(io.BytesIO):
            def read(source, count=-1):
                chunk = super(Changed, source).read(count)
                if self.marker.exists():
                    self.marker.unlink()
                return chunk
        self.error("storageIdentityMismatch", lambda: self.store.put(
            *self.ids, Changed(self.body), size=len(self.body),
            sha256=self.ids[2], authorize=allowed,
        ))
        self.assertFalse((self.root / self.store.key(*self.ids)).exists())
        self.assertFalse(list(self.root.rglob(".upload-*")))
        # A separate new store lets the read test start from a valid identity.
        read_store = ObjectStore(Path(self.temp.name) / "read-root")
        content = b"a" * (ObjectStore.chunk_bytes + 1)
        ids = (*self.ids[:2], hashlib.sha256(content).hexdigest())
        read_store.put(*ids, io.BytesIO(content), size=len(content), sha256=ids[2], authorize=allowed)
        stream = read_store.read(*ids, authorize=allowed)
        self.assertEqual(ObjectStore.chunk_bytes, len(next(stream)))
        (read_store.root / ObjectStore.identity_marker).unlink()
        self.error("storageIdentityMismatch", lambda: next(stream))

    def test_interrupted_marker_creation_leaves_no_automatic_identity_recovery(self):
        root = Path(self.temp.name) / "interrupted-root"
        with patch("services.family_gateway.storage.os.link", side_effect=OSError("synthetic disk failure")):
            self.error("invalidStorageIdentity", lambda: ObjectStore(root))
        self.assertEqual([], list(root.iterdir()))
        self.error("invalidStorageIdentity", lambda: ObjectStore(root))


def canonical_marker(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii")


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.scope = CosScope("synthetic-1250000000", "ap-beijing", "1250000000")
        self.family, self.member = identifier(), identifier()

    def test_read_only_family_scope_never_grants_overwrite_delete_or_acl(self):
        for role in ("admin", "contributor", "viewer"):
            policy = cos_policy(self.scope, self.family, self.member, role)
            statement = policy["statement"][0]
            self.assertEqual(["name/cos:GetObject", "name/cos:HeadObject"], statement["action"])
            self.assertEqual([
                f"qcs::cos:ap-beijing:uid/1250000000:synthetic-1250000000/family/v1/{self.family}/members/*/objects/*"
            ], statement["resource"])

    def test_untrusted_config_cannot_widen_policy(self):
        for bucket, region, appid in (("*", "ap-beijing", "1250000000"),
                                       ("synthetic-1250000000", "*", "1250000000"),
                                       ("synthetic-12345", "ap-beijing", "1250000000")):
            with self.assertRaises(StorageError):
                CosScope(bucket, region, appid)
        with self.assertRaises(StorageError):
            cos_policy(self.scope, self.family, self.member, "owner")

    def test_no_default_issuer_and_revocation_stops_new_issue(self):
        issuer = RestrictedStsIssuer()
        with self.assertRaises(StorageError) as caught:
            issuer.issue(self.scope, self.family, self.member, "viewer", authorize=allowed)
        self.assertEqual("stsNotConfigured", caught.exception.code)
        calls = []
        def denied(*args):
            raise PermissionError("revoked")
        issuer = RestrictedStsIssuer(lambda p, d: calls.append(p), clock=lambda: 100)
        with self.assertRaises(PermissionError):
            issuer.issue(self.scope, self.family, self.member, "viewer", authorize=denied)
        self.assertEqual([], calls)

    def test_bounded_issuer_response_redacts_repr(self):
        synthetic = {"tmpSecretId": "synthetic-id", "tmpSecretKey": "synthetic-key", "sessionToken": "synthetic-token"}
        issuer = RestrictedStsIssuer(lambda p, d: {"credentials": synthetic, "expiredTime": 700}, clock=lambda: 100)
        result = issuer.issue(self.scope, self.family, self.member, "viewer", authorize=allowed)
        self.assertEqual("TemporaryCredentials(redacted)", repr(result))
        self.assertEqual(synthetic, result.to_dict()["credentials"])

    def test_issuer_exception_message_is_redacted(self):
        def failure(policy, duration):
            raise RuntimeError("synthetic secret response must not escape")
        issuer = RestrictedStsIssuer(failure, clock=lambda: 100)
        with self.assertRaises(StorageError) as caught:
            issuer.issue(self.scope, self.family, self.member, "viewer", authorize=allowed)
        self.assertEqual("stsUnavailable", caught.exception.code)
        self.assertEqual("stsUnavailable", str(caught.exception))
        self.assertIsNone(caught.exception.__cause__)
        self.assertTrue(caught.exception.__suppress_context__)

    def test_issuer_expiry_and_requested_duration_are_bounded(self):
        synthetic = {"tmpSecretId": "a", "tmpSecretKey": "b", "sessionToken": "c"}
        for expiry in (100, 701, True, "700"):
            issuer = RestrictedStsIssuer(lambda p, d: {"credentials": synthetic, "expiredTime": expiry}, clock=lambda: 100)
            with self.assertRaises(StorageError) as caught:
                issuer.issue(self.scope, self.family, self.member, "viewer", authorize=allowed)
            self.assertEqual("invalidStsResponse", caught.exception.code)
        issuer = RestrictedStsIssuer(lambda p, d: {}, clock=lambda: 100)
        for duration in (0, 601, True):
            with self.assertRaises(StorageError) as caught:
                issuer.issue(self.scope, self.family, self.member, "viewer", authorize=allowed, duration_seconds=duration)
            self.assertEqual("invalidDuration", caught.exception.code)

    def test_https_origin_boundary(self):
        self.assertEqual("https://nas.invalid:8443", validate_https_origin("https://nas.invalid:8443/"))
        for url in ("http://nas.invalid", "https://user:pw@nas.invalid", "https://nas.invalid/a", "https://nas.invalid?x=1", "https://nas.invalid#x", "https://nas.invalid:99999", "https://nas.invalid/\n", "https://nas.invalid?", "https://nas.invalid#", "https://nas%0d.invalid", 123):
            with self.assertRaises(StorageError):
                validate_https_origin(url)


if __name__ == "__main__":
    unittest.main()
