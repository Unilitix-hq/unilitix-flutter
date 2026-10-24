package com.unilitix.unilitix_flutter

/**
 * Coordination with the Unilitix Android SDK (`com.unilitix:unilitix-android`,
 * package `io.unilitix.sdk`) in apps that ship it next to this plugin.
 *
 * Both capture native (NDK) crashes the same way (signal handler on API
 * 21-29, `ApplicationExitInfo` on API 30+), so with both active one crash
 * would be reported twice. From Android SDK 1.8.0, `Unilitix.nativeCrashCaptureActive()`
 * says the SDK captures native crashes in this process; when it does, the
 * plugin leaves native crashes to it: no signal handler of its own, and the
 * exit records it reads are dropped (its watermark still moves, so nothing is
 * reported late if the SDK is removed). The SDK attributes each crash to its
 * own session that was running, as it does in a native app.
 *
 * Looked up by name: no compile-time dependency, so the plugin builds and
 * runs the same without the SDK, and with an SDK older than 1.8.0 (no such
 * method) it keeps its own capture as in 2.4.0.
 *
 * ANRs (plugin 2.6.0, API 30+) follow the same decision as exit-info native
 * crashes ([sdkReportsExits]).
 *
 * JVM crashes and sessions are not coordinated: each SDK keeps reporting its own.
 */
internal object AndroidSdkNativeCrash {

    const val SDK_CLASS = "io.unilitix.sdk.Unilitix"
    const val ACTIVE_METHOD = "nativeCrashCaptureActive"
    const val INITIALIZED_METHOD = "isInitialized"

    enum class State {
        /** The Android SDK is not in the app. */
        ABSENT,
        /** An Android SDK older than 1.8.0 (or one that cannot be asked): both capture, as before. */
        LEGACY,
        /** SDK 1.8.0+ present but `init` has not run yet: it may still take over. */
        NOT_INITIALIZED,
        /** SDK initialized without native capture (`autoTrackCrashes` off, handler not installed). */
        INACTIVE,
        /** The SDK captures native crashes in this process. */
        ACTIVE,
    }

    /** What the plugin does with its signal handler at attach. */
    enum class Install { INSTALL, SKIP, DEFER }

    fun state(loadClass: (String) -> Class<*>? = ::loadSdkClass): State {
        val cls = try {
            loadClass(SDK_CLASS)
        } catch (_: Throwable) {
            null
        } ?: return State.ABSENT
        val active = try {
            cls.getMethod(ACTIVE_METHOD)
        } catch (_: Throwable) {
            return State.LEGACY
        }
        return try {
            when {
                active.invoke(null) == true -> State.ACTIVE
                cls.getMethod(INITIALIZED_METHOD).invoke(null) == true -> State.INACTIVE
                else -> State.NOT_INITIALIZED
            }
        } catch (_: Throwable) {
            State.LEGACY
        }
    }

    /**
     * At plugin attach. An SDK that is present but not initialized yet (a
     * Flutter engine started in `Application.onCreate` before
     * `Unilitix.init`) gets until the next main-looper turn ([DEFER]), then
     * [afterDefer] decides.
     */
    fun installDecision(state: State): Install = when (state) {
        State.ACTIVE -> Install.SKIP
        State.NOT_INITIALIZED -> Install.DEFER
        State.ABSENT, State.LEGACY, State.INACTIVE -> Install.INSTALL
    }

    fun afterDefer(state: State): Install = if (state == State.ACTIVE) Install.SKIP else Install.INSTALL

    /**
     * At collection (next launch): exit records, native crashes and ANRs
     * alike, are the SDK's to report when it is active.
     *
     * ANRs (2.6.0): Android SDK 1.9.0+ reports them from the same exits. SDK
     * 1.8.x does not, and this plugin's own scan would still see them (its
     * watermark is its own, in its own preferences), but 1.8.x and 1.9.x
     * cannot be told apart at runtime: neither adds a public member, and in
     * an R8-minified release build the SDK's BuildConfig and internal classes
     * are removed or renamed. Reporting them whenever the SDK is active
     * would send every ANR twice with 1.9.0+, so they are left to the SDK in
     * every version: with 1.8.x, ANRs are not reported until the app moves to
     * Android SDK 1.9.0 (README). Without the SDK, with one older than 1.8.0
     * ([State.LEGACY], which never reports ANRs) or one initialized without
     * crash capture ([State.INACTIVE]), the plugin reports them; an SDK not
     * initialized yet when Dart reads the records is treated as for native
     * crashes (the plugin reports).
     */
    fun sdkReportsExits(state: State): Boolean = state == State.ACTIVE

    private fun loadSdkClass(name: String): Class<*>? = try {
        Class.forName(name, false, AndroidSdkNativeCrash::class.java.classLoader)
    } catch (_: ClassNotFoundException) {
        null
    } catch (_: LinkageError) {
        null
    }
}
