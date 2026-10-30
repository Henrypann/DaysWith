package com.henrypann.jinbao365.startup

/** One claim per process; a new gate represents a new cold process. */
internal class StartupArtworkLaunchGate {
    private var claimed = false

    @Synchronized
    fun claim(readNextIndex: () -> Int, saveNextIndex: (Int) -> Unit): Int? {
        if (claimed) return null
        claimed = true
        val index = if (readNextIndex() == 1) 1 else 0
        saveNextIndex(1 - index)
        return index
    }
}

/** Only visible, resumed frames contribute to the packaged artwork's display time. */
internal class StartupArtworkCountdown {
    var remainingNanos: Long = 900_000_000L
        private set
    val finished get() = remainingNanos == 0L

    fun advance(elapsedNanos: Long, resumed: Boolean): Boolean {
        if (resumed) remainingNanos = (remainingNanos - elapsedNanos.coerceAtLeast(0L)).coerceAtLeast(0L)
        return finished
    }
}

/** Protect the window synchronously before any app content can be composed. */
internal class StartupArtworkHandoff(
    private val protectWindow: () -> Unit,
    private val enterApp: () -> Unit,
) {
    private var completed = false

    fun complete() {
        if (completed) return
        protectWindow()
        completed = true
        enterApp()
    }
}
