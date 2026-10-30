package com.henrypann.jinbao365.backup

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.data.*
import com.henrypann.jinbao365.storage.StorageConfiguration
import com.henrypann.jinbao365.storage.StorageCredentials
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.LocalDate

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AnniversaryRestoreTest {
    @get:Rule val temporary = TemporaryFolder()
    @Test fun sharingDeletionOfflineCacheAndTakeoverPreserveAnniversaries() {
        val root = StorageConfiguration(bucket = "example-1234567890")
        val config = root.copy(prefix = ParentIdentity.Mom.prefix)
        val remote = MemoryCosStore(config)
        val credentials = StorageCredentials("fixtureID", "fixtureKey")
        val originalDevice = "00000000-0000-4000-8000-000000000001"
        val newDevice = "00000000-0000-4000-8000-000000000002"
        val states = MemoryBackupState().apply { value = BackupState(bucket = config.bucket, prefix = config.prefix, paused = false) }
        val sourceMedia = temporary.newFolder()
        val anniversary = Anniversary("00000000-0000-4000-8000-000000000099", ParentIdentity.Mom,
            "示例生日", LocalDate.of(2000, 2, 3))
        fun publish(values: List<Anniversary>, now: Long) = BackupEngine(states,
            { BackupConditions(config, true, false, false) }, objectStore = { _, _, _ -> remote }, parent = ParentIdentity.Mom)
            .runOnce(ArchiveSnapshot.empty(), sourceMedia, config, credentials, originalDevice, now, values)
        publish(listOf(anniversary), 100)
        val db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), ArchiveDatabase::class.java)
            .allowMainThreadQueries().build()
        try {
            val repository = ArchiveRepository(db)
            val reader = ParentArchiveReader(temporary.newFolder(), repository::cacheOtherAnniversaries) { _, _, _ -> remote }
            reader.read(root, credentials, ParentIdentity.Dad)
            assertEquals(listOf(anniversary), repository.loadAnniversaries())
            val originalSource = AnniversarySource(root.bucket, root.region)
            val changedRoot = root.copy(bucket = "other-family-1234567890")
            assertTrue(reader.loadCached(ParentIdentity.Dad, changedRoot).records.isEmpty())
            assertThrows(CosException::class.java) { reader.read(changedRoot, credentials, ParentIdentity.Dad) }
            assertTrue(ArchiveRepository(db).loadVisibleAnniversaries(ParentIdentity.Dad,
                AnniversarySource(changedRoot.bucket, changedRoot.region)).isEmpty())
            assertEquals(listOf(anniversary), ArchiveRepository(db).loadVisibleAnniversaries(ParentIdentity.Dad, originalSource))
            assertThrows(IllegalArgumentException::class.java) { repository.deleteAnniversary(ParentIdentity.Dad, anniversary.id, 101) }
            val deleted = anniversary.copy(deletedAt = 102)
            publish(listOf(deleted), 102)
            reader.read(root, credentials, ParentIdentity.Dad)
            assertEquals(listOf(deleted), repository.loadAnniversaries())
            remote.data[config.prefix + V1Json.commitRelativeKey(3)] = "invalid".toByteArray()
            assertThrows(Exception::class.java) { reader.read(root, credentials, ParentIdentity.Dad) }
            assertEquals(listOf(deleted), repository.loadAnniversaries())
            reader.loadCached(ParentIdentity.Dad, root)
            assertEquals(listOf(deleted), repository.loadAnniversaries())
            remote.data.remove(config.prefix + V1Json.commitRelativeKey(3)) // Test double only; never a cloud delete.
            repository.cacheOtherAnniversaries(ParentIdentity.Dad, emptyList())
            assertTrue(repository.loadAnniversaries().isEmpty())
            val beforeWrites = remote.writes.toList()
            FolderTakeover(repository, MemoryBackupState(), temporary.newFolder()) { _, _, _ -> remote }
                .restore(root, ParentIdentity.Mom, credentials, newDevice, 103)
            assertEquals(listOf(deleted), repository.loadAnniversaries())
            assertEquals(beforeWrites, remote.writes) // Restore stages a local registration, then regular backup publishes.
        } finally { db.close() }
    }
}
