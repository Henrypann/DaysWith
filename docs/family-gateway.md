# Family Gateway — isolated implementation and integration contract

2026-11-03. This is undeployed code with synthetic tests, **not a configured
production identity service or an accepted COS/NAS deployment**. The mobile family
entry remains experimental until an operator supplies and verifies its identity,
TLS, storage and revocation integrations. No persistent credential, real family
archive, storage account or listener was created by this work.

## Components and identity boundary

`services/family_gateway/gateway.py` is a Python standard-library WSGI application.
It has no command that starts a server and no default identity provider. Construct
it with a dedicated private SQLite path and a fixed HTTPS origin. Every `/v1`
request, including invitation inspection, requires HTTPS and a Bearer token.
The injected `verify_bearer(token) -> subjectID` authenticates the caller; request
bodies never select or override a subject. Without a verifier the application
returns `503 {"error":"unavailable"}`. The gateway ignores forwarded TLS headers;
its hosting adapter must provide the true secure WSGI scheme. The application
requires an explicit HTTP Host matching its configured HTTPS origin (including
the effective port); missing or foreign hosts fail closed. There is no cookie authentication or redirect behavior.

Production must supply an independently reviewed identity adapter (issuer,
audience, expiry, algorithm/key validation, recovery and identity revocation),
TLS termination, protected storage volume and operational limits. Do not turn a
client-supplied subject string into a verifier. `SyntheticHmacVerifier` requires
explicit `synthetic_only=True`; it signs short-lived test tokens in process and
has no HTTP issuance endpoint. It is used only with random ephemeral test keys.

SQLite uses foreign keys, WAL, a bounded busy timeout and `BEGIN IMMEDIATE`
transactions. Active family/subject membership and pending applications have
unique indexes. Invitation token hashes and consumption state survive restart;
raw tokens and Bearer tokens are not saved. Database files are created mode 0600;
existing symlinks, nonregular files or group/world-readable database files are
rejected. Version 1 is explicit and unknown versions fail rather than migrate
in place. Operators still need backups and a verified recovery procedure for the
SQLite database and object directory as one logical dataset.

## Persistent backend binding

A newly created dedicated object root receives a canonical private
`.dayswith-storage-id` marker containing only version 1 and a random installation
UUID, not credentials. Existing unmarked roots cannot be silently adopted.
Marker creation is atomic and fsynced. Invalid, missing, symlinked, nonregular,
nonprivate or replaced markers fail closed. A live instance checks the marker
and root directory identity on operations, streaming chunks and commit boundaries.

The SQLite database binds once to that opaque backend ID. Reopening the same
backend is stable; pointing the same database/gateway origin at a different root
raises a configuration error, without rebinding or migrating archives. Binding
also fills `family.primaryStorageID`, which upload confirmation must pin along
with family/member/origin. Marker copying alone is not a supported migration;
operators with filesystem control must preserve database and backend together.

Starting the gateway with `object_store=None` may keep family/member/admin
metadata available, including the persisted expected target ID. Media reads and
writes, archive catalog, raw snapshot reads and all snapshot publications (even
text-only ones) return 503 until the correctly bound backend is available.
Registration and moderation metadata do not create a valid backup while storage
is unavailable. Missing or corrupt live markers similarly disable data access.

## JSON wire contract

Fields use camelCase. UUID identifiers are normalized to uppercase. Names and
relationship labels are display fields and never become storage paths. Roles are
`admin`, `contributor`, `viewer`; member status is `active` or `revoked`.
`expiresAt` is an ISO 8601 UTC string; confirmed expiry is compared as an instant,
so a client `.000Z` representation is accepted. Every POST/PUT JSON request uses
`Content-Type: application/json`. Action POSTs send `{}`. Generic metadata bodies are strictly UTF-8 JSON with duplicate keys, nonfinite
numbers, floats and unpaired surrogates rejected. They are limited to
64 KiB and authenticated callers are rate-limited in persistent one-minute
windows (default 360 requests). List materialization is bounded to 2000 items
and 768 KiB of encoded entries; larger results fail explicitly with 413 rather
than silently truncate. Directory-list cursor pagination is not yet implemented and remains an
integration requirement for very large member/request directories. The archive
catalog has its own stable, bounded cursor pagination described below. Edge authentication-abuse/connection limits are
still an operator responsibility.

