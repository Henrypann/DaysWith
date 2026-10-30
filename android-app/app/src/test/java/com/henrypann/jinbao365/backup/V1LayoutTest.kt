package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.data.ParentIdentity
import org.junit.Assert.*
import org.junit.Test

class V1LayoutTest {
    private val a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    @Test fun deviceChainsShareTheParentObjectsFolder() {
        val chain = V1Layout.chainPrefix(ParentIdentity.Dad, a, false)
        assertEquals("life/v1/dad/", V1Layout.objectRoot(chain))
        assertEquals("life/v1/dad/objects/ab/" + "ab".repeat(32), V1Layout.objectKey(chain, "ab".repeat(32)))
        // Legacy root keeps its exact old object keys.
        assertEquals("life/v1/dad/objects/ab/" + "ab".repeat(32), V1Layout.objectKey("life/v1/dad/", "ab".repeat(32)))
        assertEquals("life/v1/test/", V1Layout.objectRoot(V1Layout.chainPrefix(ParentIdentity.Mom, a, true)))
    }

    @Test fun galleryDebugUploadsNeverResolveToFamilyRoots() {
        for (parent in ParentIdentity.entries) {
            val chain = V1Layout.chainPrefix(parent, a, true)
            assertEquals("life/v1/test/$a/", chain)
            val keys = listOf(chain + "commits/00000000000000000001.json",
                chain + "snapshots/gallery.json", V1Layout.objectKey(chain, "ab".repeat(32)))
            keys.forEach { key ->
                assertTrue(key.startsWith("life/v1/test/"))
                assertFalse(key.startsWith("life/v1/dad/") || key.startsWith("life/v1/mom/"))
            }
        }
    }

    @Test fun findsLegacyAndDeviceChainsButIgnoresObjects() {
        val keys = listOf(
            "life/v1/dad/commits/00000000000000000001.json",
            "life/v1/dad/snapshots/x.json",
            "life/v1/dad/objects/ab/abc",
            "life/v1/dad/$a/commits/00000000000000000001.json",
            "life/v1/dad/$a/commits/00000000000000000002.json",
            "life/v1/dad/$b/snapshots/only.json", // no commits yet: not a chain
            "life/v1/mom/commits/00000000000000000001.json",
        )
        assertEquals(listOf("life/v1/dad/", "life/v1/dad/$a/"), V1Layout.chainsUnder("life/v1/dad/", keys))
    }

    @Test fun anniversaryOwnershipCoversLegacyDeviceAndTestChains() {
        assertTrue(V1Layout.owns(ParentIdentity.Dad, "life/v1/dad/"))
        assertTrue(V1Layout.owns(ParentIdentity.Dad, "life/v1/dad/$a/"))
        assertTrue(V1Layout.owns(ParentIdentity.Dad, "life/v1/test/$a/"))
        assertFalse(V1Layout.owns(ParentIdentity.Dad, "life/v1/mom/$a/"))
        assertFalse(V1Layout.owns(ParentIdentity.Dad, "life/v1/mom/"))
    }
}
