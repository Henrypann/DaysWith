package com.henrypann.jinbao365.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Path
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.ColorDrawable
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.henrypann.jinbao365.R
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin

/** Offline Android-framework render evidence. Circle/squircle previews add clipping to the device mask;
 * they do not change launcher configuration or claim acceptance for another launcher's own mask. */
@RunWith(AndroidJUnit4::class)
class BrandIconRenderingTest {
    @Test fun captureFrameworkAdaptiveIconAndThemedMonochrome() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val icon = context.getDrawable(R.mipmap.ic_launcher)
        assertTrue("Manifest icon must load as an adaptive icon", icon is AdaptiveIconDrawable)
        icon as AdaptiveIconDrawable
        assertNotNull(icon.foreground)
        assertNotNull(icon.background)
        render(context, icon, "30-launcher-adaptive-native")
        render(context, icon, "31-launcher-adaptive-circle", circle())
        render(context, icon, "32-launcher-adaptive-squircle", squircle())
        val round = context.getDrawable(R.mipmap.ic_launcher_round)
        assertTrue("Round resource must retain adaptive foreground and background", round is AdaptiveIconDrawable)
        render(context, round as AdaptiveIconDrawable, "34-launcher-round-native")
        if (Build.VERSION.SDK_INT >= 33) {
            val monochrome = requireNotNull(icon.monochrome) { "Android 13+ icon must provide a monochrome layer" }
                .constantState!!.newDrawable(context.resources).mutate().apply { setTint(Color.rgb(15, 39, 71)) }
            render(context, AdaptiveIconDrawable(ColorDrawable(Color.rgb(253, 246, 233)), monochrome),
                "33-launcher-monochrome")
        }
    }

    private fun render(context: Context, icon: AdaptiveIconDrawable, name: String, mask: Path? = null) {
        val bitmap = Bitmap.createBitmap(SIZE, SIZE, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            if (mask != null) canvas.clipPath(mask)
            icon.setBounds(0, 0, SIZE, SIZE)
            icon.draw(canvas)
            assertTrue("$name must keep the center of the artwork visible", Color.alpha(bitmap.getPixel(SIZE / 2, SIZE / 2)) > 200)
            assertEquals("$name must have transparent outside corners", 0, Color.alpha(bitmap.getPixel(0, 0)))
            val visibleColors = (2..8).flatMap { x -> (2..8).map { y -> bitmap.getPixel(SIZE * x / 10, SIZE * y / 10) } }.toSet()
            assertTrue("$name must include both background and foreground", visibleColors.size > 1)
            val target = File(context.getExternalFilesDir(null), "brand-v1.0/$name.png")
            check(target.parentFile!!.mkdirs() || target.parentFile!!.isDirectory)
            target.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        } finally { bitmap.recycle() }
    }

    private fun circle() = Path().apply { addCircle(SIZE / 2f, SIZE / 2f, SIZE / 2f, Path.Direction.CW) }

    private fun squircle() = Path().apply {
        // Superellipse n=4 offers a reproducible rounded-square review mask.
        for (step in 0..360) {
            val angle = Math.PI * 2 * step / 360
            fun component(value: Double) = if (value < 0) -abs(value).pow(.5) else abs(value).pow(.5)
            val x = (SIZE / 2.0 + SIZE / 2.0 * component(cos(angle))).toFloat()
            val y = (SIZE / 2.0 + SIZE / 2.0 * component(sin(angle))).toFloat()
            if (step == 0) moveTo(x, y) else lineTo(x, y)
        }
        close()
    }

    companion object { private const val SIZE = 1024 }
}
