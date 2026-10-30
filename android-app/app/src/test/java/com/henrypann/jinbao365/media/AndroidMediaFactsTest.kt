package com.henrypann.jinbao365.media

import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.Instant
import java.util.Base64

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29])
class AndroidMediaFactsTest {
    @get:Rule val temp = TemporaryFolder()

    @Test
    fun android10ReadsOriginalCaptureOffsetFromExif() {
        // JPEG APP1 contains DateTimeOriginal=2024:06:01 12:00:00 and OffsetTimeOriginal=+08:00.
        val photo = temp.newFile("offset.jpg").apply {
            writeBytes(Base64.getDecoder().decode(
                "/9j/4QBbRXhpZgAASUkqAAgAAAABAGmHBAABAAAAGgAAAAAAAAACAAOQAgAUAAAAOAAAABGQAgAHAAAATAAAAAAAAAAyMDI0OjA2OjAxIDEyOjAwOjAwACswODowMAD/2Q==",
            ))
        }

        assertEquals(
            CaptureTime.offsetKnown(Instant.parse("2024-06-01T04:00:00Z").toEpochMilli(), "+08:00"),
            AndroidMediaFacts.capture(photo, "photo"),
        )
    }
}
