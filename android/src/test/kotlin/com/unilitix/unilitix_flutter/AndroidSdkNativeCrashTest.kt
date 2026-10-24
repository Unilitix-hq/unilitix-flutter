package com.unilitix.unilitix_flutter

import com.unilitix.unilitix_flutter.AndroidSdkNativeCrash.Install
import com.unilitix.unilitix_flutter.AndroidSdkNativeCrash.State
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Stand-ins for `io.unilitix.sdk.Unilitix`, found the way the real one is (static methods by name). */
object SdkActive {
    @JvmStatic fun nativeCrashCaptureActive(): Boolean = true
    @JvmStatic val isInitialized: Boolean get() = true
}

object SdkNotInitialized {
    @JvmStatic fun nativeCrashCaptureActive(): Boolean = false
    @JvmStatic val isInitialized: Boolean get() = false
}

object SdkInactive {
    @JvmStatic fun nativeCrashCaptureActive(): Boolean = false
    @JvmStatic val isInitialized: Boolean get() = true
}

/** Android SDK 1.7.x: no nativeCrashCaptureActive. */
object SdkLegacy {
    @JvmStatic val isInitialized: Boolean get() = true
}

object SdkThrows {
    @JvmStatic fun nativeCrashCaptureActive(): Boolean = throw IllegalStateException("boom")
}

class AndroidSdkNativeCrashTest {

    private fun stateOf(cls: Class<*>?): State =
        AndroidSdkNativeCrash.state { name ->
            assertEquals("io.unilitix.sdk.Unilitix", name)
            cls
        }

    @Test
    fun statesFromTheSdkClass() {
        assertEquals(State.ABSENT, stateOf(null))
        assertEquals(State.ABSENT, AndroidSdkNativeCrash.state { throw ClassNotFoundException(it) })
        assertEquals(State.LEGACY, stateOf(SdkLegacy::class.java))
        assertEquals(State.LEGACY, stateOf(SdkThrows::class.java))
        assertEquals(State.NOT_INITIALIZED, stateOf(SdkNotInitialized::class.java))
        assertEquals(State.INACTIVE, stateOf(SdkInactive::class.java))
        assertEquals(State.ACTIVE, stateOf(SdkActive::class.java))
    }

    @Test
    fun withoutTheSdkInThisTestClasspathThePluginCaptures() {
        // The real lookup: the Android SDK is not a dependency of the plugin.
        assertEquals(State.ABSENT, AndroidSdkNativeCrash.state())
    }

    @Test
    fun handlerInstalledUnlessTheSdkCaptures() {
        assertEquals(Install.INSTALL, AndroidSdkNativeCrash.installDecision(State.ABSENT))
        assertEquals(Install.INSTALL, AndroidSdkNativeCrash.installDecision(State.LEGACY))
        assertEquals(Install.INSTALL, AndroidSdkNativeCrash.installDecision(State.INACTIVE))
        assertEquals(Install.SKIP, AndroidSdkNativeCrash.installDecision(State.ACTIVE))
        assertEquals(Install.DEFER, AndroidSdkNativeCrash.installDecision(State.NOT_INITIALIZED))
        // After one main-looper turn: only an active SDK takes over.
        assertEquals(Install.SKIP, AndroidSdkNativeCrash.afterDefer(State.ACTIVE))
        for (s in listOf(State.ABSENT, State.LEGACY, State.INACTIVE, State.NOT_INITIALIZED)) {
            assertEquals(Install.INSTALL, AndroidSdkNativeCrash.afterDefer(s))
        }
    }

    @Test
    fun exitRecordsAreTheSdksOnlyWhenItIsActive() {
        assertTrue(AndroidSdkNativeCrash.sdkReportsExits(State.ACTIVE))
        for (s in listOf(State.ABSENT, State.LEGACY, State.INACTIVE, State.NOT_INITIALIZED)) {
            assertFalse(AndroidSdkNativeCrash.sdkReportsExits(s))
        }
    }
}
