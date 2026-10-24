package io.unilitix.flutter.nativecrash

import android.util.Log

// Plugin-owned (not vendored): the two Android SDK types the vendored native
// crash sources use, which the SDK defines in files that are not vendored
// (core/Consent.kt, util/Logger.kt). scripts/sync-android-native.sh never
// overwrites this file.

/** Where [ProcessExits.scan] keeps its watermark (the SDK's `core.KeyValueStore`). */
internal interface KeyValueStore {
    fun getString(key: String): String?
    fun getBoolean(key: String, default: Boolean): Boolean
    fun putString(key: String, value: String)
    fun putBoolean(key: String, value: Boolean)
}

/**
 * The SDK's `util.Logger`, reduced to what the vendored code calls. Debug
 * lines are dropped (the Dart side owns SDK logging); warnings go to logcat
 * under the `Unilitix` tag.
 */
internal object Logger {
    private const val TAG = "Unilitix"

    @Suppress("UNUSED_PARAMETER")
    fun d(message: String) {
        // Intentionally silent: no debug flag reaches the Android side.
    }

    fun w(message: String) {
        try {
            Log.w(TAG, message)
        } catch (_: Throwable) {
            // android.util.Log is a stub in JVM unit tests.
        }
    }
}
