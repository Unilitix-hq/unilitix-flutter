package com.unilitix.unilitix_flutter

import io.unilitix.sdk.UnilitixConfig

/**
 * Maps the Dart SDK's options (SDK contract canonical keys, see
 * `nativeInitArguments` in lib/unilitix.dart) onto the Android SDK's
 * [UnilitixConfig.Builder]. An option that is absent keeps the native
 * default; the native SDK clamps out-of-range values.
 */
internal object NativeConfig {

    fun apply(b: UnilitixConfig.Builder, c: Map<*, *>) {
        c.string("apiUrl")?.takeIf { it.isNotEmpty() }?.let { b.apiUrl = it }
        c.bool("debug")?.let { b.debugLogging = it }
        // Flutter has one Activity: the native screen tracker would report it
        // as the only screen. Route names come from Dart (trackScreen).
        b.autoTrackScreens = false
        // The native tap tracker names every tap's screen after the Activity
        // and cannot see UnilitixPrivate areas: Dart reports taps and rage
        // taps (`recordTap`), so the native ones are off.
        b.autoTrackTaps = false
        b.autoTrackRageTaps = false
        c.bool("autoTrackCrashes")?.let { b.autoTrackCrashes = it }
        c.int("flushIntervalSeconds")?.let { b.flushIntervalSeconds = it }
        c.int("flushBatchSize")?.let { b.flushBatchSize = it }
        c.int("maxOfflineEvents")?.let { b.maxOfflineEvents = it }
        c.int("sessionTimeoutSeconds")?.let { b.sessionTimeoutSeconds = it }
        c.bool("maskInputs")?.let { b.maskInputs = it }
        c.bool("maskAllText")?.let { b.maskAllText = it }
        c.bool("maskImages")?.let { b.maskImages = it }
        c.bool("maskInputsInScreenshots")?.let { b.maskInputsInScreenshots = it }
        // The contract's replaySampleRate is `sampleRate` on Android.
        c.double("replaySampleRate")?.let { b.sampleRate = it }
        c.bool("captureSnapshots")?.let { b.captureSnapshots = it }
        c.long("snapshotIntervalMs")?.let { b.snapshotIntervalMs = it }
        c.int("maxSnapshotsPerSession")?.let { b.maxSnapshotsPerSession = it }
        c.bool("captureScreenshots")?.let { b.captureScreenshots = it }
        c.long("screenshotIntervalMs")?.let { b.screenshotIntervalMs = it }
        c.int("screenshotQuality")?.let { b.screenshotQuality = it }
        c.int("screenshotMaxWidth")?.let { b.screenshotMaxWidth = it }
        c.bool("uploadScreenshotsOnWifiOnly")?.let { b.uploadScreenshotsOnWifiOnly = it }
        c.int("maxScreenshotsPerSession")?.let { b.maxScreenshotsPerSession = it }
        c.int("maxScreenshotsPerMinute")?.let { b.maxScreenshotsPerMinute = it }
        c.long("screenshotHeartbeatMs")?.let { b.screenshotHeartbeatMs = it }
        // appHangTimeoutMs is iOS-only (Android reports the system's ANRs).
    }

    private fun Map<*, *>.bool(key: String): Boolean? = this[key] as? Boolean
    private fun Map<*, *>.int(key: String): Int? = (this[key] as? Number)?.toInt()
    private fun Map<*, *>.long(key: String): Long? = (this[key] as? Number)?.toLong()
    private fun Map<*, *>.double(key: String): Double? = (this[key] as? Number)?.toDouble()
}
