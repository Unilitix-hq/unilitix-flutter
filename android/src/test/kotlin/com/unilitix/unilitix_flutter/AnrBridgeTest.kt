package com.unilitix.unilitix_flutter

import io.unilitix.flutter.nativecrash.AnrTrace
import io.unilitix.flutter.nativecrash.KeyValueStore
import io.unilitix.flutter.nativecrash.MiniJson
import io.unilitix.flutter.nativecrash.ProcessExit
import io.unilitix.flutter.nativecrash.ProcessExits
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ANR records for Dart (2.6.0, API 30+): what NativeCrashBridge hands to
 * `readNativeCrash` for a `REASON_ANR` exit, and when it hands nothing
 * because the Unilitix Android SDK reports exits. The dump parsing itself
 * (vendored AnrTrace) is tested in the Android SDK, AnrTraceTest.
 */
class AnrBridgeTest {

    private class MemoryStore : KeyValueStore {
        val backing = mutableMapOf<String, Any>()
        override fun getString(key: String): String? = backing[key] as? String
        override fun getBoolean(key: String, default: Boolean): Boolean = backing[key] as? Boolean ?: default
        override fun putString(key: String, value: String) { backing[key] = value }
        override fun putBoolean(key: String, value: Boolean) { backing[key] = value }
    }

    private val killedAt = 1_760_700_000_000L

    /** The contract's "android anr main thread" vector, as a dump's main thread block. */
    private val dump = """
Subject: Input dispatching timed out (com.shop/com.shop.ui.CheckoutActivity is not responding)
DALVIK THREADS (2):
"main" prio=5 tid=1 Native
  | group="main" sCount=1 ucsCount=0 flags=1 obj=0x72a1b2c8 self=0xb400007a1c2d3e40
  | sysTid=8123 nice=-10 cgrp=top-app sched=0/0 handle=0x7b9e1f44f8
  native: #00 pc 000000000009a1b8  /apex/com.android.runtime/lib64/bionic/libc.so (read+8)
  native: #01 pc 0000000000012c34  /system/lib64/libsqlite.so (unixRead+52)
  at android.database.sqlite.SQLiteConnection.nativeExecuteForCursorWindow(Native method)
  at android.database.sqlite.SQLiteConnection.executeForCursorWindow(SQLiteConnection.java:1001)
  - locked <0x0b1c2d3e> (a android.database.sqlite.SQLiteConnection)
  at com.shop.cart.CartRepository.load(CartRepository.kt:88)
  at com.shop.ui.CheckoutActivity.onPay(CheckoutActivity.kt:118)

"Signal Catcher" daemon prio=10 tid=6 Runnable
  native: #00 pc 00000000005b3f1c  /apex/com.android.art/lib64/libart.so (art::DumpNativeStack+108)
""".trimStart()

    private fun anrExit(ts: Long, importance: Int? = 100, description: String? = "Input dispatching timed out") =
        ProcessExit(ProcessExits.REASON_ANR, ts, pid = 8123, description = description,
            readTrace = { dump.toByteArray() }, importance = importance)

    private fun nativeExit(ts: Long) =
        ProcessExit(ProcessExits.REASON_CRASH_NATIVE, ts, pid = 8124, description = "Fatal signal 11 (SIGSEGV)")

    @Suppress("UNCHECKED_CAST")
    private fun parse(record: String): Map<String, Any?> = MiniJson(record).readObject() as Map<String, Any?>

    @Test
    fun anrRecordCarriesTypeMessageMainThreadAndContractFingerprint() {
        val record = parse(NativeCrashBridge.recordFor(AnrTrace.fromExit(anrExit(killedAt))))
        assertEquals("ANR", record["type"])
        assertEquals("ANR", record["exceptionType"])
        assertEquals("android", record["platform"])
        assertEquals("Input dispatching timed out", record["exceptionMessage"])
        assertEquals(killedAt, (record["timestamp"] as Number).toLong())
        val stack = record["stackTrace"] as String
        assertTrue(stack, stack.startsWith("\"main\" prio=5 tid=1 Native\n"))
        assertFalse("property lines dropped", stack.contains("sysTid="))
        assertFalse("other threads left out", stack.contains("Signal Catcher"))
        // SDK contract 1.3.0, vector "android anr main thread".
        assertEquals("ff80a5189f547c4d", record["fingerprint"])
        assertEquals(100, (record["importance"] as Number).toInt())
        assertEquals(true, record["foreground"])
        assertNull("not a crash", record["fatal"])
        assertNull(record["signal"])
    }

    @Test
    fun backgroundImportanceIsNotForeground() {
        val record = parse(NativeCrashBridge.recordFor(AnrTrace.fromExit(anrExit(killedAt, importance = 400))))
        assertEquals(400, (record["importance"] as Number).toInt())
        assertEquals(false, record["foreground"])
    }

