package com.henrypann.jinbao365.archive

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class DeviceIdentityTest {
    @Test
    fun identityStaysInTheDirectoryItIsGivenAndIsStableThere() {
        val directory = kotlin.io.path.createTempDirectory("ootd-no-backup").toFile()
        val first = DeviceIdentity(directory).getOrCreate()
        val second = DeviceIdentity(directory).getOrCreate()
        assertEquals(first, second)
        val file = File(directory, DeviceIdentity.FILE_NAME)
        assertTrue(file.isFile)
        assertEquals(first, file.readText())
        val elsewhere = kotlin.io.path.createTempDirectory("ootd-other-phone").toFile()
        assertFalse(File(elsewhere, DeviceIdentity.FILE_NAME).exists())
        assertNotEquals(first, DeviceIdentity(elsewhere).getOrCreate())
    }

    @Test
    fun backupRulesExcludeDeviceIdentityDatabaseAndPendingCapturesInEachSection() {
        val root = androidModuleRoot()
        val manifest = File(root, "src/main/AndroidManifest.xml").readText()
        val application = File(root, "src/main/java/com/henrypann/jinbao365/JinbaoApplication.kt").readText()
        val identity = File(root, "src/main/java/com/henrypann/jinbao365/archive/DeviceIdentity.kt").readText()
        assertTrue(manifest.contains("android:fullBackupContent=\"@xml/backup_rules\""))
        assertTrue(manifest.contains("android:dataExtractionRules=\"@xml/data_extraction_rules\""))
        assertTrue(manifest.contains("android:allowBackup=\"true\""))
        assertTrue(application.contains("DeviceIdentity.fromContext"))
        assertTrue(application.contains("reconcileOwner"))
        assertTrue(identity.contains("context.noBackupFilesDir"))

        val legacy = excludes(File(root, "src/main/res/xml/backup_rules.xml"), "full-backup-content")
        val cloud = excludes(File(root, "src/main/res/xml/data_extraction_rules.xml"), "cloud-backup")
        val transfer = excludes(File(root, "src/main/res/xml/data_extraction_rules.xml"), "device-transfer")
        assertEquals(ARCHIVE_BACKUP_EXCLUDES, legacy)
        assertEquals(ARCHIVE_BACKUP_EXCLUDES, cloud)
        assertEquals(ARCHIVE_BACKUP_EXCLUDES, transfer)
        assertEquals(cloud, transfer)
    }
}

private val ARCHIVE_BACKUP_EXCLUDES = setOf(
    "root" to "no_backup",
    "file" to "pending-media/",
    "database" to "archive-v3.db",
    "database" to "archive-v3.db-wal",
    "database" to "archive-v3.db-shm",
    "database" to "archive-v3.db-journal",
)

private fun excludes(file: File, section: String): Set<Pair<String, String>> {
    val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
    val nodes = document.getElementsByTagName(section)
    assertEquals(1, nodes.length)
    val parent = nodes.item(0) as Element
    val found = mutableSetOf<Pair<String, String>>()
    val children = parent.childNodes
    for (index in 0 until children.length) {
        val node = children.item(index)
        if (node is Element && node.tagName == "exclude") {
            found += node.getAttribute("domain") to node.getAttribute("path")
        }
    }
    return found
}

private fun androidModuleRoot(): File {
    var directory = File(checkNotNull(System.getProperty("user.dir")))
    repeat(6) {
        if (File(directory, "src/main/AndroidManifest.xml").isFile) return directory
        directory = directory.parentFile ?: return@repeat
    }
    error("Android module root not found from ${System.getProperty("user.dir")}")
}
