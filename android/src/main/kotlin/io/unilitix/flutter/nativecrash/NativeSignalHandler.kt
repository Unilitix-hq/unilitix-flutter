// VENDORED from unilitix-android 1.9.0 (unilitix-sdk/src/main/java/io/unilitix/sdk/capture/NativeSignalHandler.kt) by scripts/sync-android-native.sh.
// Do not edit here; change the Android SDK and re-run the script.

package io.unilitix.flutter.nativecrash

import android.os.Build
import java.io.File

/**
 * Native crash capture for Android 5.0-10 (API 21-29): fatal-signal handlers
 * in `libunilitix-flutter-native.so` (src/main/cpp) write a [NativeCrashRecord] to
 * [NativeCrashFile] in the dying process; the next launch reports it.
 *
 * On API 30+ nothing is installed: the system records native crashes itself
 * and [ProcessExits] reads them. If the library cannot be loaded (an ABI the
 * AAR does not ship, a broken split install) the SDK logs it and carries on
 * without native capture.
 *
 * The JNI methods are bound by name; consumer-rules.pro keeps them.
 */
internal object NativeSignalHandler {

    const val LIBRARY = "unilitix-flutter-native"
    /** Last API level that needs the in-process handler (30 has ApplicationExitInfo). */
    const val LAST_API_LEVEL = 29

    @Volatile
    var isInstalled: Boolean = false
        private set

    /**
     * True once an uncaught JVM exception (or a fatal `recordException`) was
     * reported: the signal that may follow it is not recorded again. Mirrors
     * UnilitixCore's `CrashFile.markExceptionHandled()`.
     */
    @Volatile
    var exceptionHandled: Boolean = false
        private set

    /**
     * Installs the handlers, writing to [file], once. False when not needed
     * (API 30+), already failed, or the library could not be loaded.
     */
    @Synchronized
    fun install(
        file: File,
        sdkInt: Int = Build.VERSION.SDK_INT,
        loadLibrary: (String) -> Unit = { System.loadLibrary(it) },
        nativeInstaller: (String) -> Boolean = { nativeInstall(it) }
    ): Boolean {
        if (isInstalled) return true
        if (sdkInt > LAST_API_LEVEL) return false
        return try {
            file.parentFile?.mkdirs()
            loadLibrary(LIBRARY)
            isInstalled = nativeInstaller(file.absolutePath)
            if (isInstalled) Logger.d("NativeSignalHandler: installed (API $sdkInt)")
            else Logger.w("Unilitix: native crash handler could not be installed; continuing without it")
            isInstalled
        } catch (e: UnsatisfiedLinkError) {
            Logger.w("Unilitix: lib$LIBRARY.so not loaded (${e.message}); native crashes will not be captured")
            false
        } catch (e: SecurityException) {
            Logger.w("Unilitix: native crash handler not installed (${e.message})")
            false
        }
    }

    /**
     * The uncaught exception about to end the process has been dealt with
     * (reported, or deliberately not, e.g. consent denied): the SIGABRT that
     * may follow it is not reported as a native crash. Safe to call when the
     * library is not loaded.
     */
    fun markExceptionHandled(nativeMarker: () -> Unit = { nativeMarkExceptionHandled() }) {
        exceptionHandled = true
        if (!isInstalled) return
        try {
            nativeMarker()
        } catch (e: Throwable) {
            // Already crashing: never let this get in the way.
        }
    }

    /** Tests only. */
    internal fun resetForTests() {
        isInstalled = false
        exceptionHandled = false
    }

    @JvmStatic
    private external fun nativeInstall(path: String): Boolean

    @JvmStatic
    private external fun nativeMarkExceptionHandled()
}
