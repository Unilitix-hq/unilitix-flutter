// VENDORED from unilitix-android 1.9.0 (unilitix-sdk/src/main/java/io/unilitix/sdk/capture/AnrTrace.kt) by scripts/sync-android-native.sh.
// Do not edit here; change the Android SDK and re-run the script.

package io.unilitix.flutter.nativecrash


/**
 * An ANR (app not responding) of an earlier process: an `ApplicationExitInfo`
 * with `REASON_ANR` (API 30+, [ProcessExits]). The system records one when it
 * killed the process after an ANR (the user chose "Close app", or the system
 * did it for a background ANR); an ANR the app recovered from leaves no exit
 * record, so it is not reported.
 *
 * Reported on the next launch as an `ANR` event (contract 1.3.0): its own
 * issue type, not a crash, so the session is not marked crashed.
 */
internal data class Anr(
    /** The system's description, e.g. `Input dispatching timed out (...)`. */
    val exceptionMessage: String,
    /** The main thread's section of the ANR thread dump, or "" when unreadable. */
    val stackTrace: String,
    /** When the process was killed (ms since 1970), or null when unknown. */
    val timestampMs: Long?,
    /** `ApplicationExitInfo.getImportance()` of the process when it died, or null. */
    val importance: Int?,
    val fingerprint: String
)

/**
 * Reads the main thread out of the text thread dump `getTraceInputStream()`
 * returns for `REASON_ANR` (the ART "traces" format, API 30+). Pure Kotlin so
 * it runs in JVM unit tests.
 *
 * The dump lists every thread as a block that starts with a quoted name and
 * ends at a blank line:
 * ```
 * "main" prio=5 tid=1 Blocked
 *   | group="main" sCount=1 ucsCount=0 flags=1 obj=0x72a1b2c8 self=0xb400...
 *   | sysTid=8123 nice=-10 cgrp=top-app sched=0/0 handle=0x7b9e1f44f8
 *   native: #00 pc 000000000009a1b8  /apex/.../libc.so (syscall+28)
 *   at com.shop.cart.CartRepository.load(CartRepository.kt:88)
 *   - waiting to lock <0x0b1c2d3e> (a java.lang.Object) held by thread 14
 *   at com.shop.ui.CheckoutActivity.onPay(CheckoutActivity.kt:118)
 * ```
 * The `|` property lines (thread ids, scheduler state, addresses) are dropped:
 * noise for a reader and different on every report. The header, the native
 * and managed frames and the lock lines are kept.
 */
internal object AnrTrace {

    const val TYPE = "ANR"
    const val PLATFORM = "android"
    /** Same cap as a crash stack. */
    const val MAX_STACK = 16 * 1024
    /** How much of the dump is read: the main thread comes first, after a short header. */
    const val MAX_TRACE_BYTES = 256 * 1024
    /** Message used when the system gave no description. */
    const val DEFAULT_MESSAGE = "Application Not Responding"

    /** `IMPORTANCE_FOREGROUND`: the app was in front of the user (Play's "user-perceived" ANR). */
    private const val IMPORTANCE_FOREGROUND = 100

    private val subjectLine = Regex("""(?m)^Subject:\s*(.+)$""")

    /**
     * The `"main"` thread's block of [dump] without its `|` property lines, or
     * null when the dump has no main thread. Capped at [MAX_STACK] characters
     * on a line boundary.
     */
    fun mainThread(dump: String): String? {
        val lines = dump.lineSequence().iterator()
        val out = StringBuilder()
        var inMain = false
        while (lines.hasNext()) {
            val line = lines.next().trimEnd('\r')
            if (!inMain) {
                if (line.startsWith("\"main\" ")) {
                    inMain = true
                    out.append(line.trimEnd())
                }
                continue
            }
            if (line.isBlank() || line.startsWith("\"")) break
            if (line.trimStart().startsWith("|")) continue
            if (out.length + 1 + line.length > MAX_STACK) break
            out.append('\n').append(line.trimEnd())
        }
        return if (inMain) out.toString() else null
    }

    /** The `Subject:` line of the dump header (API 30+ dumps carry the ANR reason there). */
    fun subject(dump: String): String? =
        subjectLine.find(dump)?.groupValues?.get(1)?.trim()?.takeIf { it.isNotEmpty() }

    /** The ANR of [exit]; a trace that cannot be read leaves the stack empty. */
    fun fromExit(exit: ProcessExit): Anr {
        val dump = try {
            exit.readTrace()?.toString(Charsets.UTF_8)
        } catch (e: Exception) {
            null
        }
        val stack = dump?.let { mainThread(it) } ?: ""
        val message = exit.description?.trim()?.takeIf { it.isNotEmpty() }
            ?: dump?.let { subject(it) }
            ?: DEFAULT_MESSAGE
        return Anr(
            exceptionMessage = message.take(1_000),
            stackTrace = stack,
            timestampMs = exit.timestampMs.takeIf { it > 0 },
            importance = exit.importance,
            fingerprint = Fingerprint.of(TYPE, stack)
        )
    }

    /**
     * The ANR event in the wire shape CrashHandler persists. No `fatal` and no
     * `title`: an ANR is not a crash, and the server titles ANR issues from the
     * main thread's first app frame. `metadata` carries the fingerprint, the
     * platform, the process importance and whether the app was in the
     * foreground.
     */
    fun toEvent(anr: Anr, nowMs: Long, isoTimestamp: (Long) -> String): Map<String, Any?> {
        val metadata = LinkedHashMap<String, Any?>()
        metadata["fingerprint"] = anr.fingerprint
        metadata["platform"] = PLATFORM
        if (anr.importance != null) {
            metadata["importance"] = anr.importance
            metadata["foreground"] = anr.importance <= IMPORTANCE_FOREGROUND
        }
        return linkedMapOf(
            "type"             to TYPE,
            "timestamp"        to isoTimestamp(anr.timestampMs ?: nowMs),
            "exceptionType"    to TYPE,
            "exceptionMessage" to anr.exceptionMessage,
            "stackTrace"       to anr.stackTrace,
            "breadcrumbs"      to emptyList<Any>(),
            "metadata"         to metadata,
            "screen"           to "",
            "x"                to 0.0,
            "y"                to 0.0,
            "capturedOffline"  to false,
            "networkAtCapture" to ""
        )
    }
}
