"""Gateway-managed immutable objects and an unconfigured COS STS boundary.

ObjectStore manages a dedicated local/mounted directory. It is not a WebDAV
network adapter and must never be pointed at a client's original media folder.
Authorization is mandatory and must consult current server-side membership.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
import time
from typing import BinaryIO, Callable, Iterator, Mapping
from urllib.parse import urlsplit
import uuid


class StorageError(Exception):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


def stable_id(value: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(
        r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
        value,
    ):
        raise StorageError("invalidObjectPath")
    return str(uuid.UUID(value)).upper()


def object_digest(value: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise StorageError("invalidObjectPath")
    return value


def validate_https_origin(value: str) -> str:
    """Validate config, without fetching or following arbitrary client URLs."""
    try:
        if not isinstance(value, str):
            raise ValueError()
        url = urlsplit(value)
        if (
            url.scheme != "https"
            or not url.hostname
            or "%" in url.netloc
            or "\\" in url.netloc
            or url.username is not None
            or url.password is not None
            or "?" in value
            or "#" in value
            or "%" in url.netloc
            or url.path not in ("", "/")
            or any(ord(c) < 33 for c in value)
        ):
            raise ValueError()
        port = url.port
        if port is not None and not 1 <= port <= 65535:
            raise ValueError()
        return f"https://{url.netloc}"
    except (TypeError, ValueError):
        raise StorageError("invalidHttpsOrigin") from None


@dataclass(frozen=True)
class ObjectInfo:
    key: str
    size: int
    sha256: str

    def to_dict(self) -> dict:
        return {"key": self.key, "size": self.size, "sha256": self.sha256}


Authorize = Callable[[str, str, str, str | None], None]


class ObjectStore:
    chunk_bytes = 64 * 1024
    identity_marker = ".dayswith-storage-id"
    marker_limit = 256

    def __init__(self, root: str | Path, max_bytes: int = 256 * 1024 * 1024):
        if isinstance(max_bytes, bool) or not isinstance(max_bytes, int) or max_bytes < 1:
            raise ValueError("max_bytes must be positive")
        self.max_bytes = max_bytes
        self.root = Path(root).absolute()
        # Every component is opened with O_NOFOLLOW at operation time; checking
        # once with resolve() would hide symlinks and leave a TOCTOU window.
        self._created_root = False
        directory = self._root_fd(create=True)
        try:
            if self._created_root:
                self._create_marker(directory)
            identity, raw, marker_stat = self._read_marker(directory)
            self._storage_id = "gateway:" + identity
            self._identity_bytes = raw
            self._marker_stat = marker_stat
            metadata = os.fstat(directory)
            self._root_stat = (metadata.st_dev, metadata.st_ino)
        finally:
            os.close(directory)

    @property
    def storage_id(self) -> str:
        self._verify_current()
        return self._storage_id

    @staticmethod
    def _marker_signature(metadata):
        return (metadata.st_dev, metadata.st_ino, metadata.st_mtime_ns,
                metadata.st_ctime_ns, metadata.st_size, metadata.st_uid,
                stat.S_IMODE(metadata.st_mode), metadata.st_nlink)

    def _create_marker(self, directory: int) -> None:
        """Publish a fully written private marker without replacing any file."""
        marker = {"id": str(uuid.uuid4()).upper(), "version": 1}
        raw = (json.dumps(marker, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii")
        temporary = ".identity-" + secrets.token_hex(16)
        created = False
        try:
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         mode=0o600, dir_fd=directory)
            created = True
            with os.fdopen(fd, "wb") as target:
                target.write(raw)
                target.flush()
                os.fsync(target.fileno())
            try:
                os.link(temporary, self.identity_marker, src_dir_fd=directory,
                        dst_dir_fd=directory, follow_symlinks=False)
            except FileExistsError:
                # Another completed initializer may already have installed it.
                # Validate that existing marker below; never overwrite it.
                pass
        except OSError:
            raise StorageError("invalidStorageIdentity") from None
        finally:
            if created:
                try:
                    os.unlink(temporary, dir_fd=directory)
                except FileNotFoundError:
                    pass
            os.fsync(directory)

    def _read_marker(self, directory: int):
        try:
            fd = os.open(self.identity_marker, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                         dir_fd=directory)
        except OSError:
            raise StorageError("invalidStorageIdentity") from None
        try:
            metadata = os.fstat(fd)
            if (not stat.S_ISREG(metadata.st_mode) or
                    stat.S_IMODE(metadata.st_mode) != 0o600 or
                    metadata.st_uid != os.geteuid() or metadata.st_nlink != 1 or
                    not 0 < metadata.st_size <= self.marker_limit):
                raise StorageError("invalidStorageIdentity")
            with os.fdopen(fd, "rb", closefd=False) as source:
                raw = source.read(self.marker_limit + 1)
            if self._marker_signature(metadata) != self._marker_signature(os.fstat(fd)):
                raise StorageError("invalidStorageIdentity")
            marker = json.loads(raw)
            if (not isinstance(marker, dict) or set(marker) != {"id", "version"} or
                    type(marker["version"]) is not int or marker["version"] != 1 or
                    not isinstance(marker["id"], str) or
                    stable_id(marker["id"]) != marker["id"] or
                    uuid.UUID(marker["id"]).version != 4 or
                    (json.dumps(marker, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii") != raw):
                raise StorageError("invalidStorageIdentity")
            return marker["id"], raw, self._marker_signature(metadata)
        except (ValueError, TypeError, UnicodeError, KeyError, StorageError):
            raise StorageError("invalidStorageIdentity") from None
        finally:
            os.close(fd)

    def _verify_current(self) -> None:
        directory = self._root_fd()
        os.close(directory)

    def _root_fd(self, *, create: bool = False, close: bool = False) -> int:
        fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        try:
            components = self.root.parts[1:]
            for index, component in enumerate(components):
                if component in (".", ".."):
                    raise StorageError("invalidObjectPath")
                if create:
                    try:
                        os.mkdir(component, mode=0o700, dir_fd=fd)
                        os.fsync(fd)
                        if index == len(components) - 1:
                            self._created_root = True
                    except FileExistsError:
                        pass
                next_fd = os.open(
                    component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd
                )
                os.close(fd)
                fd = next_fd
            if hasattr(self, "_identity_bytes"):
                try:
                    metadata = os.fstat(fd)
                    _, raw, marker_stat = self._read_marker(fd)
                    if ((metadata.st_dev, metadata.st_ino) != self._root_stat or
                            raw != self._identity_bytes or marker_stat != self._marker_stat):
                        raise StorageError("storageIdentityMismatch")
                except StorageError:
                    raise StorageError("storageIdentityMismatch") from None
            if close:
                os.close(fd)
                return -1
            return fd
        except OSError:
            os.close(fd)
            raise StorageError("unsafeStoragePath") from None
        except BaseException:
            os.close(fd)
            raise

    @staticmethod
    def key(family_id: str, member_id: str, object_id: str) -> str:
        return (
            f"family/v1/{stable_id(family_id)}/members/"
            f"{stable_id(member_id)}/objects/{object_digest(object_id)}"
        )

    def _parent_fd(self, key: str, *, create: bool) -> int:
        fd = self._root_fd()
        try:
            for component in key.split("/")[:-1]:
                if create:
                    try:
                        os.mkdir(component, mode=0o700, dir_fd=fd)
                    except FileExistsError:
                        pass
                next_fd = os.open(
                    component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd
                )
                os.close(fd)
                fd = next_fd
            return fd
        except FileNotFoundError:
            os.close(fd)
            raise StorageError("notFound") from None
        except OSError:
            os.close(fd)
            raise StorageError("unsafeStoragePath") from None

    def _metadata(self, directory: int, key: str) -> ObjectInfo:
        try:
            fd = os.open(key.rsplit("/", 1)[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        except FileNotFoundError:
            raise StorageError("notFound") from None
        except OSError:
            raise StorageError("unsafeStoragePath") from None
        try:
            metadata = os.fstat(fd)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > self.max_bytes:
                raise StorageError("unsafeStoragePath")
            digest = hashlib.sha256()
            size = 0
            with os.fdopen(fd, "rb", closefd=False) as source:
                while True:
                    self._verify_current()
                    chunk = source.read(self.chunk_bytes)
                    if not chunk:
                        break
                    size += len(chunk)
                    if size > self.max_bytes:
                        raise StorageError("sizeLimit")
                    digest.update(chunk)
            return ObjectInfo(key, size, digest.hexdigest())
        finally:
            os.close(fd)

    def put(
        self,
        family_id: str,
        member_id: str,
        object_id: str,
        stream: BinaryIO,
        *,
        size: int,
        sha256: str,
        authorize: Authorize,
    ) -> ObjectInfo:
        family_id, member_id = map(stable_id, (family_id, member_id))
        object_id = object_digest(object_id)
        authorize("write", family_id, member_id, object_id)
        if isinstance(size, bool) or not isinstance(size, int) or not 0 <= size <= self.max_bytes:
            raise StorageError("sizeLimit")
        if not isinstance(sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", sha256):
            raise StorageError("invalidDigest")
        if sha256 != object_id:
            raise StorageError("objectDigestMismatch")
        key = self.key(family_id, member_id, object_id)
        directory = self._parent_fd(key, create=True)
        temporary = ".upload-" + secrets.token_hex(16)
        created = False
        try:
            fd = os.open(
                temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                mode=0o600, dir_fd=directory,
            )
            created = True
            actual_size = 0
            digest = hashlib.sha256()
            with os.fdopen(fd, "wb") as target:
                while True:
                    authorize("write", family_id, member_id, object_id)
                    self._verify_current()
                    # Ask for at most one extra byte to detect declared-size lies.
                    chunk = stream.read(min(self.chunk_bytes, size - actual_size + 1))
                    if not chunk:
                        break
                    if not isinstance(chunk, bytes):
                        raise StorageError("invalidBody")
                    actual_size += len(chunk)
                    if actual_size > size:
                        raise StorageError("sizeMismatch")
                    digest.update(chunk)
                    target.write(chunk)
                if actual_size != size:
                    raise StorageError("sizeMismatch")
                if digest.hexdigest() != sha256:
                    raise StorageError("digestMismatch")
                target.flush()
                os.fsync(target.fileno())
            authorize("write", family_id, member_id, object_id)
            self._verify_current()
            try:
                # link() atomically refuses an existing destination. replace()
                # would silently overwrite originals under concurrent uploads.
                os.link(
                    temporary, object_id, src_dir_fd=directory,
                    dst_dir_fd=directory, follow_symlinks=False,
                )
                os.fsync(directory)
            except FileExistsError:
                old = self._metadata(directory, key)
                if old.size != size or old.sha256 != sha256:
                    raise StorageError("immutableConflict") from None
            return ObjectInfo(key, size, sha256)
        finally:
            if created:
                try:
                    os.unlink(temporary, dir_fd=directory)
                except FileNotFoundError:
                    pass
            os.close(directory)

    def stat(self, family_id: str, member_id: str, object_id: str, *, authorize: Authorize) -> ObjectInfo:
        ids = (stable_id(family_id), stable_id(member_id), object_digest(object_id))
        authorize("read", *ids)
        key = self.key(*ids)
        directory = self._parent_fd(key, create=False)
        try:
            result = self._metadata(directory, key)
            if result.sha256 != ids[2]:
                raise StorageError("corruptObject")
            return result
        finally:
            os.close(directory)

    def read(self, family_id: str, member_id: str, object_id: str, *, authorize: Authorize) -> Iterator[bytes]:
        ids = (stable_id(family_id), stable_id(member_id), object_digest(object_id))
        authorize("read", *ids)
        key = self.key(*ids)
        directory = self._parent_fd(key, create=False)
        try:
            fd = os.open(ids[2], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        except FileNotFoundError:
            raise StorageError("notFound") from None
        except OSError:
            raise StorageError("unsafeStoragePath") from None
        finally:
            os.close(directory)
        with os.fdopen(fd, "rb") as source:
            metadata = os.fstat(source.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > self.max_bytes:
                raise StorageError("unsafeStoragePath")
            transferred = 0
            digest = hashlib.sha256()
            while True:
                authorize("read", *ids)
                self._verify_current()
                chunk = source.read(self.chunk_bytes)
                if not chunk:
                    if digest.hexdigest() != ids[2]:
                        raise StorageError("corruptObject")
                    return
                transferred += len(chunk)
                if transferred > self.max_bytes:
                    raise StorageError("sizeLimit")
                digest.update(chunk)
                yield chunk

    def delete(self, family_id: str, member_id: str, object_id: str, *, authorize: Authorize) -> None:
        ids = (stable_id(family_id), stable_id(member_id), object_digest(object_id))
        authorize("delete", *ids)
        key = self.key(*ids)
        directory = self._parent_fd(key, create=False)
        try:
            # Refuse a symlink even though unlink itself would not follow it.
            self._metadata(directory, key)
            authorize("delete", *ids)
            self._verify_current()
            os.unlink(ids[2], dir_fd=directory)
            os.fsync(directory)
        finally:
            os.close(directory)


@dataclass(frozen=True)
class CosScope:
    bucket: str
    region: str
    appid: str

    def __post_init__(self):
        if (
            not re.fullmatch(r"[0-9]{5,20}", self.appid)
            or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,49}-" + self.appid, self.bucket)
            or not re.fullmatch(r"[a-z]{2}-[a-z0-9-]{1,40}", self.region)
        ):
            raise StorageError("invalidCosScope")


def cos_policy(scope: CosScope, family_id: str, member_id: str, role: str) -> dict:
    """Read-only STS policy. Immutable writes require the gateway.

    IAM PutObject alone permits replacing an existing original. Until a real
    COS integration proves immutable conditional-write enforcement, this module
    deliberately grants no write, delete, bucket listing, ACL or admin action.
    See https://www.tencentcloud.com/document/product/436/30580 .
    """
    family_id, member_id = map(stable_id, (family_id, member_id))
    if role not in {"admin", "contributor", "viewer"}:
        raise StorageError("denied")
    resource = (
        f"qcs::cos:{scope.region}:uid/{scope.appid}:{scope.bucket}/"
        f"family/v1/{family_id}/members/*/objects/*"
    )
    return {"version": "2.0", "statement": [{
        "effect": "allow", "action": ["name/cos:GetObject", "name/cos:HeadObject"],
        "resource": [resource],
    }]}


@dataclass(frozen=True, repr=False)
class TemporaryCredentials:
    credentials: Mapping[str, str]
    expires_at: int

    def __repr__(self):
        return "TemporaryCredentials(redacted)"

    def to_dict(self) -> dict:
        return {
            "credentials": dict(self.credentials),
            "expiresAt": datetime.fromtimestamp(self.expires_at, timezone.utc).isoformat().replace("+00:00", "Z"),
        }


class RestrictedStsIssuer:
    """Requires an independently configured issuer; no real issuer is included.

    Revocation stops new calls but an already issued COS key can remain valid
    until expires_at. Never cache or log this result or promise instant removal.
    """

    def __init__(self, issue_callback: Callable[[dict, int], Mapping] | None = None, *, clock=time.time):
        self._issue = issue_callback
        self._clock = clock

    def issue(
        self, scope: CosScope, family_id: str, member_id: str, role: str, *,
        authorize: Authorize, duration_seconds: int = 600,
    ) -> TemporaryCredentials:
        family_id, member_id = map(stable_id, (family_id, member_id))
        authorize("issueCredentials", family_id, member_id, None)
        if self._issue is None:
            raise StorageError("stsNotConfigured")
        if isinstance(duration_seconds, bool) or not isinstance(duration_seconds, int) or not 1 <= duration_seconds <= 600:
            raise StorageError("invalidDuration")
        started = int(self._clock())
        policy = cos_policy(scope, family_id, member_id, role)
        try:
            result = self._issue(policy, duration_seconds)
        except Exception:
            # Provider exceptions can include raw responses or credentials.
            # Normalize without retaining a chained exception for server logs.
            raise StorageError("stsUnavailable") from None
        # Reject unbounded/malformed issuer results; do not log their values.
        try:
            expiry = result["expiredTime"]
            credentials = result["credentials"]
            if isinstance(expiry, bool) or not isinstance(expiry, int) or not int(self._clock()) < expiry <= started + duration_seconds:
                raise ValueError()
            values = {key: credentials[key] for key in ("tmpSecretId", "tmpSecretKey", "sessionToken")}
            if any(not isinstance(v, str) or not v or len(v) > 16384 for v in values.values()):
                raise ValueError()
        except (KeyError, TypeError, ValueError):
            raise StorageError("invalidStsResponse") from None
        authorize("issueCredentials", family_id, member_id, None)
        return TemporaryCredentials(values, expiry)