| Method and path | Body / response |
| --- | --- |
| `GET /v1/families` | `{families:[{id,name,primaryStorageID}]}` for active caller memberships |
| `POST /v1/families` | `{name,displayName,relationshipLabel,deviceID}` → family detail |
| `GET /v1/families/F` | `{family:{id,name,primaryStorageID},members:[member],currentMember:member}` |
| `POST /v1/families/F/invitations` | `{requestedRole}` → `{id,url,requestedRole,expiresAt}` |
| `GET /v1/invitations/TOKEN` | `{familyID,familyName,requestedRole,expiresAt}`; does not consume or grant membership |
| `POST /v1/invitations/TOKEN/requests` | Preview fields plus `confirmed:true,displayName,relationshipLabel,deviceID` → request |
| `GET /v1/requests` | `{requests:[request]}` for caller's own applications, including resolved ones; permits restart recovery without retaining invite URLs |
| `GET /v1/requests/R` | Request visible to applicant or current family administrator |
| `GET /v1/families/F/requests` | `{requests:[request]}` pending applications, administrator only |
| `POST /v1/requests/R/approve` | Member, administrator only |
| `POST /v1/requests/R/deny` | Resolved request, administrator only |
| `POST /v1/families/F/invitations/I/revoke` | `{ok:true}`; cancels pending application but not approved membership |
| `POST /v1/families/F/members/M/revoke` | `{ok:true}`; explicit administrator action, last active administrator protected |
| `GET /v1/families/F/audit` | `{events:[...]}`, latest 200, administrator only |

A member has `id,familyID,subjectID,displayName,relationshipLabel,role,status,
deviceIDs`. A request has `id,familyID,invitationID,subjectID,displayName,
relationshipLabel,requestedRole,status,approvedMemberID,deviceID`. Request status
is `pending`, `approved`, `denied` or `revoked`; `approvedMemberID` is nullable.
`primaryStorageID` is the persisted opaque ID of the configured dedicated object
backend (`gateway:<UUID>`). It is null only before initial backend setup. A bound
ID can remain visible while its backend is unavailable; it describes target
identity, not a health claim. No copying, merging or production storage provisioning
is automatic.

Errors are `{error:code}` with no input or credentials echoed. Relevant statuses
are 400 validation/confirmation, 401 identity, 403 permission, 404 unknown target,
409 replay/state/conflict, 410 expired/revoked invite, 413 size, 429 rate limit,
503 unavailable adapter/backend. Clients must fail closed on errors and unknown
states and must not synthesize a successful membership while offline.

## Invitation and revocation behavior

The QR payload is only a fixed trusted HTTPS gateway origin and a 256-bit random
opaque token at `/family-invitations/TOKEN`. No role, name, COS secret or NAS
password is encoded in it. A preview is authenticated but neither consumes the
token nor authorizes family data. Explicitly confirming the displayed family,
role and expiry atomically consumes a valid token and creates a pending request.
Expiry is exclusive: the exact ten-minute boundary is expired. Admin invitations
are intentionally unsupported; privilege promotion needs a separate reviewed
policy. Approvals and denials are durable transactions; concurrent redemption or
approval produces one result, never duplicate active members. Token expiry limits
redemption, not the time an already pending request may await administrator review.

Revoking an invitation blocks new redemption and cancels its pending request.
Revoking a member immediately makes subsequent gateway membership checks fail.
Read/write chunks recheck current membership; revocation during a streamed
response aborts that stream, whose client must reject an incomplete size/hash.
An approved rejoin creates a new member ID and does not take ownership of the old
member's records. Revocation does not delete records or cached content. A client
may retain bytes already downloaded; physical deletion of all cached copies
cannot be promised.

## Record ownership and namespace boundaries

Gateway metadata endpoints are independently versioned API records:

- `GET /v1/families/F/records` → `{records:[...]}`; reads include tombstones.
- `POST /v1/families/F/records` with `{id,content}` assigns the active caller's
  member as owner and starts revision 1. Identical owner/content retries are
  idempotent. Different content under an existing ID conflicts.
- `GET /v1/families/F/records/R` returns `{id,familyID,ownerMemberID,revision,
  content,deleted}`.
- `PUT .../records/R` with `{expectedRevision,content}` is allowed only to the
  owner when their role permits contribution. Stale versions conflict; admins
  cannot silently edit another member's content.
- `DELETE .../records/R` is a distinct administrator-only operation. It writes a
  tombstone and a separate audit event rather than silently deleting originals.

