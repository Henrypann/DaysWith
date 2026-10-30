package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.storage.SavedConnection
import com.henrypann.jinbao365.storage.StorageConfiguration
import org.junit.Assert.*
import org.junit.Test

class V1DestinationTest {
    @Test fun eachParentGetsAnIndependentFixedV1Folder() {
        val root = StorageConfiguration(bucket = "example-1234567890")
        assertEquals("life/v1/dad/", V1Destination.forParent(root, ParentIdentity.Dad).prefix)
        assertEquals("life/v1/mom/", V1Destination.forParent(root, ParentIdentity.Mom).prefix)
        assertEquals("life/v1/dad/", V1Destination.forParent(root.copy(prefix = "old/android/"), ParentIdentity.Dad).prefix)
    }

    private val dev = "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9"
    private val other = "11111111-2222-4333-8444-555555555555"

    @Test fun noIdentityCanNeverBecomeAWritableConnection() {
        assertSame(SavedConnection.Missing, V1Destination.mapConnection(SavedConnection.Verified(StorageConfiguration(bucket = "example-1234567890")), null, dev, false))
    }

    @Test fun eachDeviceWritesItsOwnChainUnderItsParent() {
        val root = StorageConfiguration(bucket = "example-1234567890")
        val mapped = V1Destination.mapConnection(SavedConnection.Verified(root), ParentIdentity.Mom, dev, false) as SavedConnection.Verified
        assertEquals("life/v1/mom/0f1e2d3c-4b5a-4978-8695-a4b3c2d1e0f9/", mapped.configuration.prefix)
        assertEquals(root, V1Destination.rootOf(mapped.configuration, root, ParentIdentity.Mom, dev, false))
        assertNull(V1Destination.rootOf(mapped.configuration, root, ParentIdentity.Dad, dev, false))
        assertNull(V1Destination.rootOf(mapped.configuration, root, ParentIdentity.Mom, other, false))
        assertNull(V1Destination.rootOf(mapped.configuration, root, null, dev, false))
        assertSame(SavedConnection.Missing, V1Destination.mapConnection(SavedConnection.Missing, ParentIdentity.Dad, dev, false))
        assertNotEquals(V1Destination.forWriter(root, ParentIdentity.Dad, dev, false).prefix,
            V1Destination.forWriter(root, ParentIdentity.Dad, other, false).prefix)
    }

    @Test fun testBuildsNeverTouchDadOrMom() {
        val root = StorageConfiguration(bucket = "example-1234567890")
        for (parent in ParentIdentity.entries) {
            val prefix = V1Destination.forWriter(root, parent, dev, true).prefix
            assertEquals("life/v1/test/0f1e2d3c-4b5a-4978-8695-a4b3c2d1e0f9/", prefix)
            assertFalse(prefix.startsWith("life/v1/dad/") || prefix.startsWith("life/v1/mom/"))
        }
    }
}
