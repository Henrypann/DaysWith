package com.henrypann.jinbao365.backup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class V1IdsTest {
    private val uuid = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

    @Test fun bareRecordUuidUploadsVerbatim() {
        assertEquals(uuid.uppercase(), V1Ids.map("record", uuid))
    }

    @Test fun recPrefixedRecordUuidStripsPrefixAndUploadsTheSameUuid() {
        assertEquals(uuid.uppercase(), V1Ids.map("record", "rec-$uuid"))
        assertEquals(V1Ids.map("record", uuid), V1Ids.map("record", "rec-${uuid.uppercase()}"))
    }

    @Test fun recPrefixWithNonUuidStillUsesTheIsolatedLegacyPath() {
        // Single-image imports store rec-<sha12>; that is not a UUID after stripping.
        val legacy = "rec-0123456789ab"
        assertEquals(V1Ids.legacyIdToV1Uuid("record", legacy), V1Ids.map("record", legacy))
        assertNotEquals(legacy.removePrefix("rec-"), V1Ids.map("record", legacy))
    }

    @Test fun prefixIsOnlyStrippedForRecords() {
        val prefixed = "rec-$uuid"
        assertEquals(V1Ids.legacyIdToV1Uuid("asset", prefixed), V1Ids.map("asset", prefixed))
    }

    @Test fun malformedUuidAfterPrefixIsNotAccepted() {
        val bad = "rec-3f2504e0-4f89-41d3-9a0c-0305e82c330"
        assertEquals(V1Ids.legacyIdToV1Uuid("record", bad), V1Ids.map("record", bad))
    }
}
