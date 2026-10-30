package com.henrypann.jinbao365.startup

import org.junit.Assert.*
import org.junit.Test

class StartupArtworkPolicyTest {
    @Test fun coldProcessesAlternateAndActivityRecreationDoesNotClaimAgain() {
        var next = 0
        var writes = 0
        val firstProcess = StartupArtworkLaunchGate()
        assertEquals(0, firstProcess.claim({ next }, { next = it; writes++ }))
        assertNull(firstProcess.claim({ error("Recreation must not read the cursor") }, { error("No second write") }))
        val secondProcess = StartupArtworkLaunchGate()
        assertEquals(1, secondProcess.claim({ next }, { next = it; writes++ }))
        assertNull(secondProcess.claim({ next }, { next = it; writes++ }))
        assertEquals(0, StartupArtworkLaunchGate().claim({ next }, { next = it; writes++ }))
        assertEquals(3, writes)
        assertEquals(1, next)
    }

    @Test fun invalidStoredIndexResetsToFirstArtworkAndWritesOnlyZeroOrOne() {
        var next = -9
        assertEquals(0, StartupArtworkLaunchGate().claim({ next }, { next = it }))
        assertEquals(1, next)
    }

    @Test fun countdownRequiresNineHundredMillisecondsOfResumedFrames() {
        val countdown = StartupArtworkCountdown()
        assertFalse(countdown.advance(400_000_000L, resumed = true))
        assertFalse(countdown.advance(30_000_000_000L, resumed = false))
        assertEquals(500_000_000L, countdown.remainingNanos)
        assertFalse(countdown.advance(499_999_999L, resumed = true))
        assertTrue(countdown.advance(1L, resumed = true))
        assertEquals(0L, countdown.remainingNanos)
    }

    @Test fun negativeFrameDeltaNeverIncreasesTheCountdown() {
        val countdown = StartupArtworkCountdown()
        assertFalse(countdown.advance(-100L, resumed = true))
        assertEquals(900_000_000L, countdown.remainingNanos)
    }

    @Test fun handoffProtectsBeforeEnteringAndRunsOnlyOnce() {
        val events = mutableListOf<String>()
        val handoff = StartupArtworkHandoff({ events += "secure" }, { events += "app" })
        handoff.complete()
        handoff.complete()
        assertEquals(listOf("secure", "app"), events)
    }

    @Test fun failedProtectionNeverEntersTheApp() {
        var entered = false
        val handoff = StartupArtworkHandoff({ error("Window protection failed") }, { entered = true })
        assertThrows(IllegalStateException::class.java) { handoff.complete() }
        assertFalse(entered)
    }
}