The generic `/records` API is a separate metadata store; it never writes the
immutable archive catalog, snapshot blobs or revision history. Updating a generic
record cannot modify a published snapshot. Family backup/restore uses the actual
canonical snapshot API below. Legacy `life/v1` copying remains separately reviewed;
no legacy archive is renamed, overwritten or cleaned up.

## Canonical family/v1 snapshot publication and independent restore

`archives.py` validates and durably stores the same version-1 manifest as Dart
`FamilyArchiveManifest` and `JsonWire`. The logical immutable key is
`family/v1/F/members/M/devices/D/manifests/SEQUENCE-SHA256.json`; shared originals
and previews use `family/v1/F/members/M/objects/SHA256`. All namespace IDs are
uppercase canonical UUIDs and hashes are lowercase hex. Human names never form
keys. SQLite stores the exact canonical UTF-8 bytes (maximum 8 MiB), descriptor,
member-wide revision history and object-reference set in one transaction.

| Method and path | Behavior |
| --- | --- |
| `POST /v1/families/F/devices/D` with `{}` | Register D for the authenticated active member; viewer registration permits reads, not publishing. An existing device associated with another subject cannot be taken over. |
| `PUT /v1/families/F/members/M/devices/D/snapshots/SEQUENCE/SHA256` | Raw canonical JSON, Content-Length required, `Content-Type: application/json`, optional matching X-Content-SHA256; returns one descriptor. |
| `GET` at the same snapshot path | Exact raw canonical JSON plus Content-Length and X-Content-SHA256. Any currently active family member may read. |
| `GET /v1/families/F/archive?limit=100&cursor=TOKEN` | `{snapshots:[descriptor],nextCursor:null-or-token,moderationVersion,moderations}`; every immutable sequence is cataloged for independent chain validation. |

A descriptor is exactly `familyID,memberID,deviceID,sequence,sha256,byteCount`.
Only the archive catalog accepts query parameters. Limit is 1..100; duplicate,
unknown, percent-encoded or malformed query fields fail. An opaque cursor is
bound to the authenticated subject, family, frozen snapshot and moderation upper
watermarks and a ten-minute expiry. New publications are visible in a fresh scan, not inserted
mid-scan. Catalog queries select descriptors only, never bulk-load snapshot BLOBs.
Expired or foreign cursors fail explicitly instead of returning a partial success.

The HTTP adapter checks the independent 8 MiB bound before reading raw snapshots;
this route does not inherit or bypass the generic 64 KiB metadata limit by an
unbounded read. Reads handle fragmented streams and never probe beyond declared
Content-Length. Strict schema validation rejects unknown/duplicate fields,
noncanonical bytes or ordering, unsafe resource filenames/MIME roles, invalid
calendar dates, floats/bools as integers and inconsistent media IDs/hash sizes.
UTF-16 text limits and Dart whitespace behavior are preserved across languages.

Publishing requires the current authenticated member to own M and registered D,
and to hold contributor/admin permission. Claimed IDs in the manifest do not
supply authority. The first sequence has a null parent; later sequences are
contiguous with the exact predecessor hash and retain prior device records and
anniversaries. Deletion is an explicit tombstone, never an omission. An equal
member/record/revision must have identical canonical bytes across all device
chains; older versions cannot overwrite a newer member-wide head. Stable media
identifiers cannot be rebound to altered assets/resources. Every original **and**
preview is independently statted and hashed under the authenticated member prefix
before publication; missing/corrupt bytes or wrong sizes roll back the entire
snapshot, history, references and audit event. Exact retries recheck the media
and return the existing descriptor without a second catalog row.

Publication and physical object deletion serialize on the same SQLite write
transaction. A retained snapshot's referenced object cannot be physically removed
through the object DELETE API (`409 referencedObject`). There is no pruning or
original-cleanup feature. A concurrent delete either finishes before publication,
which then fails for missing media, or publication commits first and blocks the
delete. Neither ordering publishes a snapshot missing an original.

A normal snapshot PUT cannot introduce a new tombstone or resurrect one, even
for an administrator. A separately initiated administrator action must explicitly
supply `X-DaysWith-Deletion-Intent: explicit-admin-action`; the server checks the
current role and writes distinct record/anniversary delete or restore audit
events. The ordinary Dart archive client never sends that header. Existing
identical tombstones may be carried forward without a new deletion intent.
Local trash state is therefore not an implicit shared-delete authorization.
Cross-owner removal uses the separate moderation overlay below, preserving the
other member's immutable chain. The ordinary `/records` DELETE cannot rewrite
archive snapshots or grant moderation authority.

