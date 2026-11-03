"""Synthetic WSGI archive acceptance; no real family data or storage service.

The complete-restore vector uses 10 valid tiny PNGs and, when ffmpeg is present,
one locally generated playable MPEG-4 video. It verifies bytes, not device UI.
"""
import copy
import hashlib
import io
import json
from pathlib import Path
import secrets
import shutil
import struct
import subprocess
import tempfile
import threading
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import quote
import zlib

from services.family_gateway.gateway import Gateway, SyntheticHmacVerifier
from services.family_gateway.storage import ObjectStore


def uid():
    return str(uuid.uuid4()).upper()


def digest(body):
    return hashlib.sha256(body).hexdigest()


def canonical(value):
    # Valid scalar code-point order and UTF-8 order agree. All schema field
    # names are ASCII; non-ASCII text values remain unescaped UTF-8 like Dart.
    return json.dumps(value, sort_keys=True, ensure_ascii=False,
                      separators=(',', ':'), allow_nan=False).encode('utf-8')


def png(colour, width=2, height=2):
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff)
    scanlines = b''.join(b'\x00' + bytes(colour) * width for _ in range(height))
    return (b'\x89PNG\r\n\x1a\n' +
            chunk(b'IHDR', struct.pack('!IIBBBBB', width, height, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(scanlines)) + chunk(b'IEND', b''))


class ArchivePublicationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.video = None
        if shutil.which('ffmpeg'):
            with tempfile.TemporaryDirectory() as root:
                video = Path(root) / 'synthetic.mp4'
                subprocess.run([
                    'ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin',
                    '-f', 'lavfi', '-i', 'color=c=blue:s=16x16:d=0.2:r=10',
                    '-an', '-c:v', 'mpeg4', '-q:v', '8', '-movflags', '+faststart',
                    '-y', str(video),
                ], check=True, timeout=20, capture_output=True)
                cls.video = video.read_bytes()
                if shutil.which('ffprobe'):
                    probe = subprocess.run([
                        'ffprobe', '-v', 'error', '-select_streams', 'v:0',
                        '-show_entries', 'stream=codec_name,width,height',
                        '-of', 'json', str(video),
                    ], check=True, timeout=10, capture_output=True)
                    cls.video_probe = json.loads(probe.stdout)['streams'][0]

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.database = Path(self.temp.name) / 'family.sqlite3'
        self.store = ObjectStore(Path(self.temp.name) / 'objects')
        self.now = 1900000000
        self.verifier = SyntheticHmacVerifier(secrets.token_bytes(32), synthetic_only=True,
                                              clock=lambda: self.now)
        self.admin = 'issuer|synthetic-archive-parent'
        self.device = uid()
        self.app = self.make_app()
        created = self.call('POST', '/v1/families', {
            'name': '合成家庭', 'displayName': '合成家长',
            'relationshipLabel': '爸爸', 'deviceID': self.device,
        })
        self.assertEqual(200, created['status'], created['body'])
        self.family = created['body']['family']['id']
        self.member = created['body']['currentMember']['id']
        self.register(self.device)

    def make_app(self):
        return Gateway(self.database, origin='https://family.example.test',
                       verify_bearer=self.verifier, clock=lambda: self.now,
                       object_store=self.store)

    def call(self, method, path, body=None, *, raw=None, subject=None,
             content_type='application/json', headers=None, declared_length=None, app=None):
        if raw is None:
            raw = canonical(body if body is not None else {}) if method in ('POST', 'PUT') else b''
        path, _, query = path.partition('?')
        env = {'REQUEST_METHOD': method, 'PATH_INFO': path, 'QUERY_STRING': query,
               'wsgi.url_scheme': 'https', 'wsgi.input': io.BytesIO(raw),
               'HTTP_HOST': 'family.example.test',
               'CONTENT_LENGTH': str(len(raw) if declared_length is None else declared_length),
               'CONTENT_TYPE': content_type,
               'HTTP_AUTHORIZATION': 'Bearer ' + self.verifier.sign_for_test(subject or self.admin)}
        env.update(headers or {})
        output = {}
        def start(status, values):
            output['status'] = int(status.split()[0])
            output['headers'] = dict(values)
        output['raw'] = b''.join((app or self.app)(env, start))
        if output['headers'].get('Content-Type', '').startswith('application/json'):
            output['body'] = json.loads(output['raw'])
        else:
            output['body'] = output['raw']
        return output

    def register(self, device, subject=None):
        result = self.call('POST', f'/v1/families/{self.family}/devices/{device}', {}, subject=subject)
        self.assertEqual(200, result['status'], result['body'])
        return result

    def record(self, *, device=None, record_id=None, revision=1, title='合成文字', assets=None):
        return {'id': record_id or uid(), 'ownerMemberID': self.member,
                'writerDeviceID': device or self.device, 'revision': revision,
                'occurredAt': 1900000000000, 'updatedAt': 1900000000000,
                'deletedAt': None, 'title': title, 'note': '只使用合成资料 😀\n第二行',
                'assets': sorted(assets or [], key=lambda a: a['id'])}

    def manifest(self, *, device=None, sequence=1, parent=None, records=None, anniversaries=None):
        return {'version': 1, 'familyID': self.family, 'memberID': self.member,
                'deviceID': device or self.device, 'sequence': sequence, 'parentHash': parent,
                'records': sorted(records if records is not None else [self.record()], key=lambda r: r['id']),
                'anniversaries': sorted(anniversaries or [], key=lambda a: a['id'])}

    def path(self, manifest, sha=None):
        return (f'/v1/families/{manifest["familyID"]}/members/{manifest["memberID"]}'
                f'/devices/{manifest["deviceID"]}/snapshots/{manifest["sequence"]}/'
                f'{sha or digest(canonical(manifest))}')

    def publish(self, manifest, **kwargs):
        raw = kwargs.pop('raw', None)
        raw = canonical(manifest) if raw is None else raw
        return self.call('PUT', self.path(manifest, digest(raw)), raw=raw, **kwargs)

    def resource(self, role, body, filename):
        sha = digest(body)
        return {'id': uid(), 'role': role,
                'contentType': 'video/mp4' if role == 'video' else 'image/png',
                'originalFilename': filename, 'byteCount': len(body), 'sha256': sha,
                'objectKey': f'family/v1/{self.family}/members/{self.member}/objects/{sha}'}

    def upload(self, resource, body, *, subject=None):
        path = f'/v1/families/{self.family}/members/{self.member}/objects/{resource["sha256"]}'
        result = self.call('PUT', path, raw=body, subject=subject,
                           content_type='application/octet-stream',
                           headers={'HTTP_X_CONTENT_SHA256': resource['sha256']})
        self.assertEqual(200, result['status'], result['body'])

    def photo_asset(self, number=0):
        original = png((10 + number, 80, 190))
        preview = png((10 + number, 81, 190), 1, 1)
        resources = [self.resource('photo', original, f'合成照片-{number}.png'),
                     self.resource('preview', preview, f'预览-{number}.png')]
        return ({'id': uid(), 'kind': 'photo', 'capturedAt': 1900000000000,
                 'resources': sorted(resources, key=lambda r: r['id'])},
                {digest(original): original, digest(preview): preview})

    def upload_assets(self, assets, objects):
        for asset in assets:
            for resource in asset['resources']:
                self.upload(resource, objects[resource['sha256']])

    def catalog(self, query='limit=100', *, subject=None, app=None):
        return self.call('GET', f'/v1/families/{self.family}/archive?{query}', subject=subject, app=app)

    def join(self, role, subject):
        invitation = self.call('POST', f'/v1/families/{self.family}/invitations',
                               {'requestedRole': role})['body']
        token = invitation['url'].rsplit('/', 1)[1]
        preview = self.call('GET', '/v1/invitations/' + token, subject=subject)['body']
        device = uid()
        request = self.call('POST', f'/v1/invitations/{token}/requests',
                            dict(preview, confirmed=True, displayName='合成成员',
                                 relationshipLabel='亲人', deviceID=device), subject=subject)
        self.assertEqual(200, request['status'], request['body'])
        approved = self.call('POST', '/v1/requests/' + request['body']['id'] + '/approve')
        self.assertEqual(200, approved['status'], approved['body'])
        return approved['body'], device

    def test_10_photos_one_playable_synthetic_video_text_anniversary_independent_restore(self):
        if self.video is None:
            self.skipTest('ffmpeg unavailable; complete playable-video vector not executed')
        photos, objects = [], {}
        for i in range(10):
            asset, contents = self.photo_asset(i)
            photos.append(asset)
            objects.update(contents)
        video_preview = png((220, 30, 80), 1, 1)
        video_resources = [self.resource('video', self.video, '合成视频.mp4'),
                           self.resource('preview', video_preview, '合成视频预览.png')]
        video_asset = {'id': uid(), 'kind': 'video', 'capturedAt': 1900000000000,
                       'resources': sorted(video_resources, key=lambda r: r['id'])}
        assets = photos + [video_asset]
        objects.update({digest(self.video): self.video, digest(video_preview): video_preview})
        # Match the foreground client pipeline: fresh target identity, probe,
        # upload and independently verify each original/preview before publish.
        # All requests share one fixed minute, exercising the normal 11-asset
        # budget without treating 429 as success or silently retrying it.
        for asset in assets:
            for resource in asset['resources']:
                path = f'/v1/families/{self.family}/members/{self.member}/objects/{resource["sha256"]}'
                self.assertEqual(404, self.call('HEAD', path)['status'])
                detail = self.call('GET', f'/v1/families/{self.family}')
                self.assertEqual(200, detail['status'])
                self.assertEqual(self.store.storage_id, detail['body']['family']['primaryStorageID'])
                self.upload(resource, objects[resource['sha256']])
                head = self.call('HEAD', path)
                self.assertEqual(200, head['status'])
                self.assertEqual(str(resource['byteCount']), head['headers']['Content-Length'])
                verified = self.call('GET', path)
                self.assertEqual(200, verified['status'])
                self.assertEqual(resource['sha256'], digest(verified['raw']))
        date = {'id': uid(), 'ownerMemberID': self.member, 'title': '合成纪念日',
                'date': '0004-02-29', 'revision': 1, 'deletedAt': None}
        manifest = self.manifest(records=[self.record(assets=[a]) for a in assets] +
                                 [self.record(title='独立文字记录')], anniversaries=[date])
        published = self.publish(manifest)
        self.assertEqual(200, published['status'], published['body'])
        catalog = self.catalog(app=self.make_app())
        self.assertEqual(200, catalog['status'], catalog['body'])
        self.assertEqual(1, len(catalog['body']['snapshots']))
        descriptor = catalog['body']['snapshots'][0]
        for key in ('familyID', 'memberID', 'deviceID', 'sequence', 'sha256', 'byteCount'):
            self.assertIn(key, descriptor)
        recovered = self.call('GET', self.path(manifest), app=self.make_app())
        self.assertEqual(200, recovered['status'])
        self.assertEqual(descriptor['sha256'], digest(recovered['raw']))
        self.assertEqual(descriptor['byteCount'], len(recovered['raw']))
        restored = json.loads(recovered['raw'])
        self.assertEqual(manifest, restored)
        self.assertEqual(12, len(restored['records']))
        self.assertEqual([date], restored['anniversaries'])
        recovered_objects = set()
        with tempfile.TemporaryDirectory() as recovery_root:
            for record in restored['records']:
                self.assertEqual(self.member, record['ownerMemberID'])
                for asset in record['assets']:
                    for resource in asset['resources']:
                        path = '/v1/families/' + self.family + '/members/' + self.member + '/objects/' + resource['sha256']
                        identity = self.call('GET', f'/v1/families/{self.family}', app=self.make_app())
                        self.assertEqual(200, identity['status'])
                        self.assertEqual(self.store.storage_id, identity['body']['family']['primaryStorageID'])
                        self.assertEqual(200, self.call('HEAD', path, app=self.make_app())['status'])
                        read = self.call('GET', path, app=self.make_app())
                        self.assertEqual(200, read['status'])
                        self.assertEqual(resource['byteCount'], len(read['raw']))
                        self.assertEqual(resource['sha256'], digest(read['raw']))
                        target = Path(recovery_root) / resource['sha256']
                        target.write_bytes(read['raw'])
                        self.assertEqual(objects[resource['sha256']], target.read_bytes())
                        recovered_objects.add(resource['sha256'])
        self.assertEqual(22, len(recovered_objects))
        self.assertIn(b'ftyp', self.video[:32])
        if hasattr(self, 'video_probe'):
            self.assertEqual('mpeg4', self.video_probe['codec_name'])

    def test_restart_and_same_snapshot_retry_do_not_duplicate_catalog(self):
        manifest = self.manifest()
        first = self.publish(manifest)
        self.assertEqual(200, first['status'], first['body'])
        restart = self.make_app()
        second = self.publish(manifest, app=restart)
        self.assertEqual(200, second['status'], second['body'])
        self.assertEqual(first['body'], second['body'])
        self.assertEqual(1, len(self.catalog(app=restart)['body']['snapshots']))

    def test_interrupted_snapshot_body_does_not_publish_and_exact_retry_recovers(self):
        manifest = self.manifest()
        raw = canonical(manifest)
        broken = self.call('PUT', self.path(manifest), raw=raw[:-11], declared_length=len(raw))
        self.assertEqual(400, broken['status'], broken['body'])
        self.assertEqual([], self.catalog()['body']['snapshots'])
        self.assertEqual(200, self.publish(manifest)['status'])

    def test_path_digest_and_metadata_size_limit_are_enforced(self):
        manifest = self.manifest()
        wrong_hash = self.call('PUT', self.path(manifest, '0' * 64), raw=canonical(manifest))
        self.assertEqual(400, wrong_hash['status'], wrong_hash['body'])
        oversized = b' ' * (8 * 1024 * 1024 + 1)
        rejected = self.call('PUT', self.path(manifest, digest(oversized)), raw=oversized)
        self.assertEqual(413, rejected['status'], rejected['body'])
        self.assertEqual([], self.catalog()['body']['snapshots'])

    def test_concurrent_different_snapshot_publication_has_one_winner(self):
        record = self.record()
        first = self.manifest(records=[record])
        second = copy.deepcopy(first)
        second['records'][0]['title'] = '并发另一分支'
        barrier = threading.Barrier(2)
        apps = [self.app, self.make_app()]
        def publish(pair):
            data, app = pair
            barrier.wait()
            return self.publish(data, app=app)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(publish, zip([first, second], apps)))
        self.assertEqual([200, 409], sorted(r['status'] for r in results), results)
        self.assertEqual(1, len(self.catalog()['body']['snapshots']))

    def test_missing_corrupt_and_wrong_size_media_never_publish(self):
        asset, objects = self.photo_asset()
        manifest = self.manifest(records=[self.record(assets=[asset])])
        self.assertNotEqual(200, self.publish(manifest)['status'])
        self.upload_assets([asset], objects)
        bad_size = copy.deepcopy(manifest)
        bad_size['records'][0]['assets'][0]['resources'][0]['byteCount'] += 1
        self.assertNotEqual(200, self.publish(bad_size)['status'])
        resource = asset['resources'][0]
        (self.store.root / resource['objectKey']).write_bytes(b'corrupt synthetic media')
        self.assertNotEqual(200, self.publish(manifest)['status'])
        self.assertEqual([], self.catalog()['body']['snapshots'])

    def test_unregistered_device_wrong_owner_and_wrong_family_fail_closed(self):
        unregistered = self.manifest(device=uid())
        self.assertEqual(403, self.publish(unregistered)['status'])
        wrong_owner = self.manifest()
        wrong_owner['memberID'] = uid()
        wrong_owner['records'][0]['ownerMemberID'] = wrong_owner['memberID']
        self.assertEqual(403, self.publish(wrong_owner)['status'])
        wrong_family = self.manifest()
        wrong_family['familyID'] = uid()
        self.assertEqual(403, self.publish(wrong_family)['status'])

    def test_full_successor_requires_chain_parent_and_retains_records_and_dates(self):
        anniversary = {'id': uid(), 'ownerMemberID': self.member, 'title': '纪念日',
                       'date': '2024-02-29', 'revision': 1, 'deletedAt': None}
        first = self.manifest(anniversaries=[anniversary])
        self.assertEqual(200, self.publish(first)['status'])
        second = self.manifest(sequence=2, parent=digest(canonical(first)),
                               records=copy.deepcopy(first['records']), anniversaries=[anniversary])
        wrong_parent = copy.deepcopy(second)
        wrong_parent['parentHash'] = '0' * 64
        self.assertEqual(409, self.publish(wrong_parent)['status'])
        dropped_record = copy.deepcopy(second)
        dropped_record['records'] = []
        self.assertEqual(409, self.publish(dropped_record)['status'])
        dropped_date = copy.deepcopy(second)
        dropped_date['anniversaries'] = []
        self.assertEqual(409, self.publish(dropped_date)['status'])
        self.assertEqual(200, self.publish(second)['status'])

    def test_cross_device_equal_revision_fork_and_old_revision_are_rejected(self):
        original = self.record()
        first = self.manifest(records=[original])
        self.assertEqual(200, self.publish(first)['status'])
        other_device = uid()
        self.register(other_device)
        fork_record = copy.deepcopy(original)
        fork_record.update(title='同版本不同内容', writerDeviceID=other_device)
        fork = self.manifest(device=other_device, records=[fork_record])
        self.assertEqual(409, self.publish(fork)['status'])
        revised = copy.deepcopy(original)
        revised.update(revision=2, title='较新内容')
        second = self.manifest(sequence=2, parent=digest(canonical(first)), records=[revised])
        self.assertEqual(200, self.publish(second)['status'])
        older = self.manifest(device=other_device, records=[original])
        self.assertEqual(409, self.publish(older)['status'])
        revised.update(revision=3, writerDeviceID=other_device, title='另一设备明确新版本')
        latest = self.manifest(device=other_device, records=[revised])
        self.assertEqual(200, self.publish(latest)['status'])

    def test_ownership_cannot_change_inside_authenticated_manifest(self):
        manifest = self.manifest()
        manifest['records'][0]['ownerMemberID'] = uid()
        self.assertEqual(400, self.publish(manifest)['status'])

    def test_revocation_stops_publication_catalog_and_snapshot_reads(self):
        guest = 'issuer|synthetic-archive-contributor'
        invitation = self.call('POST', f'/v1/families/{self.family}/invitations',
                               {'requestedRole': 'contributor'})['body']
        token = invitation['url'].rsplit('/', 1)[1]
        preview = self.call('GET', '/v1/invitations/' + token, subject=guest)['body']
        guest_device = uid()
        request = self.call('POST', f'/v1/invitations/{token}/requests',
                            dict(preview, confirmed=True, displayName='合成成员',
                                 relationshipLabel='外婆', deviceID=guest_device), subject=guest)['body']
        approved = self.call('POST', '/v1/requests/' + request['id'] + '/approve')['body']
        self.register(guest_device, subject=guest)
        admin_member = self.member
        self.member = approved['id']
        try:
            manifest = self.manifest(device=guest_device,
                                     records=[self.record(device=guest_device)])
        finally:
            self.member = admin_member
        self.assertEqual(200, self.publish(manifest, subject=guest)['status'])
        self.assertEqual(200, self.call('GET', self.path(manifest), subject=guest)['status'])
        revoked = self.call('POST', f'/v1/families/{self.family}/members/{approved["id"]}/revoke')
        self.assertEqual(200, revoked['status'], revoked['body'])
        self.assertEqual(403, self.catalog(subject=guest)['status'])
        self.assertEqual(403, self.call('GET', self.path(manifest), subject=guest)['status'])
        self.assertEqual(403, self.publish(manifest, subject=guest)['status'])
        self.assertEqual(403, self.call('POST', f'/v1/families/{self.family}/devices/{uid()}', {}, subject=guest)['status'])

    def test_published_archive_protects_referenced_original_from_physical_delete(self):
        asset, objects = self.photo_asset()
        self.upload_assets([asset], objects)
        manifest = self.manifest(records=[self.record(assets=[asset])])
        self.assertEqual(200, self.publish(manifest)['status'])
        original = next(r for r in asset['resources'] if r['role'] == 'photo')
        path = f'/v1/families/{self.family}/members/{self.member}/objects/{original["sha256"]}'
        denied = self.call('DELETE', path)
        self.assertEqual(409, denied['status'], denied['body'])
        self.assertEqual('referencedObject', denied['body']['error'])
        restored = self.call('GET', path)
        self.assertEqual(200, restored['status'])
        self.assertEqual(objects[original['sha256']], restored['raw'])

    def test_admin_tombstone_and_resurrection_require_explicit_intent_and_separate_audit(self):
        record = self.record()
        record['deletedAt'] = 1900000000001
        anniversary = {'id': uid(), 'ownerMemberID': self.member, 'title': '已删除纪念日',
                       'date': '0004-02-29', 'revision': 1, 'deletedAt': 1900000000001}
        first = self.manifest(records=[record], anniversaries=[anniversary])
        self.assertEqual(403, self.publish(first)['status'])
        intent = {'HTTP_X_DAYSWITH_DELETION_INTENT': 'explicit-admin-action'}
        self.assertEqual(200, self.publish(first, headers=intent)['status'])
        carried = self.manifest(sequence=2, parent=digest(canonical(first)),
                                records=[copy.deepcopy(record)], anniversaries=[copy.deepcopy(anniversary)])
        self.assertEqual(200, self.publish(carried)['status'])
        restored_record = dict(record, revision=2, deletedAt=None)
        restored_date = dict(anniversary, revision=2, deletedAt=None)
        restored = self.manifest(sequence=3, parent=digest(canonical(carried)),
                                 records=[restored_record], anniversaries=[restored_date])
        self.assertEqual(403, self.publish(restored)['status'])
        self.assertEqual(200, self.publish(restored, headers=intent)['status'])
        audit = self.call('GET', f'/v1/families/{self.family}/audit')['body']['events']
        for kind, entity in (('records', record['id']), ('anniversaries', anniversary['id'])):
            for transition in ('delete', 'restore'):
                matching = [a for a in audit if a['action'] == f'archive.{kind}.{transition}'
                            and a['targetID'] == entity]
                self.assertEqual(1, len(matching), (kind, transition, audit))

    def test_contributor_cannot_gain_delete_authority_with_explicit_header(self):
        subject = 'issuer|synthetic-contributor-intent'
        member, device = self.join('contributor', subject)
        admin_member = self.member
        self.member = member['id']
        try:
            record = self.record(device=device)
            record['deletedAt'] = 1900000000001
            manifest = self.manifest(device=device, records=[record])
        finally:
            self.member = admin_member
        self.assertEqual(403, self.publish(manifest, subject=subject)['status'])
        self.assertEqual(403, self.publish(manifest, subject=subject, headers={
            'HTTP_X_DAYSWITH_DELETION_INTENT': 'explicit-admin-action'})['status'])
        self.assertEqual([], self.catalog(subject=subject)['body']['snapshots'])

    def test_viewer_can_register_and_read_but_cannot_publish(self):
        first = self.manifest()
        self.assertEqual(200, self.publish(first)['status'])
        subject = 'issuer|synthetic-archive-viewer'
        member, _ = self.join('viewer', subject)
        viewer_device = uid()
        self.register(viewer_device, subject=subject)
        self.assertEqual(200, self.catalog(subject=subject)['status'])
        self.assertEqual(canonical(first), self.call('GET', self.path(first), subject=subject)['raw'])
        admin_member = self.member
        self.member = member['id']
        try:
            manifest = self.manifest(device=viewer_device,
                                     records=[self.record(device=viewer_device)])
        finally:
            self.member = admin_member
        self.assertEqual(403, self.publish(manifest, subject=subject)['status'])

    def test_device_owned_by_another_subject_cannot_be_registered(self):
        subject = 'issuer|synthetic-other-device-owner'
        _, guest_device = self.join('contributor', subject)
        self.register(guest_device, subject=subject)
        conflict = self.call('POST', f'/v1/families/{self.family}/devices/{self.device}', {}, subject=subject)
        self.assertEqual(409, conflict['status'], conflict['body'])

    def test_delete_and_publish_race_never_leaves_a_published_snapshot_without_original(self):
        asset, objects = self.photo_asset()
        self.upload_assets([asset], objects)
        manifest = self.manifest(records=[self.record(assets=[asset])])
        original = next(r for r in asset['resources'] if r['role'] == 'photo')
        path = f'/v1/families/{self.family}/members/{self.member}/objects/{original["sha256"]}'
        barrier = threading.Barrier(2)
        other_app = self.make_app()
        def publish():
            barrier.wait()
            return self.publish(manifest)
        def delete():
            barrier.wait()
            return self.call('DELETE', path, app=other_app)
        with ThreadPoolExecutor(max_workers=2) as pool:
            publishing = pool.submit(publish)
            deleting = pool.submit(delete)
            published, removed = publishing.result(), deleting.result()
        self.assertIn((published['status'], removed['status']), ((200, 409), (409, 200)))
        entries = self.catalog()['body']['snapshots']
        read = self.call('GET', path)
        if published['status'] == 200:
            self.assertEqual(1, len(entries))
            self.assertEqual('referencedObject', removed['body']['error'])
            self.assertEqual(200, read['status'])
            self.assertEqual(objects[original['sha256']], read['raw'])
        else:
            self.assertEqual([], entries)
            self.assertEqual('missingMedia', published['body']['error'])
            self.assertEqual(404, read['status'])

    def test_schema_duplicates_and_noncanonical_json_are_rejected(self):
        base = self.manifest()
        variants = []
        extra = copy.deepcopy(base)
        extra['unknown'] = True
        variants.append(('unknown field', canonical(extra)))
        duplicate = copy.deepcopy(base)
        duplicate['records'].append(copy.deepcopy(duplicate['records'][0]))
        variants.append(('duplicate record id', canonical(duplicate)))
        boolean = copy.deepcopy(base)
        boolean['version'] = True
        variants.append(('boolean version', canonical(boolean)))
        number = copy.deepcopy(base)
        number['records'][0]['revision'] = 1.0
        variants.append(('float revision', canonical(number)))
        variants.append(('duplicate key', b'{"version":1,' + canonical(base)[1:]))
        variants.append(('spaces', json.dumps(base, ensure_ascii=False, indent=2).encode()))
        variants.append(('invalid utf8', b'\xff'))
        for name, raw in variants:
            with self.subTest(name=name):
                result = self.publish(base, raw=raw)
                self.assertEqual(400, result['status'], result['body'])
        self.assertEqual([], self.catalog()['body']['snapshots'])

    def test_content_type_filename_and_calendar_date_validation(self):
        asset, objects = self.photo_asset()
        self.upload_assets([asset], objects)
        valid = self.manifest(records=[self.record(assets=[asset])])
        bad_type = copy.deepcopy(valid)
        bad_type['records'][0]['assets'][0]['resources'][0]['contentType'] = 'text/plain'
        bad_name = copy.deepcopy(valid)
        bad_name['records'][0]['assets'][0]['resources'][0]['originalFilename'] = '../original.png'
        bad_date = copy.deepcopy(valid)
        bad_date['anniversaries'] = [{'id': uid(), 'ownerMemberID': self.member,
            'title': '无效日期', 'date': '2025-02-29', 'revision': 1, 'deletedAt': None}]
        for data in (bad_type, bad_name, bad_date):
            self.assertEqual(400, self.publish(data)['status'])
        self.assertEqual(400, self.publish(valid, content_type='application/octet-stream')['status'])
        self.assertEqual(200, self.publish(valid)['status'])

    def test_catalog_watermark_cursor_expiry_and_subject_family_binding(self):
        first = self.manifest()
        self.assertEqual(200, self.publish(first)['status'])
        device = uid()
        self.register(device)
        self.assertEqual(200, self.publish(self.manifest(device=device))['status'])
        page = self.catalog('limit=1')['body']
        cursor = page['nextCursor']
        late_device = uid()
        self.register(late_device)
        late = self.manifest(device=late_device)
        self.assertEqual(200, self.publish(late)['status'])
        next_page = self.catalog('limit=100&cursor=' + cursor)
        self.assertEqual(1, len(next_page['body']['snapshots']))
        self.assertIsNone(next_page['body']['nextCursor'])
        self.assertEqual(3, len(self.catalog()['body']['snapshots']))
        subject = 'issuer|synthetic-cursor-viewer'
        self.join('viewer', subject)
        self.assertEqual(400, self.catalog('cursor=' + cursor, subject=subject)['status'])
        other = self.call('POST', '/v1/families', {
            'name': 'Other', 'displayName': 'Owner', 'relationshipLabel': 'Parent', 'deviceID': uid()})['body']['family']['id']
        self.assertEqual(400, self.call('GET', f'/v1/families/{other}/archive?cursor={cursor}')['status'])
        self.now += 600
        self.assertEqual(400, self.catalog('cursor=' + cursor)['status'])

    def test_generic_record_api_cannot_rewrite_published_snapshot(self):
        manifest = self.manifest()
        raw = canonical(manifest)
        self.assertEqual(200, self.publish(manifest)['status'])
        record_id = manifest['records'][0]['id']
        path = f'/v1/families/{self.family}/records'
        self.assertEqual(200, self.call('POST', path, {'id': record_id, 'content': {'text': 'metadata only'}})['status'])
        self.assertEqual(200, self.call('PUT', path + '/' + record_id,
            {'expectedRevision': 1, 'content': {'text': 'metadata update'}})['status'])
        self.assertEqual(raw, self.call('GET', self.path(manifest))['raw'])
        self.assertEqual(digest(raw), self.catalog()['body']['snapshots'][0]['sha256'])

    def test_unicode_wire_bounds_and_fragmented_http_body(self):
        valid = self.manifest(records=[self.record(title='😀' * 100)])
        raw = canonical(valid)
        class FragmentedInput:
            def __init__(self, body):
                self.body, self.position = body, 0
            def read(self, amount):
                count = min(amount, 7)
                result = self.body[self.position:self.position + count]
                self.position += len(result)
                return result
        result = self.publish(valid, headers={'wsgi.input': FragmentedInput(raw)})
        self.assertEqual(200, result['status'], result['body'])
        for title in ('😀' * 101,):
            invalid = self.manifest(device=uid(), records=[self.record(title=title)])
            self.register(invalid['deviceID'])
            self.assertEqual(400, self.publish(invalid)['status'])
        empty = self.manifest(device=uid(), anniversaries=[{
            'id': uid(), 'ownerMemberID': self.member, 'title': '\ufeff \ufeff \ufeff',
            'date': '0004-02-29', 'revision': 1, 'deletedAt': None}])
        self.register(empty['deviceID'])
        self.assertEqual(400, self.publish(empty)['status'])

    def test_catalog_pagination_has_no_duplicates_and_rejects_invalid_queries(self):
        first = self.manifest()
        self.assertEqual(200, self.publish(first)['status'])
        device = uid()
        self.register(device)
        second = self.manifest(device=device)
        self.assertEqual(200, self.publish(second)['status'])
        page1 = self.catalog('limit=1')
        self.assertEqual(200, page1['status'], page1['body'])
        self.assertEqual(1, len(page1['body']['snapshots']))
        cursor = page1['body']['nextCursor']
        self.assertIsInstance(cursor, str)
        page2 = self.catalog('limit=1&cursor=' + quote(cursor, safe=''))
        self.assertEqual(200, page2['status'], page2['body'])
        all_items = page1['body']['snapshots'] + page2['body']['snapshots']
        self.assertEqual(2, len({(s['deviceID'], s['sequence'], s['sha256']) for s in all_items}))
        self.assertIsNone(page2['body']['nextCursor'])
        for query in ('limit=0', 'limit=not-a-number', 'cursor=../invalid', 'limit=1&limit=2'):
            with self.subTest(query=query):
                self.assertEqual(400, self.catalog(query)['status'])


if __name__ == '__main__':
    unittest.main()
