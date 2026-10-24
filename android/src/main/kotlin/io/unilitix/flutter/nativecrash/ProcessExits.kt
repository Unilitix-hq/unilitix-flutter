// VENDORED from unilitix-android 1.9.0 (unilitix-sdk/src/main/java/io/unilitix/sdk/capture/ProcessExits.kt) by scripts/sync-android-native.sh.
// Do not edit here; change the Android SDK and re-run the script.

package io.unilitix.flutter.nativecrash


/**
 * One `ApplicationExitInfo`, copied out so the selection logic runs in JVM
 * unit tests. [readTrace] returns the start of `getTraceInputStream()` (for a
 * native crash on API 31+, the tombstone in protobuf form; for an ANR, the
 * text thread dump) or null. [importance] is `getImportance()`.
 */
internal data class ProcessExit(
    val reason: Int,
    val timestampMs: Long,
    val pid: Int,
    val description: String?,
    val readTrace: () -> ByteArray? = { null },
    val importance: Int? = null
)

/**
 * Native crashes and ANRs from the system's record of how earlier processes
 * of this app ended (`ActivityManager.getHistoricalProcessExitReasons`,
 * API 30+).
 *
 * `REASON_CRASH_NATIVE` is reported as a CRASH and (from 1.9.0) `REASON_ANR`
 * as an ANR (contract 1.3.0; not a crash). `REASON_CRASH` (an uncaught JVM
 * exception) is not: CrashHandler reported it, with its stack, before the
 * process died.
 *
 * A watermark (the newest exit timestamp already looked at) is kept in the
 * SDK's preferences so every exit is considered once. On the first launch
 * with this SDK version there is no watermark: it is set to now and nothing
 * is reported, so exits from before the upgrade (already-reported JVM
 * crashes, native crashes of sessions uploaded long ago, possibly before the
 * user's consent decision) never arrive as a flood of stale crashes.
 */
internal object ProcessExits {

    /** `ApplicationExitInfo.REASON_CRASH`: uncaught JVM exception. */
    const val REASON_CRASH = 4
    /** `ApplicationExitInfo.REASON_CRASH_NATIVE`. */
    const val REASON_CRASH_NATIVE = 5
    /** `ApplicationExitInfo.REASON_ANR`. */
    const val REASON_ANR = 6

    /** How many exits to ask the system for (it keeps a bounded history per package). */
    const val MAX_QUERIED = 32
    /** At most this many native crashes reported per launch (newest kept), so a crash loop cannot flood the queue. */
    const val MAX_REPORTED = 5
    /** At most this many ANRs reported per launch (newest kept); their dumps are only read for these. */
    const val MAX_ANRS_REPORTED = 5

    const val KEY_WATERMARK = "native_exit_watermark"

    data class Scan(val crashes: List<NativeCrash>, val watermark: Long, val anrs: List<Anr> = emptyList())

    /**
     * Picks the native crashes and ANRs newer than the stored watermark and
     * advances it past every exit seen (reported or not), so each is reported
     * at most once. Consent is applied by the caller: a denied scan still
     * advances the watermark, so the reports are dropped, not held.
     */
    fun scan(kv: KeyValueStore, exits: List<ProcessExit>, nowMs: Long): Scan {
        val stored = kv.getString(KEY_WATERMARK)?.toLongOrNull()
        val result = select(exits, stored, nowMs)
        if (stored == null || result.watermark != stored) kv.putString(KEY_WATERMARK, result.watermark.toString())
        return result
    }

    fun select(exits: List<ProcessExit>, watermark: Long?, nowMs: Long): Scan {
        val newest = exits.maxOfOrNull { it.timestampMs }
        if (watermark == null) {
            // First launch with exit-info capture: start from now.
            return Scan(emptyList(), maxOf(nowMs, newest ?: nowMs), emptyList())
        }
        val fresh = exits.filter { it.timestampMs > watermark }.sortedBy { it.timestampMs }
        val crashes = fresh
            .filter { it.reason == REASON_CRASH_NATIVE }
            .takeLast(MAX_REPORTED)
            .map { NativeCrashRecord.fromSignal(signalOf(it), it.timestampMs) }
        // The thread dump is read only for the ANRs kept.
        val anrs = fresh
            .filter { it.reason == REASON_ANR }
            .takeLast(MAX_ANRS_REPORTED)
            .map { AnrTrace.fromExit(it) }
        return Scan(crashes, maxOf(watermark, newest ?: watermark), anrs)
    }

    /** The tombstone's signal (API 31+), else one named in the description, else null (unknown). */
    fun signalOf(exit: ProcessExit): Int? {
        val trace = try {
            exit.readTrace()
        } catch (e: Exception) {
            null
        }
        trace?.let { TombstoneSignal.parse(it) }?.let { return it }
        return signalFromDescription(exit.description)
    }

