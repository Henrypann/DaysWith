"""Logical family moderation over immutable snapshots, using synthetic data.

The overlay hides/restores presentation only. Original snapshots and media stay
available for isolated recovery; this is not physical erasure of shared bytes.
"""
import copy
import sqlite3
import unittest
from urllib.parse import quote

from services.family_gateway.tests import test_archives as archive_fixtures


class ModerationTests(unittest.TestCase):
    def setUp(self):
        # Composition reuses only fixture helpers, without inheriting or running
        # the archive module's unrelated acceptance tests a second time.
        self.fixture = archive_fixtures.ArchivePublicationTests(methodName='runTest')
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.family = self.fixture.family
        self.admin_member = self.fixture.member
        self.contributor = 'issuer|synthetic-moderated-contributor'
        self.member, self.device = self.fixture.join('contributor', self.contributor)
        self.first = self.member_manifest()
        published = self.fixture.publish(self.first, subject=self.contributor)
        self.assertEqual(200, published['status'], published['body'])
        self.record = self.first['records'][0]

    def member_manifest(self, *, member=None, device=None, sequence=1, parent=None, records=None):
        fixture = self.fixture
        member = member or self.member
        device = device or self.device
        previous = fixture.member
        fixture.member = member['id']
        try:
            return fixture.manifest(device=device, sequence=sequence, parent=parent,
                                    records=records or [fixture.record(device=device)])
        finally:
            fixture.member = previous

    def path(self, owner=None, record=None, family=None):
        return (f'/v1/families/{family or self.family}/members/'
                f'{owner or self.member["id"]}/records/'
                f'{record or self.record["id"]}/moderation')

    def moderate(self, hidden, *, revision=1, subject=None, path=None, **kwargs):
        return self.fixture.call('POST', path or self.path(),
                                 {'expectedRevision': revision, 'hidden': hidden},
                                 subject=subject, **kwargs)

    def catalog(self, query='limit=100', *, subject=None):
        result = self.fixture.catalog(query, subject=subject)
        self.assertEqual(200, result['status'], result['body'])
        return result['body']

    def test_admin_cross_owner_hide_and_restore_are_separate_authenticated_events(self):
        before = self.catalog()
        self.assertEqual(0, before['moderationVersion'])
        self.assertEqual([], before['moderations'])
        hidden = self.moderate(True)
        self.assertEqual(200, hidden['status'], hidden['body'])
        event = hidden['body']
        self.assertGreater(event['id'], 0)
        self.assertEqual(self.family, event['familyID'])
        self.assertEqual(self.member['id'], event['ownerMemberID'])
        self.assertEqual(self.record['id'], event['recordID'])
        self.assertEqual(self.admin_member, event['actorMemberID'])
        self.assertEqual(1, event['recordRevision'])
        self.assertIs(event['hidden'], True)
        self.assertEqual(self.fixture.now * 1000, event['at'])
        current = self.catalog(subject=self.contributor)
        self.assertEqual(event['id'], current['moderationVersion'])
        self.assertEqual([event], current['moderations'])
        restored = self.moderate(False)
        self.assertEqual(200, restored['status'], restored['body'])
        self.assertGreater(restored['body']['id'], event['id'])
        self.assertIs(restored['body']['hidden'], False)
        after = self.catalog()
        self.assertEqual(restored['body']['id'], after['moderationVersion'])
        self.assertEqual([restored['body']], after['moderations'])

    def test_moderation_preserves_exact_raw_snapshot_bytes(self):
        original = self.fixture.call('GET', self.fixture.path(self.first))
        self.assertEqual(200, original['status'])
        self.assertEqual(archive_fixtures.canonical(self.first), original['raw'])
        self.assertEqual(200, self.moderate(True)['status'])
        hidden_source = self.fixture.call('GET', self.fixture.path(self.first), subject=self.contributor)
        self.assertEqual(original['raw'], hidden_source['raw'])
        self.assertIsNone(hidden_source['body']['records'][0]['deletedAt'])
        self.assertEqual(200, self.moderate(False)['status'])
        restored_source = self.fixture.call('GET', self.fixture.path(self.first))
        self.assertEqual(original['raw'], restored_source['raw'])
        self.assertEqual(self.first, restored_source['body'])

    def test_moderation_does_not_erase_referenced_original_or_preview(self):
        fixture = self.fixture
        previous = fixture.member
        fixture.member = self.member['id']
        try:
            asset, bodies = fixture.photo_asset()
            for resource in asset['resources']:
                fixture.upload(resource, bodies[resource['sha256']], subject=self.contributor)
            photo = fixture.record(device=self.device, assets=[asset])
        finally:
            fixture.member = previous
        source = self.member_manifest(sequence=2,
            parent=archive_fixtures.digest(archive_fixtures.canonical(self.first)),
            records=[copy.deepcopy(self.record), photo])
        self.assertEqual(200, fixture.publish(source, subject=self.contributor)['status'])
        hidden = self.moderate(True, path=self.path(record=photo['id']))
        self.assertEqual(200, hidden['status'], hidden['body'])
        for resource in asset['resources']:
            stored = fixture.store.root / resource['objectKey']
            self.assertTrue(stored.is_file())
            self.assertEqual(bodies[resource['sha256']], stored.read_bytes())
            self.assertEqual(resource['sha256'], archive_fixtures.digest(stored.read_bytes()))

    def test_contributor_and_viewer_cannot_moderate_even_own_records(self):
        denied = self.moderate(True, subject=self.contributor)
        self.assertEqual(403, denied['status'], denied['body'])
        viewer = 'issuer|synthetic-moderation-viewer'
        self.fixture.join('viewer', viewer)
        denied_viewer = self.moderate(True, subject=viewer)
        self.assertEqual(403, denied_viewer['status'], denied_viewer['body'])
        self.assertEqual([], self.catalog()['moderations'])

    def test_expected_revision_prevents_stale_and_malformed_decisions(self):
        stale = self.moderate(True, revision=2)
        self.assertEqual(409, stale['status'], stale['body'])
        for revision, hidden in ((True, True), (0, True), (1.0, True), (1, 1), (1, 'true')):
            with self.subTest(revision=revision, hidden=hidden):
                result = self.moderate(hidden, revision=revision)
                self.assertEqual(400, result['status'], result['body'])
        self.assertEqual([], self.catalog()['moderations'])

    def test_repeated_same_decision_is_idempotent_and_does_not_advance_version(self):
        first = self.moderate(True)
        second = self.moderate(True)
        self.assertEqual(200, first['status'], first['body'])
        self.assertEqual(200, second['status'], second['body'])
        self.assertEqual(first['body'], second['body'])
        catalog = self.catalog()
        self.assertEqual(first['body']['id'], catalog['moderationVersion'])
        self.assertEqual([first['body']], catalog['moderations'])
        audit = self.fixture.call('GET', f'/v1/families/{self.family}/audit')['body']['events']
        decisions = [event for event in audit if event['action'] == 'archive.moderation.hide'
                     and event['targetID'] == self.record['id']]
        self.assertEqual(1, len(decisions))

    def test_hidden_record_cannot_be_changed_but_exact_carry_and_new_record_are_allowed(self):
        self.assertEqual(200, self.moderate(True)['status'])
        changed = copy.deepcopy(self.record)
        changed.update(revision=2, title='隐藏期间不可借编辑恢复')
        rejected = self.member_manifest(sequence=2, parent=archive_fixtures.digest(
            archive_fixtures.canonical(self.first)), records=[changed])
        denied = self.fixture.publish(rejected, subject=self.contributor)
        self.assertEqual(403, denied['status'], denied['body'])
        additional = copy.deepcopy(self.record)
        additional.update(id=archive_fixtures.uid(), title='另一条明确新记录')
        carry = self.member_manifest(sequence=2, parent=archive_fixtures.digest(
            archive_fixtures.canonical(self.first)), records=[copy.deepcopy(self.record), additional])
        carried = self.fixture.publish(carry, subject=self.contributor)
        self.assertEqual(200, carried['status'], carried['body'])
        self.assertIs(self.catalog()['moderations'][0]['hidden'], True)
        restored = self.moderate(False)
        self.assertEqual(200, restored['status'], restored['body'])
        revised = self.member_manifest(sequence=3, parent=archive_fixtures.digest(
            archive_fixtures.canonical(carry)), records=[changed, additional])
        accepted = self.fixture.publish(revised, subject=self.contributor)
        self.assertEqual(200, accepted['status'], accepted['body'])

    def test_catalog_pages_pin_overlay_even_when_admin_changes_it_between_pages(self):
        second = self.fixture.manifest()
        self.assertEqual(200, self.fixture.publish(second)['status'])
        hide = self.moderate(True)
        self.assertEqual(200, hide['status'], hide['body'])
        first_page = self.catalog('limit=1')
        cursor = first_page['nextCursor']
        self.assertIsInstance(cursor, str)
        unhide = self.moderate(False)
        self.assertEqual(200, unhide['status'], unhide['body'])
        second_page = self.catalog('limit=1&cursor=' + quote(cursor, safe=''))
        self.assertEqual(first_page['moderationVersion'], second_page['moderationVersion'])
        self.assertEqual(first_page['moderations'], second_page['moderations'])
        self.assertEqual(hide['body']['id'], second_page['moderationVersion'])
        self.assertIs(second_page['moderations'][0]['hidden'], True)
        fresh = self.catalog()
        self.assertEqual(unhide['body']['id'], fresh['moderationVersion'])
        self.assertIs(fresh['moderations'][0]['hidden'], False)

    def test_expired_admin_session_cannot_issue_or_replay_moderation(self):
        self.assertEqual(200, self.moderate(True)['status'])
        token = self.fixture.verifier.sign_for_test(self.fixture.admin, duration=1)
        self.fixture.now += 1
        response = self.moderate(False, headers={'HTTP_AUTHORIZATION': 'Bearer ' + token})
        self.assertEqual(401, response['status'], response['body'])
        self.assertIs(self.catalog()['moderations'][0]['hidden'], True)

    def test_revoked_member_cannot_read_overlay_or_issue_moderation(self):
        self.assertEqual(200, self.moderate(True)['status'])
        revoked = self.fixture.call('POST',
            f'/v1/families/{self.family}/members/{self.member["id"]}/revoke')
        self.assertEqual(200, revoked['status'], revoked['body'])
        denied_catalog = self.fixture.catalog(subject=self.contributor)
        self.assertEqual(403, denied_catalog['status'], denied_catalog['body'])
        denied_moderation = self.moderate(False, subject=self.contributor)
        self.assertEqual(403, denied_moderation['status'], denied_moderation['body'])

    def test_current_admin_membership_is_checked_for_every_mutation(self):
        self.assertEqual(200, self.moderate(True)['status'])
        # Simulates an identity/admin recovery adapter revoking server state.
        # The application API separately protects its last active admin.
        with sqlite3.connect(self.fixture.database) as database:
            database.execute("UPDATE members SET status='revoked' WHERE id=?", (self.admin_member,))
        denied = self.moderate(False)
        self.assertEqual(403, denied['status'], denied['body'])
        denied_catalog = self.fixture.catalog()
        self.assertEqual(403, denied_catalog['status'], denied_catalog['body'])

    def test_owner_record_and_family_scope_cannot_be_swapped(self):
        unknown_record = self.moderate(True, path=self.path(record=archive_fixtures.uid()))
        self.assertIn(unknown_record['status'], (403, 404, 409), unknown_record['body'])
        wrong_owner = self.moderate(True, path=self.path(owner=self.admin_member))
        self.assertIn(wrong_owner['status'], (403, 404, 409), wrong_owner['body'])
        wrong_family = self.moderate(True, path=self.path(family=archive_fixtures.uid()))
        self.assertIn(wrong_family['status'], (403, 404, 409), wrong_family['body'])
        self.assertEqual([], self.catalog()['moderations'])


if __name__ == '__main__':
    unittest.main()
