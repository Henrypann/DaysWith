package com.henrypann.jinbao365.media

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** One import thread for the process. A Timeline visit must not start another. */
object ImportScheduler {
    val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "ootd-import").apply { isDaemon = true }
    }
}