    @Test
    fun unknownImportanceAndDescriptionLeaveTheFieldsOutAndUseTheSubject() {
        val record = parse(NativeCrashBridge.recordFor(AnrTrace.fromExit(anrExit(killedAt, importance = null, description = null))))
        assertFalse(record.containsKey("importance"))
        assertFalse(record.containsKey("foreground"))
        assertEquals("Input dispatching timed out (com.shop/com.shop.ui.CheckoutActivity is not responding)",
            record["exceptionMessage"])
    }

    @Test
    fun unreadableDumpStillGivesARecordWithAnEmptyStack() {
        val exit = ProcessExit(ProcessExits.REASON_ANR, killedAt, 1, "ANR", readTrace = { throw SecurityException("no") })
        val record = parse(NativeCrashBridge.recordFor(AnrTrace.fromExit(exit)))
        assertEquals("", record["stackTrace"])
        assertEquals(io.unilitix.flutter.nativecrash.Fingerprint.of("ANR", ""), record["fingerprint"])
    }

    @Test
    fun oneScanSharesTheWatermarkSoEachExitIsHandedOutOnce() {
        val store = MemoryStore()
        // First launch with exit-info capture: watermark = now, nothing reported.
        val first = ProcessExits.scan(store, listOf(anrExit(killedAt - 10)), killedAt)
        assertTrue(first.crashes.isEmpty() && first.anrs.isEmpty())

        val exits = listOf(nativeExit(killedAt + 100), anrExit(killedAt + 200), anrExit(killedAt - 10))
        val scan = ProcessExits.scan(store, exits, killedAt + 1_000)
        val records = NativeCrashBridge.oldestFirst(NativeCrashBridge.exitRecords(scan, sdkReportsExits = false))
        assertEquals(2, records.size)
        assertEquals("SIGNAL", parse(records[0])["exceptionType"])
        assertEquals("ANR", parse(records[1])["type"])

        val again = ProcessExits.scan(store, exits, killedAt + 2_000)
        assertTrue(NativeCrashBridge.exitRecords(again, sdkReportsExits = false).isEmpty())
    }

    @Test
    fun atMostFiveAnrsPerLaunchNewestKept() {
        val store = MemoryStore().apply { putString(ProcessExits.KEY_WATERMARK, "0") }
        val scan = ProcessExits.scan(store, (1..8).map { anrExit(it * 1_000L) }, 10_000)
        val records = NativeCrashBridge.exitRecords(scan, sdkReportsExits = false)
        assertEquals(5, records.size)
        assertEquals(listOf(4_000L, 5_000L, 6_000L, 7_000L, 8_000L),
            records.map { (parse(it)["timestamp"] as Number).toLong() })
    }

    @Test
    fun whenTheAndroidSdkReportsExitsNeitherCrashesNorAnrsAreReturnedButTheWatermarkMoves() {
        val store = MemoryStore().apply { putString(ProcessExits.KEY_WATERMARK, "0") }
        val scan = ProcessExits.scan(store, listOf(nativeExit(100), anrExit(200)), 1_000)
        assertEquals(1, scan.crashes.size)
        assertEquals(1, scan.anrs.size)
        assertTrue(NativeCrashBridge.exitRecords(scan, sdkReportsExits = true).isEmpty())
        assertEquals("200", store.getString(ProcessExits.KEY_WATERMARK))
    }

    @Test
    fun anrsFollowTheExitDecisionForEverySdkState() {
        val store = MemoryStore().apply { putString(ProcessExits.KEY_WATERMARK, "0") }
        val scan = ProcessExits.scan(store, listOf(anrExit(200)), 1_000)
        val expected = mapOf(
            AndroidSdkNativeCrash.State.ABSENT to 1,
            AndroidSdkNativeCrash.State.LEGACY to 1, // SDK < 1.8.0 never reports ANRs
            AndroidSdkNativeCrash.State.NOT_INITIALIZED to 1,
            AndroidSdkNativeCrash.State.INACTIVE to 1, // SDK without autoTrackCrashes
            AndroidSdkNativeCrash.State.ACTIVE to 0, // SDK 1.9.0+ reports them (1.8.x: see sdkReportsExits)
        )
        for ((state, n) in expected) {
            assertEquals(state.name, n,
                NativeCrashBridge.exitRecords(scan, AndroidSdkNativeCrash.sdkReportsExits(state)).size)
        }
    }

    @Test
    fun anrRecordsSortAmongCrashRecordsByKillTime() {
        val anr = NativeCrashBridge.recordFor(AnrTrace.fromExit(anrExit(150)))
        val a = """{"exceptionType":"SIGNAL","signal":6,"timestamp":300}"""
        val b = """{"exceptionType":"java.lang.Error","timestamp":100}"""
        assertEquals(listOf(b, anr, a), NativeCrashBridge.oldestFirst(listOf(a, anr, b)))
    }
}
