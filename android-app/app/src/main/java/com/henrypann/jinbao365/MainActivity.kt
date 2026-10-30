package com.henrypann.jinbao365

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.henrypann.jinbao365.ui.JinbaoApp
import com.henrypann.jinbao365.ui.StartupArtworkEntry
import com.henrypann.jinbao365.startup.StartupArtworkLaunchGate
import com.henrypann.jinbao365.ui.theme.JinbaoTheme

class MainActivity : ComponentActivity() {
    override fun attachBaseContext(newBase: android.content.Context) {
        val configuration = android.content.res.Configuration(newBase.resources.configuration)
        configuration.setLocale(java.util.Locale.SIMPLIFIED_CHINESE)
        super.attachBaseContext(newBase.createConfigurationContext(configuration))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val artworkIndex = startupArtworkGate.claim(
            readNextIndex = { getSharedPreferences("startup_artwork", MODE_PRIVATE).getInt("next_index", 0) },
            saveNextIndex = { next ->
                // Persist this tiny cursor before a cold process can be killed; it contains no archive data.
                getSharedPreferences("startup_artwork", MODE_PRIVATE).edit().putInt("next_index", next).commit()
            },
        )
        if (artworkIndex != null) window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        setContent {
            JinbaoTheme {
                if (artworkIndex == null) JinbaoApp()
                else StartupArtworkEntry(artworkIndex, onProtectWindow = {
                    window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }) { JinbaoApp() }
            }
        }
    }
}

// Process memory deliberately survives Activity recreation and warm returns, but not a cold process.
private val startupArtworkGate = StartupArtworkLaunchGate()
