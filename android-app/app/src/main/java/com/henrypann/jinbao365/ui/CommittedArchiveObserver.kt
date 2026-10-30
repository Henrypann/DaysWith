package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.archive.ArchiveSnapshot

/** Called on the serial import worker after successful reads, never from a draft mutation. */
internal class CommittedArchiveObserver(private val onChanged: () -> Unit) {
    private var previous: ArchiveSnapshot? = null

    fun accept(snapshot: ArchiveSnapshot) {
        val changed = previous != null && previous != snapshot
        previous = snapshot
        if (changed) onChanged()
    }
}