    private val numbered = Regex("""(?i)\bsignal\s+(\d{1,2})\b""")
    private val named = Regex("""\bSIG(ABRT|BUS|FPE|ILL|SEGV|TRAP|SYS)\b""")
    private val numberOf = mapOf(
        "ABRT" to 6, "BUS" to 7, "FPE" to 8, "ILL" to 4, "SEGV" to 11, "TRAP" to 5, "SYS" to 31
    )

    /** `Fatal signal 11 (SIGSEGV), code 1 ...` → 11; `SIGABRT` → 6; else null. */
    fun signalFromDescription(description: String?): Int? {
        if (description.isNullOrEmpty()) return null
        numbered.find(description)?.groupValues?.get(1)?.toIntOrNull()?.takeIf { it in 1..64 }?.let { return it }
        return named.find(description)?.groupValues?.get(1)?.let { numberOf[it] }
    }
}

/**
 * Reads `Tombstone.signal_info.number` from a tombstone in protobuf form
 * (AOSP system/core/debuggerd/proto/tombstone.proto: `Signal signal_info = 10`
 * in `Tombstone`, `int32 number = 1` in `Signal`). A minimal wire-format
 * reader: no generated code, no dependency. Fields are written in field
 * order, so `signal_info` sits near the start; the caller passes only the
 * first bytes of the trace and a truncated message is read as far as it goes.
 */
internal object TombstoneSignal {
    private const val TOMBSTONE_SIGNAL_INFO = 10
    private const val SIGNAL_NUMBER = 1

    private const val WIRE_VARINT = 0
    private const val WIRE_FIXED64 = 1
    private const val WIRE_LEN = 2
    private const val WIRE_FIXED32 = 5

    /** The signal number (1-64), or null when absent or unreadable. */
    fun parse(bytes: ByteArray): Int? {
        var found: Int? = null
        try {
            forEachField(bytes, 0, bytes.size) { field, wire, value, start, end ->
                if (field == TOMBSTONE_SIGNAL_INFO && wire == WIRE_LEN) {
                    signalNumber(bytes, start, end)?.let { found = it }
                }
            }
        } catch (e: IndexOutOfBoundsException) {
            // Truncated: keep what was read.
        } catch (e: IllegalArgumentException) {
            // Malformed: keep what was read.
        }
        return found?.takeIf { it in 1..64 }
    }

    private fun signalNumber(bytes: ByteArray, start: Int, end: Int): Int? {
        var number: Int? = null
        forEachField(bytes, start, end) { field, wire, value, _, _ ->
            if (field == SIGNAL_NUMBER && wire == WIRE_VARINT) number = value.toInt()
        }
        return number
    }

    /**
     * Calls [visit] for each field in `bytes[from, to)` with its number, wire
     * type, varint value (wire 0) and payload range (wire 2).
     */
    private inline fun forEachField(
        bytes: ByteArray,
        from: Int,
        to: Int,
        visit: (field: Int, wire: Int, value: Long, start: Int, end: Int) -> Unit
    ) {
        var pos = from
        while (pos < to) {
            val (key, afterKey) = varint(bytes, pos, to)
            pos = afterKey
            val field = (key ushr 3).toInt()
            val wire = (key and 7L).toInt()
            require(field > 0) { "bad field" }
            when (wire) {
                WIRE_VARINT -> {
                    val (v, next) = varint(bytes, pos, to)
                    pos = next
                    visit(field, wire, v, pos, pos)
                }
                WIRE_FIXED64 -> pos = skip(pos, 8, to)
                WIRE_LEN -> {
                    val (len, next) = varint(bytes, pos, to)
                    require(len >= 0 && len <= Int.MAX_VALUE) { "bad length" }
                    val end = next + len.toInt()
                    if (end > to || end < next) throw IndexOutOfBoundsException("truncated")
                    visit(field, wire, 0L, next, end)
                    pos = end
                }
                WIRE_FIXED32 -> pos = skip(pos, 4, to)
                else -> throw IllegalArgumentException("unsupported wire type $wire")
            }
        }
    }

    private fun skip(pos: Int, n: Int, to: Int): Int {
        if (pos + n > to) throw IndexOutOfBoundsException("truncated")
        return pos + n
    }

    private fun varint(bytes: ByteArray, from: Int, to: Int): Pair<Long, Int> {
        var result = 0L
        var shift = 0
        var pos = from
        while (true) {
            if (pos >= to) throw IndexOutOfBoundsException("truncated varint")
            val b = bytes[pos++].toInt() and 0xff
            result = result or ((b and 0x7f).toLong() shl shift)
            if (b and 0x80 == 0) return result to pos
            shift += 7
            require(shift < 64) { "varint too long" }
        }
    }
}
