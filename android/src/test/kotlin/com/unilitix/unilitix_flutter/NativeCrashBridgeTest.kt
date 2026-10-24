package com.unilitix.unilitix_flutter

import io.unilitix.flutter.nativecrash.NativeCrashRecord
import io.unilitix.flutter.nativecrash.NativeSignalHandler
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * The plugin-owned glue around the vendored native crash capture (the
 * vendored logic itself is tested in the Android SDK, NativeCrashTest).
 */
class NativeCrashBridgeTest {

    @Test
    fun signalRecordForDartCarriesNameAndContractFingerprint() {
        val crash = NativeCrashRecord.parse(
            """{"platform":"android","exceptionType":"SIGNAL","signal":11,"timestamp":1760700000000}"""
        )!!
        assertEquals(
            """{"platform":"android","exceptionType":"SIGNAL","signal":11,""" +
                """"exceptionMessage":"Fatal signal 11 (SIGSEGV)","timestamp":1760700000000,""" +
                """"fingerprint":"8f1fc15bfa06be00"}""",
            NativeCrashBridge.recordFor(crash)
        )
    }

    @Test
    fun exitWithUnknownSignalIsKeyedSignalWithoutNumberOrMessage() {
        val record = NativeCrashBridge.recordFor(NativeCrashRecord.fromSignal(null, 42L))
        val expectedFp = NativeCrashRecord.fingerprint("SIGNAL", null, null)
        assertEquals(
            """{"platform":"android","exceptionType":"SIGNAL","timestamp":42,"fingerprint":"$expectedFp"}""",
            record
        )
    }

    @Test
    fun stringsAreEscaped() {
        val crash = NativeCrashRecord.parse(
            """{"exceptionType":"X","exceptionMessage":"a \"b\"\n\\c","stackTrace":"at a.b(c.kt:1)\n\tat d"}"""
        )!!
        val record = NativeCrashBridge.recordFor(crash)
        assertTrue(record, record.contains(""""exceptionMessage":"a \"b\"\n\\c""""))
        assertTrue(record, record.contains(""""stackTrace":"at a.b(c.kt:1)\n\tat d""""))
        // Round trip through the vendored parser.
        assertEquals("a \"b\"\n\\c", NativeCrashRecord.parse(record)!!.exceptionMessage)
    }

    @Test
    fun recordsAreHandedOutOldestFirstUnknownTimesLast() {
        val a = """{"exceptionType":"SIGNAL","signal":6,"timestamp":300}"""
        val b = """{"exceptionType":"java.lang.Error","timestamp":100}"""
        val c = """{"exceptionType":"SIGNAL"}"""
        val d = """{"exceptionType":"SIGNAL","signal":11,"timestamp":200}"""
        assertEquals(listOf(b, d, a, c), NativeCrashBridge.oldestFirst(listOf(a, b, c, d)))
    }

    @Test
    fun signalRecordsOfEarlierProcessesAreConsumedOnceNewestKept() {
        val dir = Files.createTempDirectory("signals").toFile()
        try {
            val own = File(dir, "9000-3.json")
            own.writeText("""{"exceptionType":"SIGNAL","signal":11,"timestamp":9000}""")
            for (i in 1..7) {
                File(dir, "$i-1.json").apply {
                    writeText("""{"exceptionType":"SIGNAL","signal":11,"timestamp":$i}""")
                    setLastModified(i * 1000L)
                }
            }
            val texts = NativeCrashBridge.consumeSignalRecords(dir, own)
            assertEquals(NativeCrashBridge.MAX_SIGNAL_RECORDS, texts.size)
            assertEquals(listOf(7L, 6L, 5L, 4L, 3L), texts.map { NativeCrashRecord.parse(it)!!.timestampMs })
            assertEquals(listOf("9000-3.json"), dir.list()!!.toList())
            assertTrue(NativeCrashBridge.consumeSignalRecords(dir, own).isEmpty())
            assertTrue("this process's file is left alone", own.exists())
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun noSignalDirectoryIsNothing() {
        assertTrue(NativeCrashBridge.consumeSignalRecords(File("/nonexistent/unilitix"), null).isEmpty())
    }

    @Test
    fun libraryNameDiffersFromTheAndroidSdks() {
        // Must match CMakeLists.txt's add_library, and must not be the
        // Android SDK's unilitix-native, or an app with both clashes.
        assertEquals("unilitix-flutter-native", NativeSignalHandler.LIBRARY)
    }

    @Test
    fun handlerIsNotInstalledOnApi30AndLater() {
        var loaded = false
        val installed = NativeSignalHandler.install(
            File("unused"),
            sdkInt = 30,
            loadLibrary = { loaded = true },
            nativeInstaller = { true }
        )
        assertFalse(installed)
        assertFalse(loaded)
    }
}
