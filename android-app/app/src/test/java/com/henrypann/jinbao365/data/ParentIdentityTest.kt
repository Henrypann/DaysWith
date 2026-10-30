package com.henrypann.jinbao365.data

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.nio.file.Files

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = android.app.Application::class)
class ParentIdentityTest {
    @Test fun confirmedIdentitySurvivesRestartAndCannotBeChanged() {
        val directory = Files.createTempDirectory("parent-identity").toFile()
        try {
            val store = ParentIdentityStore(directory)
            assertNull(store.parent)
            store.confirm(ParentIdentity.Mom)
            val reopened = ParentIdentityStore(directory)
            assertEquals(ParentIdentity.Mom, reopened.parent)
            reopened.confirm(ParentIdentity.Mom)
            assertThrows(IllegalStateException::class.java) { reopened.confirm(ParentIdentity.Dad) }
            assertEquals(ParentIdentity.Mom, ParentIdentityStore(directory).parent)
        } finally { directory.deleteRecursively() }
    }
    @Test fun corruptIdentityNeverReopensChoice() {
        val directory = Files.createTempDirectory("parent-identity").toFile()
        try {
            java.io.File(directory, "parent-identity-v1").writeText("invalid")
            assertThrows(IllegalStateException::class.java) { ParentIdentityStore(directory).confirm(ParentIdentity.Dad) }
        } finally { directory.deleteRecursively() }
    }
}
