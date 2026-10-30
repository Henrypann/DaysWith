package com.henrypann.jinbao365.ui

import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.delay
import java.time.Duration
import java.time.LocalDate
import java.time.ZonedDateTime

/** No notification or background job: refresh the visible date on resume and local midnight. */
@Composable
internal fun rememberLocalToday(): LocalDate {
    var today by remember { mutableStateOf(LocalDate.now()) }
    val context = LocalContext.current
    DisposableEffect(context) {
        val lifecycle = (context as? LifecycleOwner)?.lifecycle
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) today = LocalDate.now()
        }
        lifecycle?.addObserver(observer)
        onDispose { lifecycle?.removeObserver(observer) }
    }
    LaunchedEffect(Unit) {
        while (true) {
            val now = ZonedDateTime.now()
            today = now.toLocalDate()
            val midnight = today.plusDays(1).atStartOfDay(now.zone)
            // Recheck the timezone/clock while open as well as refreshing exactly at midnight.
            delay(Duration.between(now, midnight).toMillis().coerceIn(1, 60_000))
        }
    }
    return today
}
