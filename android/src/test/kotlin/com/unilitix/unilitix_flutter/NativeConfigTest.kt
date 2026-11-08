package com.unilitix.unilitix_flutter

import io.unilitix.sdk.UnilitixConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Dart options (contract keys) land on the Android SDK's builder. */
class NativeConfigTest {

    private fun build(options: Map<String, Any?>): UnilitixConfig {
        val b = UnilitixConfig.Builder()
        NativeConfig.apply(b, options)
        return b.build()
    }

    @Test
    fun mapsEveryContractOption() {
        val c = build(
            mapOf(
                "apiUrl" to "https://ingest.example",
                "debug" to true,
                "autoTrackCrashes" to false,
                "flushIntervalSeconds" to 60,
                "flushBatchSize" to 50,
                "maxOfflineEvents" to 500,
                "sessionTimeoutSeconds" to 120,
                "maskInputs" to false,
                "maskAllText" to false,
                "maskImages" to true,
                "maskInputsInScreenshots" to false,
                "replaySampleRate" to 0.25,
                "captureSnapshots" to false,
                "snapshotIntervalMs" to 2000,
                "maxSnapshotsPerSession" to 10,
                "captureScreenshots" to false,
                "screenshotIntervalMs" to 1500,
                "screenshotQuality" to 40,
                "screenshotMaxWidth" to 360,
                "uploadScreenshotsOnWifiOnly" to false,
                "maxScreenshotsPerSession" to 11,
                "maxScreenshotsPerMinute" to 12,
                // Dart ints arrive as Integer or Long.
                "screenshotHeartbeatMs" to 5000L,
                "appHangTimeoutMs" to 2000,
            )
        )
        assertEquals("https://ingest.example", c.apiUrl)
        assertTrue(c.debugLogging)
        assertFalse(c.autoTrackCrashes)
        assertEquals(60, c.flushIntervalSeconds)
        assertEquals(50, c.flushBatchSize)
        assertEquals(500, c.maxOfflineEvents)
        assertEquals(120, c.sessionTimeoutSeconds)
        assertFalse(c.maskInputs)
        assertFalse(c.maskAllText)
        assertTrue(c.maskImages)
        assertFalse(c.maskInputsInScreenshots)
        assertEquals(0.25, c.sampleRate, 0.0)
        assertFalse(c.captureSnapshots)
        assertEquals(2000L, c.snapshotIntervalMs)
        assertEquals(10, c.maxSnapshotsPerSession)
        assertFalse(c.captureScreenshots)
        assertEquals(1500L, c.screenshotIntervalMs)
        assertEquals(40, c.screenshotQuality)
        assertEquals(360, c.screenshotMaxWidth)
        assertFalse(c.uploadScreenshotsOnWifiOnly)
        assertEquals(11, c.maxScreenshotsPerSession)
        assertEquals(12, c.maxScreenshotsPerMinute)
        assertEquals(5000L, c.screenshotHeartbeatMs)
    }

    @Test
    fun screensAndTapsAreAlwaysDartOwned() {
        val c = build(mapOf("autoTrackTaps" to true, "autoTrackRageTaps" to true))
        assertFalse(c.autoTrackScreens)
        assertFalse(c.autoTrackTaps)
        assertFalse(c.autoTrackRageTaps)
    }

    @Test
    fun absentOptionsKeepNativeDefaults() {
        val c = build(emptyMap<String, Any?>())
        val d = UnilitixConfig.Builder().build()
        assertEquals(d.apiUrl, c.apiUrl)
        assertEquals(d.flushIntervalSeconds, c.flushIntervalSeconds)
        assertEquals(d.sampleRate, c.sampleRate, 0.0)
        assertEquals(d.captureScreenshots, c.captureScreenshots)
    }
}