The synthetic service acceptance vector uploads ten valid PNG originals, one
actual locally generated playable MPEG-4 video, eleven separate previews, text
and a leap-day anniversary, then downloads the catalog and exact manifests into
an independent restore directory and verifies all 22 media objects by bytes,
length and SHA-256. This proves the isolated service data path; it is not Android/
iOS execution or a real NAS/COS acceptance result.

## Explicit administrator moderation overlay

`POST /v1/families/F/members/M/records/R/moderation` accepts exactly
`{expectedRevision:int,hidden:bool}`. It requires a current active family
administrator, validates the target member's latest archived record revision,
and returns an append-only event:

```json
{"id":1,"familyID":"F","ownerMemberID":"M","recordID":"R","hidden":true,"recordRevision":1,"at":1900000000000,"actorMemberID":"ADMIN"}
```

F/M/R/ADMIN denote canonical UUIDs in this example; `at` is UTC epoch milliseconds.
Stale expected record revisions conflict. A repeated current desired state with
the same record revision returns the existing event without another audit/version.
A new hide/unhide decision writes a distinct moderation event and audit action.
Contributor/viewer requests cannot promote themselves with body fields or headers.

The archive catalog includes `moderationVersion` (0 when empty) and `moderations`,
the latest event per owner/record at its frozen watermark, ordered by event ID.
Each cursor page returns the same overlay and version; a concurrent hide/unhide
appears in a new scan. Overlay materialization is limited to 2000 entries and
768 KiB; oversized overlays fail explicitly instead of hiding a truncated set.
An expired or revoked actor cannot use a catalog cursor as authorization.

A hidden record may be carried with its exact previous canonical fingerprint in
a later full snapshot. Changing its content or publishing a new revision is
rejected until an explicit administrator unhide event. Other owned records may
still advance. The client keeps raw ownership/history and applies the overlay
only to its visible view, including it in the catalog verification fingerprint.
Moderation never rewrites another member's original snapshot or physically deletes
media. Authorized family members can still access retained raw history; hiding
is not cryptographic erasure or a promise to recall cached content. Physical
original cleanup remains outside this release scope.

## Durable object gateway and COS boundary

`ObjectStore` manages an isolated local/mounted directory; a dedicated protected
NAS mount can be supplied by a host. It is not a WebDAV network adapter. Never
point it at a user's photo-library originals. No upstream NAS URL comes from an
HTTP request. `validate_https_origin` is the fail-closed configuration boundary
for a future HTTPS upstream adapter; a real WebDAV/network proxy is still pending.

`PUT/GET/HEAD/DELETE /v1/families/F/members/M/objects/SHA256` route through current
membership and owner checks. PUT requires `Content-Length` and
`X-Content-SHA256`, matching the path and actual streamed bytes. The default limit
is 256 MiB per object, deliberately configurable by the operator for video
requirements; larger files fail visibly rather than loading into memory. Data
is hashed in bounded chunks, written to a private temporary file, fsynced and
installed without replacing an existing original. Concurrent identical retries
are safe; altered or corrupted originals conflict. Stat and read validate the
content address. Symlink/path traversal is rejected at directory-handle level.
A Content-Length-bounded WSGI adapter never reads beyond the HTTP body.
Only contributors/admins can upload to their own member prefix. All active
members may read family objects; deleting an original is a separate explicit
administrator operation; any retained archive reference blocks it. Its audit intent is committed before unlink, followed
by a completion or failure event. A crash can leave an unfinished intent for
operator reconciliation; it cannot erase the durable intent. The streaming client must independently
verify expected size and SHA-256 before declaring a valid remote copy.

`POST /v1/families/F/credentials` accepts optional `durationSeconds` (1..600) but
is unavailable unless both `cos_scope` and an injected `RestrictedStsIssuer` are
configured by the host. Bucket/region/appid and role are never supplied by the
client. The policy builder uses only the selected family's object prefix and
`GetObject/HeadObject` actions. It grants no write, delete, listing or ACL action:
plain PutObject credentials could overwrite originals, so uploads stay behind
the gateway until conditional immutable writes have been independently validated.
The official STS SDK callback is implemented and tested offline as described
below. Real TLS/STS calls, IAM policy enforcement and provider revocation have
not been deployed or accepted; those require separately authorized validation.

