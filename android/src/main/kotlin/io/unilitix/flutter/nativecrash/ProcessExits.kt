// VENDORED from unilitix-android 1.10.0 (unilitix-sdk/src/main/java/io/unilitix/sdk/capture/ProcessExits.kt) by scripts/sync-android-native.sh.
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
            .map { crashOf(it) }
        // The thread dump is read only for the ANRs kept.
        val anrs = fresh
            .filter { it.reason == REASON_ANR }
            .takeLast(MAX_ANRS_REPORTED)
            .map { AnrTrace.fromExit(it) }
        return Scan(crashes, maxOf(watermark, newest ?: watermark), anrs)
    }

    /**
     * The CRASH for a `REASON_CRASH_NATIVE` exit: signal and (1.10.0) the
     * crashing thread's backtrace from the tombstone (API 31+), else the
     * signal named in the description and no stack. The trace is read once.
     */
    fun crashOf(exit: ProcessExit): NativeCrash {
        val tombstone = readTombstone(exit)
        val signal = tombstone?.signal ?: signalFromDescription(exit.description)
        return NativeCrashRecord.fromSignal(signal, exit.timestampMs, tombstone?.backtrace)
    }

    /** The tombstone's signal (API 31+), else one named in the description, else null (unknown). */
    fun signalOf(exit: ProcessExit): Int? =
        readTombstone(exit)?.signal ?: signalFromDescription(exit.description)

    private fun readTombstone(exit: ProcessExit): Tombstone.Info? {
        val trace = try {
            exit.readTrace()
        } catch (e: Exception) {
            null
        }
        return trace?.let { Tombstone.parse(it) }
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

/** The signal of a tombstone in protobuf form; see [Tombstone]. */
internal object TombstoneSignal {
    /** The signal number (1-64), or null when absent or unreadable. */
    fun parse(bytes: ByteArray): Int? = Tombstone.parse(bytes)?.signal
}

/**
 * Reads a tombstone in protobuf form (AOSP
 * system/core/debuggerd/proto/tombstone.proto), as `getTraceInputStream()`
 * returns it for a native crash on API 31+: the signal
 * (`Tombstone.signal_info.number`) and, from 1.10.0, the crashing thread's
 * backtrace (`Tombstone.threads[Tombstone.tid].current_backtrace`) in the
 * text format of Android tombstones:
 *
 *     #00 pc 000000000001a2b4  /data/app/~~Xy==/com.shop-Ab==/lib/arm64/libshop.so (BuildId: 9f2c…)
 *     #01 pc 0000000000356f20  /apex/com.android.art/lib64/libart.so (art_quick_generic_jni_trampoline+144) (BuildId: 5e6f…)
 *
 * `pc` is the frame's `rel_pc` (the address within the ELF file), so the
 * server symbolicates it with the unstripped library of the same build id.
 *
 * A minimal wire-format reader: no generated code, no dependency. A
 * truncated message is read as far as it goes (fields come in field-number
 * order, so the signal and, usually, the threads come before the large
 * memory-map and log sections).
 */
internal object Tombstone {
    /** [backtrace] null when the crashing thread's frames were not found. */
    data class Info(val signal: Int?, val backtrace: String?)

    const val MAX_FRAMES = 64
    private const val MAX_THREADS = 1024
    private const val MAX_FILE_NAME = 512
    private const val MAX_FUNCTION_NAME = 256

    // Tombstone
    private const val ARCH = 1
    private const val TID = 6
    private const val SIGNAL_INFO = 10
    private const val THREADS = 16
    // Signal
    private const val SIGNAL_NUMBER = 1
    // map<uint32, Thread> entry
    private const val ENTRY_KEY = 1
    private const val ENTRY_VALUE = 2
    // Thread
    private const val THREAD_ID = 1
    private const val THREAD_BACKTRACE = 4
    // BacktraceFrame
    private const val FRAME_REL_PC = 1
    private const val FRAME_FUNCTION_NAME = 4
    private const val FRAME_FUNCTION_OFFSET = 5
    private const val FRAME_FILE_NAME = 6
    private const val FRAME_FILE_MAP_OFFSET = 7
    private const val FRAME_BUILD_ID = 8

    // Architecture: ARM32 = 0, ARM64 = 1, X86 = 2, X86_64 = 3, RISCV64 = 4.
    private const val ARCH_ARM32 = 0
    private const val ARCH_X86 = 2

    private const val WIRE_VARINT = 0
    private const val WIRE_FIXED64 = 1
    private const val WIRE_LEN = 2
    private const val WIRE_FIXED32 = 5

    private val hexOnly = Regex("^[0-9a-fA-F]{1,128}$")

    /** Null when nothing could be read. */
    fun parse(bytes: ByteArray): Info? {
        var signal: Int? = null
        var arch = 1L
        var tid: Long? = null
        // (key, value start, value end) of each threads entry, read after the
        // pass: tid may follow the threads in a hand-built message.
        val threads = ArrayList<LongArray>()
        try {
            forEachField(bytes, 0, bytes.size) { field, wire, value, start, end ->
                when {
                    field == ARCH && wire == WIRE_VARINT -> arch = value
                    field == TID && wire == WIRE_VARINT -> tid = value
                    field == SIGNAL_INFO && wire == WIRE_LEN -> signalNumber(bytes, start, end)?.let { signal = it }
                    field == THREADS && wire == WIRE_LEN && threads.size < MAX_THREADS ->
                        threadEntry(bytes, start, end)?.let { threads.add(it) }
                }
            }
        } catch (e: IndexOutOfBoundsException) {
            // Truncated: keep what was read.
        } catch (e: IllegalArgumentException) {
            // Malformed: keep what was read.
        }
        val validSignal = signal?.takeIf { it in 1..64 }
        val crashed = tid?.let { t -> threads.firstOrNull { it[0] == t } }
        val backtrace = crashed?.let {
            try {
                backtrace(bytes, it[1].toInt(), it[2].toInt(), arch)
            } catch (e: IndexOutOfBoundsException) {
                null
            } catch (e: IllegalArgumentException) {
                null
            }
        }?.takeIf { it.isNotEmpty() }
        if (validSignal == null && backtrace == null) return null
        return Info(validSignal, backtrace)
    }

    private fun signalNumber(bytes: ByteArray, start: Int, end: Int): Int? {
        var number: Int? = null
        try {
            forEachField(bytes, start, end) { field, wire, value, _, _ ->
                if (field == SIGNAL_NUMBER && wire == WIRE_VARINT) number = value.toInt()
            }
        } catch (e: IndexOutOfBoundsException) {
        } catch (e: IllegalArgumentException) {
        }
        return number
    }

    /** `[key, valueStart, valueEnd]` of one map entry, or null. */
    private fun threadEntry(bytes: ByteArray, start: Int, end: Int): LongArray? {
        var key: Long? = null
        var vStart = -1
        var vEnd = -1
        try {
            forEachField(bytes, start, end) { field, wire, value, s, e ->
                if (field == ENTRY_KEY && wire == WIRE_VARINT) key = value
                if (field == ENTRY_VALUE && wire == WIRE_LEN) { vStart = s; vEnd = e }
            }
        } catch (e: IndexOutOfBoundsException) {
            return null
        } catch (e: IllegalArgumentException) {
            return null
        }
        if (vStart < 0) return null
        // The key is optional on the wire (0 is the default); Thread.id has it too.
        val k = key ?: threadId(bytes, vStart, vEnd) ?: 0L
        return longArrayOf(k, vStart.toLong(), vEnd.toLong())
    }

    private fun threadId(bytes: ByteArray, start: Int, end: Int): Long? {
        var id: Long? = null
        try {
            forEachField(bytes, start, end) { field, wire, value, _, _ ->
                if (field == THREAD_ID && wire == WIRE_VARINT) id = value
            }
        } catch (e: IndexOutOfBoundsException) {
        } catch (e: IllegalArgumentException) {
        }
        return id
    }

    private fun backtrace(bytes: ByteArray, start: Int, end: Int, arch: Long): String {
        val width = if (arch == ARCH_ARM32.toLong() || arch == ARCH_X86.toLong()) 8 else 16
        val sb = StringBuilder()
        var index = 0
        forEachField(bytes, start, end) { field, wire, _, s, e ->
            if (field == THREAD_BACKTRACE && wire == WIRE_LEN && index < MAX_FRAMES) {
                frameLine(bytes, s, e, index, width)?.let {
                    if (sb.isNotEmpty()) sb.append('\n')
                    sb.append(it)
                    index++
                }
            }
        }
        return sb.toString()
    }

    private fun frameLine(bytes: ByteArray, start: Int, end: Int, index: Int, width: Int): String? {
        var relPc = 0L
        var function = ""
        var functionOffset = 0L
        var fileName = ""
        var fileMapOffset = 0L
        var buildId = ""
        forEachField(bytes, start, end) { field, wire, value, s, e ->
            when {
                field == FRAME_REL_PC && wire == WIRE_VARINT -> relPc = value
                field == FRAME_FUNCTION_NAME && wire == WIRE_LEN -> function = text(bytes, s, e, MAX_FUNCTION_NAME)
                field == FRAME_FUNCTION_OFFSET && wire == WIRE_VARINT -> functionOffset = value
                field == FRAME_FILE_NAME && wire == WIRE_LEN -> fileName = text(bytes, s, e, MAX_FILE_NAME)
                field == FRAME_FILE_MAP_OFFSET && wire == WIRE_VARINT -> fileMapOffset = value
                field == FRAME_BUILD_ID && wire == WIRE_LEN -> buildId = text(bytes, s, e, 128)
            }
        }
        // As tombstone_proto_to_text prints it.
        val pc = java.lang.Long.toHexString(relPc).padStart(width, '0')
        val line = StringBuilder("#").append(index.toString().padStart(2, '0')).append(" pc ").append(pc)
        line.append("  ").append(fileName.ifEmpty { "<unknown>" })
        if (fileMapOffset != 0L) line.append(" (offset 0x").append(java.lang.Long.toHexString(fileMapOffset)).append(')')
        if (function.isNotEmpty()) {
            line.append(" (").append(function)
            if (functionOffset != 0L) line.append('+').append(functionOffset)
            line.append(')')
        }
        if (hexOnly.matches(buildId)) line.append(" (BuildId: ").append(buildId.lowercase()).append(')')
        return line.toString()
    }

    /** UTF-8 text with control characters replaced, so a frame stays one line. */
    private fun text(bytes: ByteArray, start: Int, end: Int, max: Int): String {
        val s = String(bytes, start, end - start, Charsets.UTF_8)
        val capped = if (s.length > max) s.substring(0, max) else s
        return buildString(capped.length) {
            for (c in capped) append(if (c < ' ' || c == '\u007f') '?' else c)
        }
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
