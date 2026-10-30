package com.henrypann.jinbao365.data

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.LocalDate

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AnniversaryRepositoryTest {
    @Test fun persistedCacheIsVisibleOnlyForItsOriginalBucketAndRegion() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val name = "anniversary-source-${java.util.UUID.randomUUID()}.db"
        var db = Room.databaseBuilder(context, ArchiveDatabase::class.java, name).allowMainThreadQueries().build()
        try {
            val repository = ArchiveRepository(db)
            val dad = repository.saveAnniversary(ParentIdentity.Dad, null, "示例生日", LocalDate.of(1990, 1, 1))
            val mom = dad.copy(owner = ParentIdentity.Mom, title = "示例生日")
            val source = AnniversarySource("family-a-1234567890", "ap-shanghai")
            repository.cacheOtherAnniversaries(ParentIdentity.Dad, listOf(mom), source)
            // Close and reopen the on-disk database to model process restart.
            db.close()
            db = Room.databaseBuilder(context, ArchiveDatabase::class.java, name).allowMainThreadQueries().build()
            val reopened = ArchiveRepository(db)
            assertEquals(setOf(dad, mom), reopened.loadVisibleAnniversaries(ParentIdentity.Dad, source).toSet())
            for (other in listOf(null, source.copy(bucket = "family-b-1234567890"), source.copy(region = "ap-beijing"))) {
                assertEquals(listOf(dad), reopened.loadVisibleAnniversaries(ParentIdentity.Dad, other))
            }
            // A failed fetch does not replace rows: switching back retains the verified offline cache.
            assertEquals(setOf(dad, mom), reopened.loadVisibleAnniversaries(ParentIdentity.Dad, source).toSet())
        } finally { db.close(); context.deleteDatabase(name) }
    }

    @Test fun boundPhoneIdentityCannotBeSpoofedByRepositoryCallers() {
        val db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), ArchiveDatabase::class.java)
            .allowMainThreadQueries().build()
        try {
            val repository = ArchiveRepository(db, deviceMetadata = { "制造商" to "型号" }, parentIdentity = { ParentIdentity.Mom })
            assertThrows(IllegalArgumentException::class.java) {
                repository.saveAnniversary(ParentIdentity.Dad, null, "生日", LocalDate.of(2020, 1, 1))
            }
            val draft = repository.createDraft("device", 100)
            assertEquals("mom", (draft.record.extensions.getValue("parent").value as kotlinx.serialization.json.JsonPrimitive).content)
            assertEquals("型号", (draft.record.extensions.getValue("deviceModel").value as kotlinx.serialization.json.JsonPrimitive).content)
            val foreign = draft.record.copy(extensions = draft.record.extensions +
                ("parent" to draft.record.extensions.getValue("parent").copy(value = kotlinx.serialization.json.JsonPrimitive("dad"))))
            assertThrows(IllegalArgumentException::class.java) { repository.saveManualRecord(foreign) }
            assertTrue(repository.loadAnniversaries().isEmpty())
        } finally { db.close() }
    }

    @Test fun creatorOwnsEditsAndDeletionAndTombstonesPersist() {
        val db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), ArchiveDatabase::class.java)
            .allowMainThreadQueries().build()
        try {
            val repository = ArchiveRepository(db)
            assertTrue(repository.loadAnniversaries().isEmpty())
            val dad = repository.saveAnniversary(ParentIdentity.Dad, null, "生日", LocalDate.of(2020, 2, 29))
            assertThrows(IllegalArgumentException::class.java) {
                repository.saveAnniversary(ParentIdentity.Mom, dad.id, "越权", dad.date)
            }
            assertThrows(IllegalArgumentException::class.java) { repository.deleteAnniversary(ParentIdentity.Mom, dad.id, 123) }
            val changed = repository.saveAnniversary(ParentIdentity.Dad, dad.id, "示例生日", dad.date)
            assertEquals(dad.id, changed.id)
            repository.deleteAnniversary(ParentIdentity.Dad, dad.id, 123)
            assertEquals(123L, ArchiveRepository(db).loadAnniversaries().single().deletedAt)
            assertThrows(IllegalArgumentException::class.java) {
                repository.saveAnniversary(ParentIdentity.Dad, dad.id, "复活", dad.date)
            }
        } finally { db.close() }
    }

    @Test fun sharedCacheCannotOverwriteLocalOwnerAndDeletionIsImported() {
        val db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), ArchiveDatabase::class.java)
            .allowMainThreadQueries().build()
        try {
            val repository = ArchiveRepository(db)
            val dad = repository.saveAnniversary(ParentIdentity.Dad, null, "示例生日", LocalDate.of(1990, 1, 1))
            val mom = dad.copy(owner = ParentIdentity.Mom, title = "示例生日") // Deliberate cross-parent UUID collision.
            repository.cacheOtherAnniversaries(ParentIdentity.Dad, listOf(mom))
            assertEquals(2, repository.loadAnniversaries().size)
            repository.cacheOtherAnniversaries(ParentIdentity.Dad, listOf(mom.copy(deletedAt = 123)))
            assertEquals(dad, repository.loadAnniversaries().single { it.owner == ParentIdentity.Dad })
            assertEquals(123L, repository.loadAnniversaries().single { it.owner == ParentIdentity.Mom }.deletedAt)
            assertThrows(IllegalArgumentException::class.java) { repository.cacheOtherAnniversaries(ParentIdentity.Dad, listOf(dad)) }
            assertEquals(2, repository.loadAnniversaries().size)
        } finally { db.close() }
    }

    @Test fun invalidTitlesAndDatesDoNotWriteRows() {
        val db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), ArchiveDatabase::class.java)
            .allowMainThreadQueries().build()
        try {
            val repository = ArchiveRepository(db)
            for (title in listOf(" ", "字".repeat(101))) assertThrows(IllegalArgumentException::class.java) {
                repository.saveAnniversary(ParentIdentity.Mom, null, title, LocalDate.of(2020, 1, 1))
            }
            assertThrows(IllegalArgumentException::class.java) {
                repository.saveAnniversary(ParentIdentity.Mom, null, "生日", LocalDate.of(0, 1, 1))
            }
            assertTrue(repository.loadAnniversaries().isEmpty())
        } finally { db.close() }
    }

    @Test fun untouchedDefaultsAreNeverStoredAndEditsOrDeletesStoreOneRowUnderTheFixedId() {
        val db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), ArchiveDatabase::class.java)
            .allowMainThreadQueries().build()
        try {
            val repository = ArchiveRepository(db)
            assertTrue(repository.loadAnniversaries().isEmpty())
            val id = DefaultAnniversaries.CHILDRENS_DAY_ID
            repository.saveAnniversary(ParentIdentity.Dad, id, "示例纪念日", LocalDate.of(2021, 5, 20))
            repository.saveAnniversary(ParentIdentity.Dad, id, "示例纪念日", LocalDate.of(2022, 5, 20))
            assertEquals(listOf(LocalDate.of(2022, 5, 20)), repository.loadAnniversaries().map { it.date })
            repository.deleteAnniversary(ParentIdentity.Dad, DefaultAnniversaries.NATIONAL_DAY_ID, 5)
            val rows = repository.loadAnniversaries()
            assertEquals(2, rows.size)
            assertEquals(5L, rows.single { it.id == DefaultAnniversaries.NATIONAL_DAY_ID }.deletedAt)
            val visible = DefaultAnniversaries.merge(rows, ParentIdentity.Dad).filter { it.deletedAt == null }
            assertEquals(2, visible.size)
            assertThrows(IllegalArgumentException::class.java) {
                repository.saveAnniversary(ParentIdentity.Dad, "not-a-default", "x", LocalDate.of(2020, 1, 1))
            }
        } finally { db.close() }
    }

    @Test fun editingARemoteDefaultWritesOnlyTheBoundParentsOverrideAndDeletionKeepsTheRemoteRow() {
        val db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), ArchiveDatabase::class.java)
            .allowMainThreadQueries().build()
        try {
            val repository = ArchiveRepository(db, parentIdentity = { ParentIdentity.Dad })
            val remote = Anniversary(DefaultAnniversaries.NEW_YEAR_ID, ParentIdentity.Mom,
                "示例生日", LocalDate.of(2000, 2, 3))
            repository.cacheOtherAnniversaries(ParentIdentity.Dad, listOf(remote))
            assertEquals(remote, DefaultAnniversaries.merge(repository.loadAnniversaries(), ParentIdentity.Dad)
                .single { it.id == remote.id })
            val local = repository.saveAnniversary(ParentIdentity.Dad, remote.id, remote.title,
                LocalDate.of(2001, 2, 3))
            assertEquals(ParentIdentity.Dad, local.owner)
            assertEquals(local, DefaultAnniversaries.merge(repository.loadAnniversaries(), ParentIdentity.Dad)
                .single { it.id == remote.id })
            repository.deleteAnniversary(ParentIdentity.Dad, remote.id, 123)
            assertEquals(remote, repository.loadAnniversaries().single { it.owner == ParentIdentity.Mom })
            assertEquals(123L, repository.loadAnniversaries().single { it.owner == ParentIdentity.Dad }.deletedAt)
            assertFalse(DefaultAnniversaries.merge(repository.loadAnniversaries(), ParentIdentity.Dad)
                .any { it.id == remote.id && it.deletedAt == null })
        } finally { db.close() }
    }
}
