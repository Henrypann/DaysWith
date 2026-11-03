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
its hosting adapter must provide the true secure WSGI scheme and enforce the
configured host. There is no cookie authentication or redirect behavior.

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

## JSON wire contract

Fields use camelCase. UUID identifiers are normalized to uppercase. Names and
relationship labels are display fields and never become storage paths. Roles are
`admin`, `contributor`, `viewer`; member status is `active` or `revoked`.
`expiresAt` is an ISO 8601 UTC string; confirmed expiry is compared as an instant,
so a client `.000Z` representation is accepted. Every POST/PUT JSON request uses
`Content-Type: application/json`. Action POSTs send `{}`. Bodies are limited to
64 KiB and authenticated callers are rate-limited in persistent one-minute
windows (default 120 requests). List materialization is bounded to 2000 items
and 768 KiB of encoded entries; larger results fail explicitly with 413 rather
than silently truncate. Cursor pagination is not yet implemented and remains an
integration requirement before supporting larger families/history through this API. Edge authentication-abuse/connection limits are
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
`primaryStorageID` is currently null: this implementation does not provision or
switch a production storage target. The host configures one dedicated object
backend; automatically copying or merging targets is not implemented.

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

These SQLite metadata records are **not yet an exporter/importer for the Dart
`FamilyArchiveManifest` or legacy `life/v1` archive**. The client contract uses
immutable device snapshots under
`family/v1/F/members/M/devices/D/records/R/REVISION-SHA256.json`. The backend object
store aligns with its shared media prefix
`family/v1/F/members/M/objects/SHA256`, where SHA256 is lowercase 64 hex. Server
record JSON is intentionally stored in SQLite rather than pretending this API
already implements device-chain conflict resolution or full app restoration.
No old archive is renamed, overwritten or cleaned up.

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
administrator operation. Its audit intent is committed before unlink, followed
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
The real STS provider adapter, TLS calls, SDK integration, policy enforcement and
credential revocation have not been deployed or tested. The policy must still be
verified against current Tencent COS/STS behavior before production use.

The issuer output is strictly bounded and checked before/after current membership
authorization. Its representation is redacted; audit stores only a member ID.
Revocation stops future issuance but already issued COS credentials can remain
valid until their explicit expiry (at most 600 seconds here). The API does not
claim early revocation of those keys or recall of previously downloaded data.

## Executed evidence and remaining acceptance

Run from repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s services/family_gateway/tests -v
```

Current suite: 47 passing tests, using temporary directories, ephemeral synthetic
authentication and generated bytes. It covers restart persistence, authenticated
identity and HTTPS boundaries, pending-only joins, expiry, confirmation binding,
concurrent exchange and approval across separate gateway instances, denial and
invitation/member revocation, ownership, role restrictions, rate/body limits,
audit/token separation, immutable media, corruption, interruption, bounded IO,
path attacks and STS policy/expiry boundaries.

This does not replace real identity-provider review, independent security review,
actual HTTPS WebDAV/COS round trips, full 10-photo/one-video device restoration,
Android/iOS execution or revocation acceptance. Logging at TLS/proxy/WSGI layers
must explicitly redact invitation URLs, Authorization and credential responses;
this module has no request logger, but cannot control an operator's host logs.
Deployment, production credentials and operational configuration require separate
authorization and remain blocked.
