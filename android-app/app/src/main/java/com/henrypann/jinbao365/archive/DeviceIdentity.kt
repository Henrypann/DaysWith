package com.henrypann.jinbao365.archive

import android.content.Context
import java.io.File
import java.util.UUID

/**
 * Writer device id for archive protocol v3.
 *
 * Call [fromContext] so the file is created in `Context.getNoBackupFilesDir()`.
 * Auto Backup skips that `no_backup` directory. `res/xml/backup_rules.xml` and
 * `res/xml/data_extraction_rules.xml` exclude it again for cloud backup and for
 * device-to-device transfer. A reinstall or a new phone therefore creates a new id.
 *
 * Two devices that kept the same id could write different values under one equal
 * `(counter, at, deviceID)` key. Merge fails closed in that case.
 */
class DeviceIdentity(private val directory: File) {
    fun getOrCreate(): String {
        val file = File(directory, FILE_NAME)
        if (file.isFile) {
            val existing = file.readText().trim()
            if (existing.isNotEmpty()) return existing
        }
        directory.mkdirs()
        val created = UUID.randomUUID().toString()
        file.writeText(created)
        return created
    }

    companion object {
        const val FILE_NAME = "writer-device-id"

        fun fromContext(context: Context): DeviceIdentity = DeviceIdentity(context.noBackupFilesDir)
    }
}
