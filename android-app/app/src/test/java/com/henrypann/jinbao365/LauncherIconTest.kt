package com.henrypann.jinbao365

import android.content.Context
import android.os.Build
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.BitmapDrawable
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29, 31, 35])
class LauncherIconTest {
    @Test fun manifestIconAndRoundResourceLoadAdaptiveBrandArtwork() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        assertEquals(R.mipmap.ic_launcher, context.applicationInfo.icon)
        for (resource in listOf(R.mipmap.ic_launcher, R.mipmap.ic_launcher_round)) {
            val icon = context.getDrawable(resource)
            assertTrue(icon is AdaptiveIconDrawable)
            icon as AdaptiveIconDrawable
            assertNotNull(icon.background)
            assertTrue(icon.foreground is InsetDrawable)
            val artwork = (icon.foreground as InsetDrawable).drawable
            assertTrue("Launcher must use the approved raster artwork", artwork is BitmapDrawable)
            assertEquals(1254, (artwork as BitmapDrawable).bitmap.width)
            assertEquals(1254, artwork.bitmap.height)
            if (Build.VERSION.SDK_INT >= 33) {
                // The approved source is opaque full-color artwork. Do not silently keep the old
                // ingot as a themed logo or use its opaque square alpha as a monochrome mask.
                assertNull("No approved monochrome rendition has been supplied", icon.monochrome)
            }
        }
    }
}
