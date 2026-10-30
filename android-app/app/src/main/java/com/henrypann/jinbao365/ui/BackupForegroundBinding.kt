package com.henrypann.jinbao365.ui

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver

/** Synchronizes a lazily created application service with an already-started UI host. */
internal class BackupForegroundBinding(
    private val lifecycle: Lifecycle,
    private val setActive: (Boolean) -> Unit,
) : AutoCloseable {
    private val observer = LifecycleEventObserver { _, event ->
        when (event) {
            Lifecycle.Event.ON_START -> setActive(true)
            Lifecycle.Event.ON_STOP, Lifecycle.Event.ON_DESTROY -> setActive(false)
            else -> Unit
        }
    }
    init {
        setActive(lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
        lifecycle.addObserver(observer)
    }
    override fun close() {
        lifecycle.removeObserver(observer)
        setActive(false)
    }
}
