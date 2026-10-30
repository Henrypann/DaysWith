package com.henrypann.jinbao365.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(
    entities = [
        RecordEntity::class,
        AssetEntity::class,
        ResourceEntity::class,
        SnapshotMetaEntity::class,
        SyncStateEntity::class,
        DraftEntity::class,
        DraftCommitEntity::class,
        AnniversaryEntity::class,
        PendingMediaTaskEntity::class,
        PendingMediaItemEntity::class,
    ],
    version = 7,
    exportSchema = true,
)
abstract class ArchiveDatabase : RoomDatabase() {
    abstract fun archiveDao(): ArchiveDao

    companion object {
        const val NAME = "archive-v3.db"

        fun open(context: Context, name: String = NAME): ArchiveDatabase =
            Room.databaseBuilder(context, ArchiveDatabase::class.java, name)
                .setJournalMode(JournalMode.TRUNCATE)
                .addMigrations(MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4, MIGRATION_4_5, MIGRATION_5_6, MIGRATION_6_7)
                .addCallback(object : Callback() {
                    override fun onOpen(db: SupportSQLiteDatabase) {
                        // One connection makes these settings apply to the writer. FULL
                        // commits sync the database before a completed import is reported.
                        db.query("PRAGMA journal_mode = TRUNCATE").use { cursor ->
                            check(cursor.moveToFirst() && cursor.getString(0).equals("truncate", ignoreCase = true)) {
                                "The archive database could not enable durable journaling."
                            }
                        }
                        db.execSQL("PRAGMA synchronous = FULL")
                    }
                })
                .build()

        val MIGRATION_6_7 = object : Migration(6, 7) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE IF NOT EXISTS `pending_media_items` (`id` TEXT NOT NULL, `taskId` TEXT NOT NULL, `position` INTEGER NOT NULL, `uri` TEXT NOT NULL, `origin` TEXT NOT NULL, `status` TEXT NOT NULL, `assetId` TEXT, `ownsPosition` INTEGER NOT NULL, `provenance` TEXT, `errorMessage` TEXT, PRIMARY KEY(`id`))")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_pending_media_items_taskId` ON `pending_media_items` (`taskId`)")
                // Version 6 URI arrays are expanded lazily in a transaction, before work resumes.
            }
        }

        val MIGRATION_5_6 = object : Migration(5, 6) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `drafts` ADD COLUMN `originalRecordJson` TEXT")
                db.execSQL("CREATE TABLE IF NOT EXISTS `pending_media_tasks` (`id` TEXT NOT NULL, `draftId` TEXT NOT NULL, `origin` TEXT NOT NULL, `status` TEXT NOT NULL, `payloadJson` TEXT NOT NULL, `completedItems` INTEGER NOT NULL, `totalItems` INTEGER NOT NULL, `errorMessage` TEXT, `ownsDraft` INTEGER NOT NULL, PRIMARY KEY(`id`))")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_pending_media_tasks_draftId` ON `pending_media_tasks` (`draftId`)")
            }
        }

        val MIGRATION_4_5 = object : Migration(4, 5) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE IF NOT EXISTS `anniversaries` (`id` TEXT NOT NULL, `owner` TEXT NOT NULL, `title` TEXT NOT NULL, `date` TEXT NOT NULL, `deletedAt` INTEGER, `sourceBucket` TEXT, `sourceRegion` TEXT, PRIMARY KEY(`owner`, `id`))")
            }
        }

        /** Preserve records and drafts while removing the retired feature's storage. */
        val MIGRATION_3_4 = object : Migration(3, 4) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE `records_v4` (`id` TEXT NOT NULL, `titleJson` TEXT NOT NULL, `noteJson` TEXT NOT NULL, `occurredAtJson` TEXT NOT NULL, `createdAtJson` TEXT NOT NULL, `assetIdsJson` TEXT NOT NULL, `tombstoneJson` TEXT NOT NULL, `extensionsJson` TEXT NOT NULL, `unknownFieldsJson` TEXT NOT NULL, `mediaOverflow` INTEGER, PRIMARY KEY(`id`))")
                db.execSQL("INSERT INTO `records_v4` (`id`, `titleJson`, `noteJson`, `occurredAtJson`, `createdAtJson`, `assetIdsJson`, `tombstoneJson`, `extensionsJson`, `unknownFieldsJson`, `mediaOverflow`) SELECT `id`, `titleJson`, `noteJson`, `occurredAtJson`, `createdAtJson`, `assetIdsJson`, `tombstoneJson`, `extensionsJson`, `unknownFieldsJson`, `mediaOverflow` FROM `records`")
                db.execSQL("DROP TABLE `records`")
                db.execSQL("ALTER TABLE `records_v4` RENAME TO `records`")
                db.execSQL("DROP TABLE IF EXISTS `items`")
            }
        }

        val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE IF NOT EXISTS `draft_commits` (`id` TEXT NOT NULL, `recordId` TEXT NOT NULL, PRIMARY KEY(`id`))")
                db.execSQL("CREATE TABLE IF NOT EXISTS `drafts` (`id` TEXT NOT NULL, `payloadJson` TEXT NOT NULL, `revision` INTEGER NOT NULL, PRIMARY KEY(`id`))")
            }
        }

        val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `sync_state` (" +
                        "`id` INTEGER NOT NULL, " +
                        "`ownerDeviceId` TEXT, " +
                        "`verifiedThroughSequence` INTEGER, " +
                        "`verifiedThroughHash` TEXT, " +
                        "`resyncFromStart` INTEGER NOT NULL, " +
                        "PRIMARY KEY(`id`))",
                )
            }
        }
    }
}