The issuer output is strictly bounded and checked before/after current membership
authorization. Its representation is redacted; audit stores only a member ID.
Revocation stops future issuance but already issued COS credentials can remain
valid until their explicit expiry (at most 600 seconds here). The API does not
claim early revocation of those keys or recall of previously downloaded data.

## Official Tencent STS adapter and COS family-write blocker

`cos_sts.py` supplies an opt-in `TencentCosStsCallback` for `RestrictedStsIssuer`.
It uses pinned official modular Tencent STS/common SDKs, defaulting to disabled.
The explicit credential-provider factory is lazy: disabled or rejected policies
never invoke it. It discovers no environment credentials and provides no login,
key-creation or deployment operation. The host must supply a properly authorized
server-side permanent IAM credential through the explicit provider; temporary
SDK credentials are rejected because this API requires permanent keys.

The callback only accepts the exact read-only `cos_policy` for its configured
account/bucket/region and a canonical family prefix. Widened actions/resources,
principal/condition additions, malformed durations or oversized policy fail
before an SDK call. `GetFederationTokenRequest.Policy` is canonical JSON followed
by URL encoding. `Name` is a random letters-only 32-character label containing no
family/member/subject identifier, following the [official API contract](https://www.tencentcloud.com/document/api/1150/49452).

The factory uses only the explicit official STS endpoint allowlist, HTTPS POST,
TC3-HMAC-SHA256, a bounded timeout and no retryer/region fallback. The actual SDK
request/response models and secure profile fields are exercised with fake
transports. Credential output is bounded and redacted; expiry is at most 600
seconds and must still be valid when the callback returns. All provider errors,
including custom exceptions, normalize without credential-bearing text. Existing
membership checks run before and after issuance in `RestrictedStsIssuer`.
These tests do not make an authenticated STS call or prove a live IAM policy.

The family data backend currently supports the dedicated local/NAS-mounted
`ObjectStore`; it does **not** supply a COS family object-write adapter. This is
a specific unresolved integration blocker, separate from existing direct COS
backup in the Dart application and the new read-only STS callback:

- Official `cos-python-sdk-v5` 1.9.44 metadata requires requests <=2.27.1 and
  certifi <=2021.10.8, conflicting with this gateway's current pinned transport.
  Its SDK runtime was not installed and modern dependencies were not downgraded.
  A vendor-supported adapter compatible with the current transport is required.
- [COS PutObject documentation](https://www.tencentcloud.com/document/product/436/7749)
  states that `x-cos-forbid-overwrite` is ineffective when bucket versioning is
  enabled. A read-before-write check alone cannot prove immutable concurrent
  writes. Real conditional-write behavior, bucket configuration and the
  gateway principal's ability to change that configuration must be verified
  before enabling a COS writer. Enabled/suspended/unknown versioning cannot be
  silently treated as safe.

No custom signing implementation, unknown mirror, obsolete dependency runtime,
real bucket configuration or persistent credential was substituted to hide these
blockers. COS family writes remain disabled; NAS-mounted gateway tests cannot be
reported as COS acceptance.

## Executed evidence and remaining acceptance

Run from repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s services/family_gateway/tests -v
```

Archive/gateway/request/storage/binding/moderation checks: 117 passing standard-library tests, using
temporary directories, ephemeral synthetic authentication and generated media.
The official STS callback adds 17 offline SDK tests. The identity and STS suites
require the pinned optional dependencies (`requirements-auth.txt` and
`requirements-sts.txt`); run the full command in that configured environment. It covers restart persistence, authenticated
identity and HTTPS boundaries, pending-only joins, expiry, confirmation binding,
concurrent exchange and approval across separate gateway instances, denial and
invitation/member revocation, ownership, role restrictions, rate/body limits,
audit/token separation, immutable media, corruption, interruption, bounded IO,
path attacks and STS policy/expiry boundaries.

This does not replace real identity-provider review, independent security review,
actual HTTPS WebDAV/COS round trips, 10-photo/one-video device restoration,
Android/iOS execution or revocation acceptance. Logging at TLS/proxy/WSGI layers
must explicitly redact invitation URLs, Authorization and credential responses;
this module has no request logger, but cannot control an operator's host logs.
Deployment, production credentials and operational configuration require separate
authorization and remain blocked.
